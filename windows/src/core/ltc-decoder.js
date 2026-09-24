// SMPTE LTC audio decoder. JavaScript port of Sources/Core/LTCDecoder.swift.
// Feed it mono Float32 samples plus the clock time of the first sample; it reports each
// decoded frame and the exact clock time at which that frame ended.

export class LTCDecoder {
  constructor(sampleRate) {
    this.minBitPeriod = sampleRate / 2400 / 1.2;
    this.maxBitPeriod = (sampleRate / 1920) * 1.2;
    this.bitPeriod = sampleRate / 2160;
    this.envelope = 0;
    this.high = false;
    this.previousSample = 0;
    this.lastEdge = -1;
    this.samplePosition = 0;
    this.halfBitPending = false;
    this.pendingShort = 0;
    // The last 80 bits received; bits[i] is LTC bit i of the frame once aligned.
    this.bits = new Uint8Array(80);
    this.bitsSinceSync = 0;
    this.peakLevel = 0;
    this.onFrame = null;
  }

  /**
   * @param {Float32Array} samples
   * @param {number} startTime clock time of samples[0]
   * @param {number} ticksPerSample clock ticks per sample
   */
  process(samples, startTime, ticksPerSample) {
    const bufferStart = this.samplePosition;
    let peak = 0;
    for (let i = 0; i < samples.length; i++) {
      const x = samples[i];
      const a = Math.abs(x);
      if (a > peak) peak = a;
      // Peak envelope with ~50 ms release so the threshold follows the signal level.
      if (a > this.envelope) this.envelope = a; else this.envelope *= 0.9995;
      const threshold = Math.max(this.envelope * 0.25, 0.002);

      let edge = false;
      if (this.high && x < -threshold) { this.high = false; edge = true; }
      else if (!this.high && x > threshold) { this.high = true; edge = true; }

      if (edge) {
        const t = this.high ? threshold : -threshold;
        const denom = x - this.previousSample;
        const frac = denom !== 0 ? (t - this.previousSample) / denom : 0.5;
        const pos = this.samplePosition + i - 1 + Math.min(Math.max(frac, 0), 1);
        this.handleEdge(pos, bufferStart, startTime, ticksPerSample);
      }
      this.previousSample = x;
    }
    this.samplePosition += samples.length;
    this.peakLevel = peak;
  }

  handleEdge(pos, bufferStart, startTime, ticksPerSample) {
    const last = this.lastEdge;
    this.lastEdge = pos;
    if (last < 0) return;
    const d = pos - last;

    if (d > this.maxBitPeriod * 1.6 || d < this.minBitPeriod * 0.3) {
      // Silence gap or noise: start over.
      this.halfBitPending = false;
      this.bitsSinceSync = 0;
      return;
    }
    if (d < this.bitPeriod * 0.75) {
      // Half-bit interval: two in a row make a '1'.
      if (this.halfBitPending) {
        this.halfBitPending = false;
        this.adaptBitPeriod(this.pendingShort + d);
        this.pushBit(1, pos, bufferStart, startTime, ticksPerSample);
      } else {
        this.halfBitPending = true;
        this.pendingShort = d;
      }
    } else {
      // Full-bit interval: a '0'. A dangling half-bit means we were out of phase.
      this.halfBitPending = false;
      this.adaptBitPeriod(d);
      this.pushBit(0, pos, bufferStart, startTime, ticksPerSample);
    }
  }

  adaptBitPeriod(measured) {
    this.bitPeriod += (measured - this.bitPeriod) * 0.1;
    this.bitPeriod = Math.min(Math.max(this.bitPeriod, this.minBitPeriod), this.maxBitPeriod);
  }

  pushBit(bit, endPos, bufferStart, startTime, ticksPerSample) {
    // Shift so bits[79] is the newest bit and bits[0] the oldest (LTC bit 0 is sent first).
    this.bits.copyWithin(0, 1);
    this.bits[79] = bit;
    this.bitsSinceSync++;
    if (this.bitsSinceSync < 80 || !this.isSync()) return;
    this.bitsSinceSync = 0;
    const decoded = this.decodeFields();
    if (!decoded || !this.onFrame) return;
    const endTime = startTime + (endPos - bufferStart) * ticksPerSample;
    this.onFrame({ timecode: decoded.tc, dropFrame: decoded.df, endTime });
  }

  isSync() {
    // Bits 64..79 transmitted as 0011 1111 1111 1101.
    const b = this.bits;
    if (b[64] !== 0 || b[65] !== 0 || b[78] !== 0 || b[79] !== 1) return false;
    for (let i = 66; i <= 77; i++) if (b[i] !== 1) return false;
    return true;
  }

  field(start, n) {
    let v = 0;
    for (let i = 0; i < n; i++) v |= this.bits[start + i] << i;
    return v;
  }

  decodeFields() {
    const fu = this.field(0, 4), ft = this.field(8, 2);
    const su = this.field(16, 4), st = this.field(24, 3);
    const mu = this.field(32, 4), mt = this.field(40, 3);
    const hu = this.field(48, 4), ht = this.field(56, 2);
    if (fu > 9 || su > 9 || mu > 9 || hu > 9) return null;
    const t = { hours: ht * 10 + hu, minutes: mt * 10 + mu, seconds: st * 10 + su, frames: ft * 10 + fu };
    if (t.frames >= 30 || t.seconds >= 60 || t.minutes >= 60 || t.hours >= 24) return null;
    return { tc: t, df: this.bits[10] === 1 };
  }
}
