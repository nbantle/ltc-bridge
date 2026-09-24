// Synthesizes SMPTE LTC audio. Used by the self-test and the developer test input.
import { frameCount, fromFrameCount } from './timecode.js';

export function ltcBits(t, drop) {
  const b = new Array(80).fill(0);
  const put = (v, start, n) => { for (let i = 0; i < n; i++) b[start + i] = (v >> i) & 1; };
  put(t.frames % 10, 0, 4); put(Math.floor(t.frames / 10), 8, 2); b[10] = drop ? 1 : 0;
  put(t.seconds % 10, 16, 4); put(Math.floor(t.seconds / 10), 24, 3);
  put(t.minutes % 10, 32, 4); put(Math.floor(t.minutes / 10), 40, 3);
  put(t.hours % 10, 48, 4); put(Math.floor(t.hours / 10), 56, 2);
  put(0x5, 4, 4);   // some user bits, which decoders must ignore
  [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1].forEach((v, i) => (b[64 + i] = v));
  return b;
}

/** Biphase-mark LTC starting at `start`, with a finite rise time and optional noise. */
export function synthesize(start, rate, realPeriod, frames, sampleRate, amplitude, noise = 0, invert = false) {
  const frameSamples = realPeriod * sampleRate, bitSamples = frameSamples / 80;
  const edges = [];
  const s0 = frameCount(start, rate);
  for (let k = 0; k < frames; k++) {
    const bits = ltcBits(fromFrameCount(s0 + k, rate), rate.drop);
    bits.forEach((bit, i) => { const t = k * frameSamples + i * bitSamples; edges.push(t); if (bit) edges.push(t + bitSamples / 2); });
  }
  const total = Math.floor(frames * frameSamples) + 64;
  const out = new Float32Array(total);
  let level = invert ? -1 : 1, e = 0, smooth = 0, seed = 12345;
  for (let i = 0; i < total; i++) {
    while (e < edges.length && edges[e] <= i) { level = -level; e++; }
    smooth += (level * amplitude - smooth) * 0.6;
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    out[i] = smooth + ((seed >>> 8) / (1 << 24) - 0.5) * 2 * noise;
  }
  return out;
}
