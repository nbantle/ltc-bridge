// Smooths audio buffer timestamps with a second-order delay-locked loop, so decoded LTC
// frames get stable times even when buffers arrive in bursts with jittery timestamps.
// JavaScript port of Sources/Core/SampleClock.swift. Times are in milliseconds.

export class SampleClock {
  constructor(sampleRate) {
    this.nominalMsPerSample = 1000 / sampleRate;
    this.msPerSample = this.nominalMsPerSample;
    this.predicted = null;   // expected time of the next buffer's first sample
    this.resetThreshold = 50;
  }

  /** Filtered time of the first sample of a buffer whose raw timestamp is `observed`. */
  timestamp(observed, frames) {
    if (frames <= 0) return observed;
    if (this.predicted == null || Math.abs(observed - this.predicted) >= this.resetThreshold) {
      // First buffer, or a real discontinuity (dropout, device restart).
      this.msPerSample = this.nominalMsPerSample;
      this.predicted = observed + frames * this.msPerSample;
      return observed;
    }
    // Loop bandwidth ~0.5 Hz: jitter is averaged over a couple of seconds.
    const periodSeconds = (frames * this.msPerSample) / 1000;
    const omega = 2 * Math.PI * 0.5 * periodSeconds;
    const b = Math.SQRT2 * omega, c = omega * omega;
    const error = observed - this.predicted;
    const filtered = this.predicted + b * error;
    this.msPerSample += (c * error) / frames;
    this.msPerSample = Math.min(Math.max(this.msPerSample, this.nominalMsPerSample * 0.995), this.nominalMsPerSample * 1.005);
    this.predicted = filtered + frames * this.msPerSample;
    return filtered;
  }
}
