// Locks onto decoded LTC frames and generates correctly timed MTC.
// Platform-independent: time is a Double in caller-defined clock ticks, and
// the caller owns the thread that calls `MTCScheduler.poll(now:)` and sends
// the returned MIDI bytes.

import Foundation

enum SyncStatus: String {
    case noSignal = "NO SIGNAL"
    case locked = "LOCKED"
    case freewheel = "FREEWHEEL"
    case test = "TEST"
}

struct EngineSnapshot {
    var status: SyncStatus
    var rate: FrameRate?
    var generation: Int
    var anchorTime: Double
    var anchorFrame: Double
    var periodTicks: Double
    var lastLTC: Timecode?
    var lastLTCAge: Double          // seconds since any LTC frame was decoded
    var relocations: Int            // total relocations since launch (jump/loop detection)
    var looping: Bool               // input is replaying the same audio over and over

    /// Output position in frames (offset applied) at clock time `t`.
    func position(at t: Double) -> Double { anchorFrame + (t - anchorTime) / periodTicks }

    /// Clock time at which the output position reaches `frame`.
    func time(atFrame frame: Double) -> Double { anchorTime + (frame - anchorFrame) * periodTicks }
}

final class MTCEngine {
    let ticksPerSecond: Double
    private let lock = NSLock()

    // Settings (read/written under lock).
    private var _offsetFrames = 0
    private var _freewheelFrames = 10

    // Rate detection.
    private var previous: (tc: Timecode, time: Double)?
    private var observedFPS: Int?          // learned from a frame-number wrap
    private var maxFrameSeen = 0
    private var measuredPeriod: Double?    // EMA of frame intervals, in ticks
    private var consecutive = 0
    private var rate: FrameRate?

    // Output lock.
    private var running = false
    private var generation = 0
    private var anchorTime = 0.0
    private var anchorFrame = 0.0
    private var lastAccepted = 0.0
    private var lastLTC: Timecode?
    private var lastDecoded = 0.0
    private var relocations = 0
    private var inputGap = 0.0            // largest recent gap between audio callbacks, in ticks

    // Recently decoded frames, used to spot a stuck buffer replaying the same audio.
    private var recent: [(count: Int, time: Double)] = []
    private var lastLoopDetected = -Double.infinity

    // Built-in test generator: runs MTC from a chosen start time, ignoring LTC.
    private var testMode = false
    /// A jump back to timecode already heard within this many seconds is treated as a stuck loop.
    static let loopWindow = 1.0

    // Diagnostic log of recent LTC frames (ring buffer).
    struct LogEntry {
        var time: Double
        var timecode: Timecode
        var dropFrame: Bool
        var action: String
        var error: Double
    }
    private var log: [LogEntry] = []
    private var logNext = 0
    private let logCapacity = 4000

    /// Frames a jump must hold steady before the output follows it.
    static let framesToLock = 4
    /// Timing disagreement (in frames) absorbed smoothly instead of treated as a jump.
    static let jitterTolerance = 1.5

    init(ticksPerSecond: Double) {
        self.ticksPerSecond = ticksPerSecond
    }

    var offsetFrames: Int {
        get { lock.lock(); defer { lock.unlock() }; return _offsetFrames }
        set {
            lock.lock()
            if running { anchorFrame += Double(newValue - _offsetFrames); generation += 1 }
            _offsetFrames = newValue
            lock.unlock()
        }
    }

    var freewheelFrames: Int {
        get { lock.lock(); defer { lock.unlock() }; return _freewheelFrames }
        set { lock.lock(); _freewheelFrames = max(0, newValue); lock.unlock() }
    }

    /// Called from the audio thread for every decoded LTC frame.
    func ingest(_ frame: LTCFrame) {
        lock.lock()
        defer { lock.unlock() }

        let t = frame.endTime
        let tc = frame.timecode
        lastDecoded = t
        if testMode {
            lastLTC = tc
            record(frame, "test running", 0)
            return
        }
        maxFrameSeen = max(maxFrameSeen, tc.frames)

        if let prev = previous, Self.isSuccessor(prev.tc, tc) {
            consecutive += 1
            if tc.frames == 0, prev.tc.frames >= 23 { observedFPS = prev.tc.frames + 1 }
            let interval = t - prev.time
            let seconds = interval / ticksPerSecond
            if seconds > 1.0 / 31.0 && seconds < 1.0 / 23.0 {
                if let p = measuredPeriod { measuredPeriod = p + (interval - p) * 0.05 } else { measuredPeriod = interval }
            }
        } else {
            consecutive = 0
        }
        previous = (tc, t)

        let detected = classifyRate(dropFrame: frame.dropFrame)
        if detected != rate {
            rate = detected
            if running { relocate(to: tc, at: t) }
        }
        guard let rate = rate else { record(frame, "detecting rate", 0); return }

        let period = measuredPeriod ?? rate.nominalPeriod * ticksPerSecond
        let count = tc.frameCount(rate: rate)
        // The frame just ended, so the position at `t` is the following frame.
        let measured = Double(count + 1 + _offsetFrames)

        // Was this exact frame already heard moments ago, before the current run of frames?
        let window = Self.loopWindow * ticksPerSecond
        let earlier = recent.dropLast(min(consecutive, recent.count))
        let heardRecently = earlier.contains { $0.count == count && t - $0.time < window }
        recent.append((count, t))
        if recent.count > 256 || (recent.first.map { t - $0.time > window * 2 } ?? false) { recent.removeFirst() }

        if running {
            let predicted = anchorFrame + (t - anchorTime) / period
            let error = measured - predicted
            if abs(error) < Self.jitterTolerance {
                // Drift or timing jitter: nudge smoothly toward the measured position.
                anchorTime = t
                anchorFrame = predicted + error * 0.1
                lastAccepted = t
                lastLTC = tc
                record(frame, "ok", error)
                return
            }
            // Not locked yet, or a jump. Only follow once it holds steady,
            // and never follow a jump back into audio we just heard (stuck loop).
            if heardRecently {
                lastLoopDetected = t
                record(frame, "loop ignored", error)
            } else if consecutive >= Self.framesToLock - 1 {
                record(frame, "jump", error)
                relocate(to: tc, at: t)
            } else {
                record(frame, "ignored", error)
            }
            return
        }

        if heardRecently {
            lastLoopDetected = t
            record(frame, "loop ignored", 0)
        } else if consecutive >= Self.framesToLock - 1 {
            record(frame, "lock", 0)
            relocate(to: tc, at: t)
        } else {
            record(frame, "waiting", 0)
        }
    }

    private func record(_ frame: LTCFrame, _ action: String, _ error: Double) {
        let entry = LogEntry(time: frame.endTime, timecode: frame.timecode, dropFrame: frame.dropFrame, action: action, error: error)
        if log.count < logCapacity { log.append(entry) } else { log[logNext] = entry }
        logNext = (logNext + 1) % logCapacity
    }

    /// Recent LTC frames, oldest first.
    func recentLog() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return log.count < logCapacity ? log : Array(log[logNext...] + log[..<logNext])
    }

    /// Called from the audio thread with the wall-clock gap since the previous callback.
    func reportInputGap(_ ticks: Double) {
        lock.lock()
        inputGap = max(ticks, inputGap * 0.9995)
        lock.unlock()
    }

    private func relocate(to tc: Timecode, at t: Double) {
        guard let rate = rate else { return }
        anchorTime = t
        anchorFrame = Double(tc.frameCount(rate: rate) + 1 + _offsetFrames)
        lastAccepted = t
        lastLTC = tc
        running = true
        generation += 1
        relocations += 1
    }

    private func classifyRate(dropFrame: Bool) -> FrameRate? {
        if dropFrame { return .fps2997DF }
        if let fps = observedFPS {
            switch fps {
            case 24: return .fps24
            case 25: return .fps25
            case 30: return .fps30
            default: break
            }
        }
        guard let p = measuredPeriod else { return nil }
        let seconds = p / ticksPerSecond
        let candidates: [FrameRate] = [.fps24, .fps25, .fps30].filter { $0.framesPerSecond > maxFrameSeen }
        return candidates.min(by: { abs($0.nominalPeriod - seconds) < abs($1.nominalPeriod - seconds) })
    }

    static func isSuccessor(_ a: Timecode, _ b: Timecode) -> Bool {
        if b.hours == a.hours, b.minutes == a.minutes, b.seconds == a.seconds {
            return b.frames == a.frames + 1
        }
        guard b.frames <= 2, a.frames >= 23 else { return false }
        var s = a.seconds + 1, m = a.minutes, h = a.hours
        if s == 60 { s = 0; m += 1 }
        if m == 60 { m = 0; h += 1 }
        if h == 24 { h = 0 }
        guard b.seconds == s, b.minutes == m, b.hours == h else { return false }
        // Drop-frame skips frames 0 and 1 at the start of most minutes.
        return b.frames == 0 || (b.frames == 2 && s == 0 && m % 10 != 0)
    }

    /// Starts the built-in generator: MTC runs from `start` at `rate` until stopped.
    func startTest(from start: Timecode, rate: FrameRate, now: Double) {
        lock.lock()
        testMode = true
        self.rate = rate
        measuredPeriod = nil
        anchorTime = now
        anchorFrame = Double(start.frameCount(rate: rate))
        running = true
        generation += 1
        lock.unlock()
    }

    /// Stops the generator and goes back to following LTC.
    func stopTest() {
        lock.lock()
        testMode = false
        running = false
        rate = nil; previous = nil; observedFPS = nil; maxFrameSeen = 0; consecutive = 0
        generation += 1
        lock.unlock()
    }

    /// Updates dropout state and returns a consistent view for the scheduler/UI.
    func snapshot(now: Double) -> EngineSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let period = measuredPeriod ?? (rate?.nominalPeriod ?? 1.0 / 30.0) * ticksPerSecond
        var status = SyncStatus.noSignal
        if testMode {
            status = .test
        } else if running {
            // Audio arrives in buffers, so allow for the gap between buffers.
            let age = (now - lastAccepted - inputGap) / period
            if age > Double(_freewheelFrames) + 1.5 {
                running = false
                consecutive = 0
            } else {
                status = age > 2.5 ? .freewheel : .locked
            }
        }
        return EngineSnapshot(status: status, rate: rate, generation: generation,
                              anchorTime: anchorTime, anchorFrame: anchorFrame,
                              periodTicks: period, lastLTC: lastLTC,
                              lastLTCAge: lastDecoded > 0 ? (now - lastDecoded) / ticksPerSecond : .infinity,
                              relocations: relocations,
                              looping: now - lastLoopDetected < 2 * ticksPerSecond)
    }

    /// Clears all lock and rate state (used when the audio input changes).
    func reset() {
        lock.lock()
        previous = nil; observedFPS = nil; maxFrameSeen = 0; measuredPeriod = nil
        consecutive = 0; rate = nil; running = false; lastLTC = nil; generation += 1; testMode = false
        lastDecoded = 0; inputGap = 0; recent.removeAll(); lastLoopDetected = -.infinity
        lock.unlock()
    }
}

/// Turns the engine's timeline into MTC quarter-frame and full-frame messages.
/// Eight quarter-frames span two frames; piece 0 is always sent on an even
/// frame boundary and carries that frame's timecode.
final class MTCScheduler {
    private let engine: MTCEngine
    private var generation = -1
    private var rate: FrameRate?
    private var nextQuarter: Int?
    private var latched = Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0)

    init(engine: MTCEngine) { self.engine = engine }

    struct Output {
        var messages: [[UInt8]] = []
        /// Frames that just started (one per frame boundary, plus on locate), for frame-based
        /// protocols such as Art-Net timecode.
        var frames: [Timecode] = []
        var rate: FrameRate?
        var wakeAt: Double
    }

    /// Returns messages due now and the clock time at which to call again.
    func poll(now: Double) -> Output {
        let snap = engine.snapshot(now: now)
        let idle = now + engine.ticksPerSecond * 0.002
        guard snap.status != .noSignal, let rate = snap.rate else {
            nextQuarter = nil
            // Nothing to send: check back in 5 ms (well under a quarter-frame).
            return Output(wakeAt: now + engine.ticksPerSecond * 0.005)
        }

        var out = Output(rate: rate, wakeAt: idle)
        let quarterTicks = snap.periodTicks / 4

        if snap.generation != generation || rate != self.rate || nextQuarter == nil {
            generation = snap.generation
            self.rate = rate
            let pos = snap.position(at: now)
            let tc = Timecode(frameCount: Int(pos.rounded(.down)), rate: rate)
            out.messages.append(Self.fullFrame(tc, rate: rate))
            out.frames.append(tc)
            nextQuarter = Self.nextCycleStart(after: pos)
        }

        while var q = nextQuarter {
            let due = snap.time(atFrame: Double(q) / 4)
            if due > now + quarterTicks * 0.05 {
                out.wakeAt = due
                return out
            }
            if now - due > quarterTicks * 2 {
                // We fell behind (e.g. the system stalled): restart the cycle cleanly.
                let pos = snap.position(at: now)
                out.messages.append(Self.fullFrame(Timecode(frameCount: Int(pos.rounded(.down)), rate: rate), rate: rate))
                nextQuarter = Self.nextCycleStart(after: pos)
                continue
            }
            let piece = q & 7
            if piece == 0 { latched = Timecode(frameCount: q / 4, rate: rate) }
            if q & 3 == 0 { out.frames.append(Timecode(frameCount: q >> 2, rate: rate)) }
            out.messages.append([0xF1, UInt8(piece << 4) | Self.nibble(piece, latched, rate)])
            q += 1
            nextQuarter = q
        }
        return out
    }

    private static func nextCycleStart(after position: Double) -> Int {
        let q = Int((position * 4).rounded(.up)) + 1
        return ((q + 7) >> 3) << 3
    }

    private static func nibble(_ piece: Int, _ tc: Timecode, _ rate: FrameRate) -> UInt8 {
        switch piece {
        case 0: return UInt8(tc.frames & 0x0F)
        case 1: return UInt8(tc.frames >> 4)
        case 2: return UInt8(tc.seconds & 0x0F)
        case 3: return UInt8(tc.seconds >> 4)
        case 4: return UInt8(tc.minutes & 0x0F)
        case 5: return UInt8(tc.minutes >> 4)
        case 6: return UInt8(tc.hours & 0x0F)
        default: return (rate.mtcCode << 1) | UInt8((tc.hours >> 4) & 1)
        }
    }

    static func fullFrame(_ tc: Timecode, rate: FrameRate) -> [UInt8] {
        [0xF0, 0x7F, 0x7F, 0x01, 0x01,
         (rate.mtcCode << 5) | UInt8(tc.hours), UInt8(tc.minutes), UInt8(tc.seconds), UInt8(tc.frames),
         0xF7]
    }
}
