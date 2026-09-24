// Timecode math shared by the LTC decoder and the MTC generator.
// Platform-independent: no Apple frameworks used here.

enum FrameRate: Int, CaseIterable {
    case fps24 = 0
    case fps25 = 1
    case fps2997DF = 2
    case fps30 = 3

    /// Rate code used in MTC quarter-frame piece 7 and the full-frame message.
    var mtcCode: UInt8 { UInt8(rawValue) }

    /// Frames per timecode second (the frame-number wrap point).
    var framesPerSecond: Int {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps2997DF, .fps30: return 30
        }
    }

    var isDropFrame: Bool { self == .fps2997DF }

    /// Nominal real-time frame period in seconds.
    var nominalPeriod: Double {
        switch self {
        case .fps24: return 1.0 / 24.0
        case .fps25: return 1.0 / 25.0
        case .fps2997DF: return 1001.0 / 30000.0
        case .fps30: return 1.0 / 30.0
        }
    }

    /// Number of frames in 24 hours.
    var framesPerDay: Int {
        isDropFrame ? 2_589_408 : 24 * 3600 * framesPerSecond
    }

    var label: String {
        switch self {
        case .fps24: return "24 fps"
        case .fps25: return "25 fps"
        case .fps2997DF: return "29.97 DF"
        case .fps30: return "30 fps"
        }
    }
}

struct Timecode: Equatable {
    var hours: Int
    var minutes: Int
    var seconds: Int
    var frames: Int

    init(hours: Int, minutes: Int, seconds: Int, frames: Int) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    /// Converts timecode to an absolute frame count since 00:00:00:00.
    func frameCount(rate: FrameRate) -> Int {
        let fps = rate.framesPerSecond
        var count = ((hours * 60 + minutes) * 60 + seconds) * fps + frames
        if rate.isDropFrame {
            let totalMinutes = hours * 60 + minutes
            count -= 2 * (totalMinutes - totalMinutes / 10)
        }
        return count
    }

    /// Converts an absolute frame count back to timecode, wrapping at 24h.
    init(frameCount: Int, rate: FrameRate) {
        let perDay = rate.framesPerDay
        var n = ((frameCount % perDay) + perDay) % perDay
        if rate.isDropFrame {
            let d = n / 17982
            let m = n % 17982
            n += 18 * d + (m < 2 ? 0 : 2 * ((m - 2) / 1798))
        }
        let fps = rate.framesPerSecond
        frames = n % fps
        seconds = (n / fps) % 60
        minutes = (n / (fps * 60)) % 60
        hours = (n / (fps * 3600)) % 24
    }

    /// Parses "HH:MM:SS:FF" (also accepts ';' or '.' separators and a leading '-').
    /// Returns a signed frame count, or nil if malformed.
    static func parseOffset(_ text: String, rate: FrameRate) -> Int? {
        var s = text.trimmingSpaces()
        var sign = 1
        if s.hasPrefix("-") { sign = -1; s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." }).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        let p = parts.map { $0! }
        guard p[1] < 60, p[2] < 60, p[3] < rate.framesPerSecond else { return nil }
        // Offsets are plain durations, so no drop-frame adjustment.
        let fps = rate.framesPerSecond
        return sign * (((p[0] * 60 + p[1]) * 60 + p[2]) * fps + p[3])
    }

    /// Parses "HH:MM:SS:FF" as a timecode position. Drop-frame labels that don't exist
    /// (frames 0 and 1 of most minutes) are moved to frame 2.
    static func parse(_ text: String, rate: FrameRate) -> Timecode? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." }).map { Int(String($0).trimmingSpaces()) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        let p = parts.map { $0! }
        guard p[0] < 24, p[1] < 60, p[2] < 60, p[3] < rate.framesPerSecond, p.allSatisfy({ $0 >= 0 }) else { return nil }
        var tc = Timecode(hours: p[0], minutes: p[1], seconds: p[2], frames: p[3])
        if rate.isDropFrame, tc.seconds == 0, tc.minutes % 10 != 0, tc.frames < 2 { tc.frames = 2 }
        return tc
    }

    func formatted(dropFrame: Bool = false) -> String {
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(two(hours)):\(two(minutes)):\(two(seconds))\(dropFrame ? ";" : ":")\(two(frames))"
    }
}

private extension String {
    func trimmingSpaces() -> String {
        var s = Substring(self)
        while s.first == " " { s.removeFirst() }
        while s.last == " " { s.removeLast() }
        return String(s)
    }
}
