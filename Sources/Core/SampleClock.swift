// Smooths audio buffer timestamps. Some drivers (notably virtual/network
// soundcards such as Dante Virtual Soundcard) deliver buffers in bursts with
// jittery timestamps; this second-order delay-locked loop tracks the true
// sample clock so decoded LTC frames get stable times.

final class SampleClock {
    private let nominalTicksPerSample: Double
    private let ticksPerSecond: Double
    private var ticksPerSample: Double
    private var predicted: Double?   // expected time of the next buffer's first sample
    private let resetThreshold: Double

    init(sampleRate: Double, ticksPerSecond: Double) {
        self.ticksPerSecond = ticksPerSecond
        nominalTicksPerSample = ticksPerSecond / sampleRate
        ticksPerSample = nominalTicksPerSample
        resetThreshold = 0.05 * ticksPerSecond
    }

    var currentTicksPerSample: Double { ticksPerSample }

    /// Returns the filtered time of the first sample of a buffer whose raw
    /// timestamp is `observed`, and advances by `frames` samples.
    func timestamp(observed: Double, frames: Int) -> Double {
        guard frames > 0 else { return observed }
        guard let p = predicted, abs(observed - p) < resetThreshold else {
            // First buffer, or a real discontinuity (dropout, device restart).
            ticksPerSample = nominalTicksPerSample
            predicted = observed + Double(frames) * ticksPerSample
            return observed
        }
        // Loop bandwidth ~0.5 Hz: jitter is averaged over a couple of seconds.
        let period = Double(frames) * ticksPerSample / ticksPerSecond
        let omega = 2 * Double.pi * 0.5 * period
        let b = 2.0.squareRoot() * omega
        let c = omega * omega

        let error = observed - p
        let filtered = p + b * error
        ticksPerSample += c * error / Double(frames)
        // Clocks never differ by more than a fraction of a percent.
        ticksPerSample = min(max(ticksPerSample, nominalTicksPerSample * 0.995), nominalTicksPerSample * 1.005)
        predicted = filtered + Double(frames) * ticksPerSample
        return filtered
    }
}
