// SMPTE LTC (linear timecode) audio decoder.
// Platform-independent: feed it mono Float samples and a clock value for the
// first sample of each buffer; it reports each decoded frame and the exact
// clock time at which that frame ended (i.e. when the next frame began).

struct LTCFrame {
    var timecode: Timecode
    var dropFrame: Bool
    /// Clock time (in caller-defined ticks) of the frame boundary that ended this frame.
    var endTime: Double
}

final class LTCDecoder {
    private let sampleRate: Double

    // Bit-period tracking (in samples). LTC is 80 bits per frame, so the bit
    // rate is 1920 bit/s at 24 fps up to 2400 bit/s at 30 fps.
    private let minBitPeriod: Double
    private let maxBitPeriod: Double
    private var bitPeriod: Double

    // Edge detection with hysteresis relative to a peak envelope.
    private var envelope: Float = 0
    private var high = false
    private var previousSample: Float = 0
    private var lastEdge: Double = -1          // absolute sample position (fractional)
    private var samplePosition: Int64 = 0      // absolute index of the next incoming sample
    private var halfBitPending = false
    private var pendingShort: Double = 0

    // 80-bit shift register: lo = bits 0...63, hi = bits 64...79.
    private var lo: UInt64 = 0
    private var hi: UInt16 = 0
    private var bitsSinceSync = 0

    // Sync word (bits 64...79 transmitted as 0011 1111 1111 1101).
    private static let syncForward: UInt16 = 0xBFFC

    /// Peak absolute sample level of the most recent buffer (0...1).
    private(set) var peakLevel: Float = 0

    var onFrame: ((LTCFrame) -> Void)?

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        minBitPeriod = sampleRate / 2400.0 / 1.2
        maxBitPeriod = sampleRate / 1920.0 * 1.2
        bitPeriod = sampleRate / 2160.0
    }

    /// Processes a buffer of mono samples.
    /// - Parameters:
    ///   - startTime: clock time of `samples[0]`.
    ///   - ticksPerSample: clock ticks per audio sample.
    func process(_ samples: UnsafePointer<Float>, count: Int, startTime: Double, ticksPerSample: Double) {
        let bufferStart = samplePosition
        var peak: Float = 0

        for i in 0..<count {
            let x = samples[i]
            let a = abs(x)
            if a > peak { peak = a }

            // Peak envelope with ~50 ms release so the threshold follows the signal level.
            if a > envelope { envelope = a } else { envelope *= 0.9995 }
            let threshold = max(envelope * 0.25, 0.002)

            var edge = false
            if high, x < -threshold { high = false; edge = true }
            else if !high, x > threshold { high = true; edge = true }

            if edge {
                // Interpolate where the signal crossed the threshold.
                let t: Float = high ? threshold : -threshold
                let denom = x - previousSample
                let frac = denom != 0 ? Double((t - previousSample) / denom) : 0.5
                let pos = Double(samplePosition + Int64(i) - 1) + min(max(frac, 0), 1)
                handleEdge(at: pos, bufferStart: bufferStart, startTime: startTime, ticksPerSample: ticksPerSample)
            }
            previousSample = x
        }

        samplePosition += Int64(count)
        peakLevel = peak
    }

    private func handleEdge(at pos: Double, bufferStart: Int64, startTime: Double, ticksPerSample: Double) {
        defer { lastEdge = pos }
        guard lastEdge >= 0 else { return }
        let d = pos - lastEdge

        if d > maxBitPeriod * 1.6 || d < minBitPeriod * 0.3 {
            // Silence gap or noise: start over.
            halfBitPending = false
            bitsSinceSync = 0
            return
        }

        if d < bitPeriod * 0.75 {
            // Half-bit interval: two in a row make a '1'.
            if halfBitPending {
                halfBitPending = false
                adaptBitPeriod(pendingShort + d)
                pushBit(1, endPos: pos, bufferStart: bufferStart, startTime: startTime, ticksPerSample: ticksPerSample)
            } else {
                halfBitPending = true
                pendingShort = d
            }
        } else {
            // Full-bit interval: a '0'. A dangling half-bit means we were out of
            // phase; drop it, which re-aligns on this edge.
            halfBitPending = false
            adaptBitPeriod(d)
            pushBit(0, endPos: pos, bufferStart: bufferStart, startTime: startTime, ticksPerSample: ticksPerSample)
        }
    }

    private func adaptBitPeriod(_ measured: Double) {
        bitPeriod += (measured - bitPeriod) * 0.1
        bitPeriod = min(max(bitPeriod, minBitPeriod), maxBitPeriod)
    }

    private func pushBit(_ bit: UInt64, endPos: Double, bufferStart: Int64, startTime: Double, ticksPerSample: Double) {
        lo = (lo >> 1) | (UInt64(hi & 1) << 63)
        hi = (hi >> 1) | (UInt16(bit) << 15)
        bitsSinceSync += 1

        guard bitsSinceSync >= 80, hi == LTCDecoder.syncForward else { return }
        bitsSinceSync = 0

        guard let frame = decodeFields() else { return }
        let endTime = startTime + (endPos - Double(bufferStart)) * ticksPerSample
        onFrame?(LTCFrame(timecode: frame.tc, dropFrame: frame.df, endTime: endTime))
    }

    private func decodeFields() -> (tc: Timecode, df: Bool)? {
        func bits(_ start: Int, _ n: Int) -> Int { Int((lo >> UInt64(start)) & ((1 << UInt64(n)) - 1)) }
        let fu = bits(0, 4), ft = bits(8, 2)
        let su = bits(16, 4), st = bits(24, 3)
        let mu = bits(32, 4), mt = bits(40, 3)
        let hu = bits(48, 4), ht = bits(56, 2)
        guard fu <= 9, su <= 9, mu <= 9, hu <= 9 else { return nil }
        let tc = Timecode(hours: ht * 10 + hu, minutes: mt * 10 + mu, seconds: st * 10 + su, frames: ft * 10 + fu)
        guard tc.frames < 30, tc.seconds < 60, tc.minutes < 60, tc.hours < 24 else { return nil }
        return (tc, bits(10, 1) == 1)
    }
}
