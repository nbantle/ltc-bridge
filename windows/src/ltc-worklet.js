// Runs on the audio thread: picks one input channel, decodes LTC, and posts each decoded
// frame (with its sample-accurate audio-clock time) plus the input level to the page.
import { LTCDecoder } from './core/ltc-decoder.js';

class LTCReader extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.channel = options.processorOptions?.channel ?? 0;
    this.decoder = new LTCDecoder(sampleRate);
    this.decoder.onFrame = (f) => this.port.postMessage({ type: 'frame', frame: f });
    this.peak = 0;
    this.blocks = 0;
    this.port.onmessage = (e) => { if (e.data.type === 'channel') this.channel = e.data.channel; };
  }

  process(inputs) {
    const input = inputs[0];
    const samples = input && input[Math.min(this.channel, input.length - 1)];
    const msPerSample = 1000 / sampleRate;
    // Audio-clock time (ms) of the first sample in this block.
    const startMs = currentFrame * msPerSample;
    if (samples) {
      this.decoder.process(samples, startMs, msPerSample);
      this.peak = Math.max(this.peak, this.decoder.peakLevel);
    }
    // Level and a heartbeat about every 21 ms (8 blocks of 128 samples at 48 kHz).
    if (++this.blocks >= 8) {
      this.port.postMessage({ type: 'level', peak: this.peak, ctxMs: startMs, channels: input ? input.length : 0 });
      this.peak = 0;
      this.blocks = 0;
    }
    return true;
  }
}

registerProcessor('ltc-reader', LTCReader);
