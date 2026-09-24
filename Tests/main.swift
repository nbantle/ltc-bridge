// Self-test: synthesizes LTC audio, checks the decoder, then runs the engine in
// real time through the actual CoreMIDI virtual source and verifies the MTC.

import CoreMIDI
import Foundation

var failures = 0
func expect(_ ok: Bool, _ message: String) {
    if !ok { failures += 1; print("  FAIL: \(message)") }
}

// MARK: - LTC synthesis

func ltcBits(_ tc: Timecode, dropFrame: Bool) -> [Int] {
    var b = [Int](repeating: 0, count: 80)
    func put(_ value: Int, _ start: Int, _ n: Int) { for i in 0..<n { b[start + i] = (value >> i) & 1 } }
    put(tc.frames % 10, 0, 4); put(tc.frames / 10, 8, 2)
    b[10] = dropFrame ? 1 : 0
    put(tc.seconds % 10, 16, 4); put(tc.seconds / 10, 24, 3)
    put(tc.minutes % 10, 32, 4); put(tc.minutes / 10, 40, 3)
    put(tc.hours % 10, 48, 4); put(tc.hours / 10, 56, 2)
    put(0x5A, 4, 4)  // some user bits, which must be ignored
    let sync = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
    for i in 0..<16 { b[64 + i] = sync[i] }
    return b
}

/// Returns audio plus the sample position where each frame ends.
func synthesize(start: Timecode, rate: FrameRate, realPeriod: Double, frames: Int, sampleRate: Double,
                amplitude: Float, noise: Float, invert: Bool) -> [Float] {
    let frameSamples = realPeriod * sampleRate
    let bitSamples = frameSamples / 80
    var edges: [Double] = []
    let startCount = start.frameCount(rate: rate)
    for k in 0..<frames {
        let tc = Timecode(frameCount: startCount + k, rate: rate)
        let bits = ltcBits(tc, dropFrame: rate.isDropFrame)
        for (i, bit) in bits.enumerated() {
            let t = Double(k) * frameSamples + Double(i) * bitSamples
            edges.append(t)
            if bit == 1 { edges.append(t + bitSamples / 2) }
        }
    }
    let total = Int(Double(frames) * frameSamples) + 64
    var out = [Float](repeating: 0, count: total)
    var level: Float = invert ? -1 : 1
    var e = 0
    var smooth: Float = 0
    var seed: UInt32 = 12345
    for i in 0..<total {
        while e < edges.count, edges[e] <= Double(i) { level = -level; e += 1 }
        smooth += (level * amplitude - smooth) * 0.6   // finite rise time
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let n = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 2 * noise
        out[i] = smooth + n
    }
    return out
}

// MARK: - Decoder tests

print("Decoder:")
for rate in FrameRate.allCases {
    for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
        let start = Timecode(hours: 1, minutes: 8, seconds: 59, frames: 20)
        let audio = synthesize(start: start, rate: rate, realPeriod: rate.nominalPeriod, frames: 120,
                               sampleRate: sampleRate, amplitude: 0.1, noise: 0.01, invert: sampleRate == 48_000)
        let decoder = LTCDecoder(sampleRate: sampleRate)
        var got: [LTCFrame] = []
        decoder.onFrame = { got.append($0) }
        let chunk = 256
        audio.withUnsafeBufferPointer { buf in
            var i = 0
            while i < buf.count {
                let n = min(chunk, buf.count - i)
                decoder.process(buf.baseAddress! + i, count: n, startTime: Double(i), ticksPerSample: 1)
                i += n
            }
        }
        let frameSamples = rate.nominalPeriod * sampleRate
        var ok = got.count >= 118
        var maxTimingError = 0.0
        for f in got {
            let idx = f.timecode.frameCount(rate: rate) - start.frameCount(rate: rate)
            let expectedEnd = Double(idx + 1) * frameSamples
            maxTimingError = max(maxTimingError, abs(f.endTime - expectedEnd))
            if f.dropFrame != rate.isDropFrame { ok = false }
        }
        for (a, b) in zip(got, got.dropFirst()) where !MTCEngine.isSuccessor(a.timecode, b.timecode) {
            ok = false; print("  non-sequential \(a.timecode.formatted()) -> \(b.timecode.formatted())")
        }
        let label = "\(rate.label) @ \(Int(sampleRate)) Hz"
        print("  \(label): \(got.count) frames, first \(got.first?.timecode.formatted() ?? "-"), max edge error \(String(format: "%.2f", maxTimingError)) samples")
        expect(ok, "\(label) decoded incorrectly")
        expect(maxTimingError < 3, "\(label) timing error too large")
    }
}

// MARK: - Timecode math

print("Timecode math:")
for rate in FrameRate.allCases {
    var ok = true
    for n in stride(from: 0, to: rate.framesPerDay, by: 997) {
        if Timecode(frameCount: n, rate: rate).frameCount(rate: rate) != n { ok = false; break }
    }
    expect(ok, "\(rate.label) round trip")
}
expect(Timecode(frameCount: 1800, rate: .fps2997DF) == Timecode(hours: 0, minutes: 1, seconds: 0, frames: 2), "DF skip at 1 min")
expect(Timecode(frameCount: 17982, rate: .fps2997DF) == Timecode(hours: 0, minutes: 10, seconds: 0, frames: 0), "DF no skip at 10 min")
expect(Timecode.parseOffset("-00:00:01:05", rate: .fps30) == -35, "offset parse")
print("  done")

// MARK: - Real-time engine + CoreMIDI loopback

struct Received { let time: Double; let bytes: [UInt8] }

final class Recorder {
    private let lock = NSLock()
    private var items: [Received] = []
    func add(_ r: Received) { lock.lock(); items.append(r); lock.unlock() }
    func take() -> [Received] { lock.lock(); defer { items.removeAll(); lock.unlock() }; return items }
}

let output = try MIDIOutput(virtualSourceName: "LTC Bridge Test")
let recorder = Recorder()
var client = MIDIClientRef()
MIDIClientCreateWithBlock("SelfTest" as CFString, &client, nil)
var inPort = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "In" as CFString, &inPort) { list, _ in
    let arrival = HostClock.now
    var p = list.pointee.packet
    for _ in 0..<list.pointee.numPackets {
        let bytes = withUnsafeBytes(of: p.data) { Array($0.prefix(Int(p.length))) }
        recorder.add(Received(time: arrival, bytes: bytes))
        p = MIDIPacketNext(&p).pointee
    }
}
// Find our own virtual source and connect to it.
var connected = false
for i in 0..<MIDIGetNumberOfSources() {
    let s = MIDIGetSource(i)
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(s, kMIDIPropertyName, &name)
    if (name?.takeRetainedValue() as String?) == "LTC Bridge Test" {
        MIDIPortConnectSource(inPort, s, nil); connected = true
    }
}
expect(connected, "virtual source visible to other MIDI clients")

func runRealtime(rate: FrameRate, drift: Double, seconds: Double, jumpAt: Double?,
                 chunk: Int = 256, jitterMs: Double = 0, bursty: Bool = false) {
    let sampleRate = 48_000.0
    let realPeriod = rate.nominalPeriod * drift
    let start = Timecode(hours: 10, minutes: 0, seconds: 58, frames: 0)
    let frames = Int(seconds / realPeriod)
    var audio = synthesize(start: start, rate: rate, realPeriod: realPeriod, frames: frames,
                           sampleRate: sampleRate, amplitude: 0.2, noise: 0.005, invert: false)
    var jumpSample = Int.max
    let jumpStart = Timecode(hours: 2, minutes: 30, seconds: 0, frames: 0)
    if let j = jumpAt {
        jumpSample = Int(Double(Int(j / realPeriod)) * realPeriod * sampleRate)
        let tail = synthesize(start: jumpStart, rate: rate, realPeriod: realPeriod, frames: frames,
                              sampleRate: sampleRate, amplitude: 0.2, noise: 0.005, invert: false)
        audio = Array(audio[0..<jumpSample]) + tail
        audio = Array(audio.prefix(Int(seconds * sampleRate)))
    }

    let engine = MTCEngine(ticksPerSecond: HostClock.ticksPerSecond)
    let scheduler = MTCScheduler(engine: engine)
    let clock = MTCClockThread(scheduler: scheduler, output: output)
    let decoder = LTCDecoder(sampleRate: sampleRate)
    decoder.onFrame = { engine.ingest($0) }
    let sampleClock = SampleClock(sampleRate: sampleRate, ticksPerSecond: HostClock.ticksPerSecond)
    _ = recorder.take()
    clock.start()

    // Feed audio at real-time pace, as the IO callback would. Optionally mimic a
    // network soundcard: jittery timestamps and buffers delivered in pairs.
    let t0 = HostClock.now + 0.01 * HostClock.ticksPerSecond
    let ticksPerSample = HostClock.ticksPerSecond / sampleRate
    var seed: UInt32 = 99
    var statusCounts: [SyncStatus: Int] = [:]
    var lastGapCheck = t0
    audio.withUnsafeBufferPointer { buf in
        var i = 0
        var n = 0
        while i + chunk <= buf.count {
            let captureTime = t0 + Double(i) * ticksPerSample
            let deliver = captureTime + Double(chunk) * ticksPerSample * (bursty && n % 2 == 0 ? 2 : 1)
            if !(bursty && n % 2 == 1) { mach_wait_until(UInt64(deliver)) }
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let jitter = (Double(seed >> 8) / Double(1 << 24) - 0.5) * 2 * jitterMs / 1000 * HostClock.ticksPerSecond
            let now = HostClock.now
            engine.reportInputGap(now - lastGapCheck)
            lastGapCheck = now
            let start = sampleClock.timestamp(observed: captureTime + jitter, frames: chunk)
            decoder.process(buf.baseAddress! + i, count: chunk, startTime: start, ticksPerSample: sampleClock.currentTicksPerSample)
            // Sample the status while LTC is flowing (after lock, away from the jump and the end).
            let elapsed = (captureTime - t0) / HostClock.ticksPerSecond
            let nearJump = jumpAt.map { abs(elapsed - $0) < 0.4 } ?? false
            if elapsed > 0.6, elapsed < seconds - 0.2, !nearJump {
                statusCounts[engine.snapshot(now: HostClock.now).status, default: 0] += 1
            }
            i += chunk
            n += 1
        }
    }
    // Let freewheel expire.
    Thread.sleep(forTimeInterval: 0.6)
    clock.stop()
    Thread.sleep(forTimeInterval: 0.01)
    let received = recorder.take()

    // Expected position at host time t.
    let periodTicks = realPeriod * HostClock.ticksPerSecond
    let jumpTime = t0 + Double(jumpSample) * ticksPerSample
    func expectedFrames(at t: Double) -> Double {
        if t >= jumpTime { return Double(jumpStart.frameCount(rate: rate)) + (t - jumpTime) / periodTicks }
        return Double(start.frameCount(rate: rate)) + (t - t0) / periodTicks
    }

    var pieces = [Int](repeating: 0, count: 8)
    var expectedPiece = 0
    var cycleErrors: [Double] = []
    var quarterTimes: [Double] = []
    var fullFrames = 0
    var badOrder = 0
    var rateCodes = Set<Int>()
    var lastQuarter = 0.0
    for r in received {
        if r.bytes.first == 0xF0 { fullFrames += 1; expectedPiece = 0; continue }
        guard r.bytes.count == 2, r.bytes[0] == 0xF1 else { continue }
        let piece = Int(r.bytes[1] >> 4), value = Int(r.bytes[1] & 0x0F)
        if piece != expectedPiece { badOrder += 1 }
        expectedPiece = (piece + 1) & 7
        pieces[piece] = value
        if lastQuarter > 0, r.time - lastQuarter < periodTicks { quarterTimes.append(r.time - lastQuarter) }
        lastQuarter = r.time
        if piece == 7 {
            let tc = Timecode(hours: pieces[6] | ((pieces[7] & 1) << 4), minutes: pieces[4] | (pieces[5] << 4),
                              seconds: pieces[2] | (pieces[3] << 4), frames: pieces[0] | (pieces[1] << 4))
            rateCodes.insert(pieces[7] >> 1)
            // Piece 7 goes out 1.75 frames after the encoded frame began.
            let encoded = Double(tc.frameCount(rate: rate)) + 1.75
            let t = r.time
            if abs(t - jumpTime) > periodTicks * 4 { cycleErrors.append(encoded - expectedFrames(at: t)) }
        }
    }
    let q = quarterTimes.map { $0 / (periodTicks / 4) }
    let meanQ = q.reduce(0, +) / Double(max(q.count, 1))
    let worstQ = q.map { abs($0 - 1) }.max() ?? 99
    let worstErrMs = (cycleErrors.map { abs($0) }.max() ?? 99) * realPeriod * 1000
    var label = "\(rate.label)\(drift != 1 ? " (+\(String(format: "%.1f", (drift - 1) * 100))% clock drift)" : "")\(jumpAt != nil ? " with jump" : "")"
    if jitterMs > 0 || bursty || chunk != 256 { label += " [\(chunk)-sample buffers\(bursty ? ", bursty" : "")\(jitterMs > 0 ? ", ±\(Int(jitterMs)) ms jitter" : "")]" }
    print("  \(label): \(cycleErrors.count) MTC cycles, worst position error \(String(format: "%.2f", worstErrMs)) ms, quarter-frame spacing mean \(String(format: "%.3f", meanQ)) worst \(String(format: "%.1f", worstQ * 100))%, full-frame msgs \(fullFrames)")
    expect(cycleErrors.count > Int(seconds / realPeriod / 2) - 6, "\(label): too few MTC cycles")
    expect(worstErrMs < (jitterMs > 0 ? 4.0 : 2.0), "\(label): MTC position error \(worstErrMs) ms")
    let nonLocked = statusCounts.filter { $0.key != .locked }.values.reduce(0, +)
    print("      status while playing: \(statusCounts.map { "\($0.key.rawValue) \($0.value)" }.sorted().joined(separator: ", "))")
    expect(nonLocked == 0, "\(label): status left LOCKED \(nonLocked) times while LTC was flowing")
    expect(badOrder == 0, "\(label): \(badOrder) out-of-order quarter frames")
    expect(worstQ < 0.35, "\(label): quarter-frame jitter")
    expect(rateCodes == [Int(rate.mtcCode)], "\(label): wrong rate code \(rateCodes)")
    expect(fullFrames == (jumpAt == nil ? 1 : 2), "\(label): expected full-frame on lock/jump, got \(fullFrames)")
    expect(engine.snapshot(now: HostClock.now).status == .noSignal, "\(label): should stop after LTC ends")
}

print("Real-time MTC via CoreMIDI:")
runRealtime(rate: .fps30, drift: 1.0, seconds: 3, jumpAt: nil)
runRealtime(rate: .fps25, drift: 1.0, seconds: 2, jumpAt: nil)
runRealtime(rate: .fps24, drift: 1.0, seconds: 2, jumpAt: nil)
runRealtime(rate: .fps2997DF, drift: 1.0, seconds: 3, jumpAt: nil)
runRealtime(rate: .fps30, drift: 1.002, seconds: 3, jumpAt: 1.5)
runRealtime(rate: .fps30, drift: 1.0, seconds: 4, jumpAt: nil, chunk: 1024, jitterMs: 8, bursty: true)
runRealtime(rate: .fps25, drift: 1.0005, seconds: 4, jumpAt: 2, chunk: 512, jitterMs: 5, bursty: true)

// MARK: - Things that must never lock

print("False-lock protection:")
do {
    let engine = MTCEngine(ticksPerSecond: 48_000)
    let decoder = LTCDecoder(sampleRate: 48_000)
    decoder.onFrame = { engine.ingest($0) }
    // 10 s of noise at several levels.
    var seed: UInt32 = 7
    var noise = [Float](repeating: 0, count: 48_000 * 10)
    for i in noise.indices {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        noise[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * (i < 160_000 ? 0.01 : (i < 320_000 ? 0.2 : 1.0))
    }
    noise.withUnsafeBufferPointer { decoder.process($0.baseAddress!, count: $0.count, startTime: 0, ticksPerSample: 1) }
    let s = engine.snapshot(now: 480_000)
    expect(s.relocations == 0, "noise caused a lock")
    print("  noise: \(s.relocations == 0 ? "no lock" : "LOCKED (bad)")")

    // A short chunk of LTC (3 frames) repeating, as a stuck buffer would.
    let loop = synthesize(start: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0), rate: .fps30,
                          realPeriod: 1.0 / 30, frames: 3, sampleRate: 48_000, amplitude: 0.2, noise: 0, invert: false)
    let engine2 = MTCEngine(ticksPerSecond: 48_000)
    let decoder2 = LTCDecoder(sampleRate: 48_000)
    decoder2.onFrame = { engine2.ingest($0) }
    var pos = 0.0
    for _ in 0..<100 {
        loop.withUnsafeBufferPointer { decoder2.process($0.baseAddress!, count: 4800, startTime: pos, ticksPerSample: 1) }
        pos += 4800
    }
    let s2 = engine2.snapshot(now: pos)
    expect(s2.relocations == 0, "a repeating 3-frame loop caused a lock")
    print("  repeating 3-frame loop: \(s2.relocations == 0 ? "no lock" : "LOCKED (bad)")")

    // Real-world case from the show computer: a 16,384-sample chunk of 24 fps LTC
    // (01:01:34:15-21) replaying ~3 times a second after Ableton stops.
    // Afterwards, real LTC resumes elsewhere and must lock normally.
    let stuck = Array(synthesize(start: Timecode(hours: 1, minutes: 1, seconds: 34, frames: 14), rate: .fps24,
                                 realPeriod: 1.0 / 24, frames: 9, sampleRate: 48_000, amplitude: 0.2, noise: 0.002,
                                 invert: false).prefix(16_384))
    var audio: [Float] = []
    for _ in 0..<60 { audio += stuck }
    let stuckEnd = audio.count
    audio += [Float](repeating: 0, count: 24_000)
    audio += synthesize(start: Timecode(hours: 1, minutes: 5, seconds: 0, frames: 0), rate: .fps24,
                        realPeriod: 1.0 / 24, frames: 48, sampleRate: 48_000, amplitude: 0.2, noise: 0.002, invert: false)
    let engine3 = MTCEngine(ticksPerSecond: 48_000)
    let decoder3 = LTCDecoder(sampleRate: 48_000)
    decoder3.onFrame = { engine3.ingest($0) }
    var sawLoopFlag = false, lockedDuringLoop = 0
    audio.withUnsafeBufferPointer { buf in
        var i = 0
        while i + 256 <= buf.count {
            decoder3.process(buf.baseAddress! + i, count: 256, startTime: Double(i), ticksPerSample: 1)
            i += 256
            let snap = engine3.snapshot(now: Double(i))
            if i < stuckEnd {
                if snap.looping { sawLoopFlag = true }
                // The first pass can't be told apart from real playback; after that it must stay quiet.
                if i > 16_384 * 2 + 12_000, snap.status != .noSignal { lockedDuringLoop += 1 }
            }
        }
    }
    let s3 = engine3.snapshot(now: Double(audio.count))
    expect(sawLoopFlag, "stuck loop not flagged")
    expect(lockedDuringLoop == 0, "output active \(lockedDuringLoop) times during stuck loop")
    expect(s3.relocations == 2, "expected 1 lock on the loop's first pass + 1 on real LTC, got \(s3.relocations)")
    expect(s3.status == .locked && s3.lastLTC?.minutes == 5, "did not lock to real LTC after the loop")
    print("  stuck 16,384-sample loop (from show log): \(lockedDuringLoop == 0 && sawLoopFlag ? "ignored" : "NOT ignored (bad)"), then real LTC: \(s3.status.rawValue)")
}

// MARK: - Test generator + Art-Net

print("Test generator and Art-Net:")
do {
    // Receive our own Art-Net packets on the loopback interface.
    let rx = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    var on: Int32 = 1
    setsockopt(rx, SOL_SOCKET, SO_REUSEPORT, &on, 4)
    setsockopt(rx, SOL_SOCKET, SO_REUSEADDR, &on, 4)
    var tv = timeval(tv_sec: 0, tv_usec: 100_000)
    setsockopt(rx, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(6454).bigEndian
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
    let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(rx, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    expect(bound, "could not bind UDP 6454 for the Art-Net test")

    let artNet = ArtNetOutput()
    expect(artNet.setTarget("127.0.0.1"), "loopback target rejected")
    expect(!artNet.setTarget("not an ip"), "bad IP accepted")
    artNet.setTarget("127.0.0.1")

    let engine = MTCEngine(ticksPerSecond: HostClock.ticksPerSecond)
    let clock = MTCClockThread(scheduler: MTCScheduler(engine: engine), output: output, artNet: artNet)
    _ = recorder.take()
    let start = Timecode(hours: 1, minutes: 59, seconds: 59, frames: 0)
    let t0 = HostClock.now
    engine.startTest(from: start, rate: .fps25, now: t0)
    clock.start()

    var packets: [(time: Double, bytes: [UInt8])] = []
    let until = Date().addingTimeInterval(2.0)
    var buf = [UInt8](repeating: 0, count: 64)
    while Date() < until {
        let n = recv(rx, &buf, buf.count, 0)
        if n > 0 { packets.append((HostClock.now, Array(buf[0..<n]))) }
    }
    // Real LTC arriving during a test must be ignored.
    engine.ingest(LTCFrame(timecode: Timecode(hours: 5, minutes: 0, seconds: 0, frames: 0), dropFrame: false, endTime: HostClock.now))
    let midTest = engine.snapshot(now: HostClock.now)
    engine.stopTest()
    Thread.sleep(forTimeInterval: 0.2)
    let afterStop = recorder.take().count
    Thread.sleep(forTimeInterval: 0.3)
    let lateMessages = recorder.take().count
    clock.stop()
    close(rx)

    expect(midTest.status == .test, "status should be TEST while generating")
    expect(lateMessages == 0, "MTC kept flowing after stopping the test (\(lateMessages) messages)")
    _ = afterStop

    // Art-Net: one packet per frame, valid header, increasing timecode, 25 fps type.
    let period = HostClock.ticksPerSecond / 25
    var worstMs = 0.0, badHeader = 0, nonSequential = 0
    var previous: Timecode?
    for p in packets {
        let b = p.bytes
        guard b.count == 19, Array(b[0..<8]) == Array("Art-Net".utf8) + [0], b[8] == 0x00, b[9] == 0x97, b[11] == 14, b[18] == 1 else { badHeader += 1; continue }
        let tc = Timecode(hours: Int(b[17]), minutes: Int(b[16]), seconds: Int(b[15]), frames: Int(b[14]))
        if let prev = previous, !MTCEngine.isSuccessor(prev, tc) { nonSequential += 1 }
        previous = tc
        let expected = Double(start.frameCount(rate: .fps25)) + (p.time - t0) / period
        worstMs = max(worstMs, abs(Double(tc.frameCount(rate: .fps25)) - expected.rounded(.down)) > 1 ? 99 : abs(Double(tc.frameCount(rate: .fps25)) - expected) * 40)
    }
    let wrapped = packets.contains { $0.bytes.count == 19 && $0.bytes[17] == 2 && $0.bytes[16] == 0 }
    print("  Art-Net: \(packets.count) packets in 2 s (expect ~50), bad \(badHeader), out of order \(nonSequential), crossed 02:00:00:00: \(wrapped)")
    expect(packets.count >= 48 && packets.count <= 52, "Art-Net packet count \(packets.count)")
    expect(badHeader == 0 && nonSequential == 0, "Art-Net packets malformed or out of order")
    expect(wrapped, "Art-Net timecode didn't advance across the hour")
    expect(worstMs < 45, "Art-Net timing off by \(worstMs) ms")
    print("  generator: status \(midTest.status.rawValue) while running (LTC ignored), stops cleanly: \(lateMessages == 0)")
}

// MARK: - Sending to a MIDI destination (how the app outputs: IAC buses, network sessions)

print("Send to MIDI destination:")
do {
    // A private destination stands in for an IAC bus, so nothing reaches real ports.
    let received = Recorder()
    var destClient = MIDIClientRef()
    MIDIClientCreateWithBlock("SelfTest Dest" as CFString, &destClient, nil)
    var dest = MIDIEndpointRef()
    MIDIDestinationCreateWithBlock(destClient, "LTC Bridge Test Destination" as CFString, &dest) { list, _ in
        var p = list.pointee.packet
        for _ in 0..<list.pointee.numPackets {
            let bytes = withUnsafeBytes(of: p.data) { Array($0.prefix(Int(p.length))) }
            received.add(Received(time: HostClock.now, bytes: bytes))
            p = MIDIPacketNext(&p).pointee
        }
    }
    var destID: MIDIUniqueID = 0
    MIDIObjectGetIntegerProperty(dest, kMIDIPropertyUniqueID, &destID)
    Thread.sleep(forTimeInterval: 0.3)
    let listed = MIDIOutput.destinations().contains { $0.id == destID }
    expect(listed, "test destination not listed")

    let appOutput = try MIDIOutput()          // destinations only, like the app
    appOutput.setDestinations([destID])
    let engine = MTCEngine(ticksPerSecond: HostClock.ticksPerSecond)
    let clock = MTCClockThread(scheduler: MTCScheduler(engine: engine), output: appOutput)
    engine.startTest(from: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0), rate: .fps30, now: HostClock.now)
    clock.start()
    Thread.sleep(forTimeInterval: 1.0)
    appOutput.setDestinations([])             // nothing ticked: nothing should arrive
    Thread.sleep(forTimeInterval: 0.1)
    let got = received.take()
    Thread.sleep(forTimeInterval: 0.5)
    let afterUntick = received.take().count
    clock.stop(); engine.stopTest()
    let quarters = got.filter { $0.bytes.first == 0xF1 }.count
    let full = got.filter { $0.bytes.first == 0xF0 }.count
    print("  1 s at 30 fps: \(quarters) quarter-frames (expect ~120), \(full) full-frame; after unticking: \(afterUntick) messages")
    expect(quarters >= 112 && quarters <= 128, "destination received \(quarters) quarter-frames")
    expect(full == 1, "expected one full-frame message on start")
    expect(afterUntick == 0, "MTC still arrived after the destination was removed")
    MIDIEndpointDispose(dest)
}

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
