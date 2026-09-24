// Decodes an LTC audio file with the app's decoder and engine and reports problems.
// Usage: decode_file <file.wav>
import AVFoundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let file = try AVAudioFile(forReading: url)
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.fileFormat.sampleRate, channels: 1, interleaved: false)!
let sr = format.sampleRate
let decoder = LTCDecoder(sampleRate: sr)
let engine = MTCEngine(ticksPerSecond: sr)
var frames = 0, gaps = 0, first: Timecode?, last: LTCFrame?, dfSeen = false
var worstJitter = 0.0, peak: Float = 0
decoder.onFrame = { f in
    engine.ingest(f)
    frames += 1
    if first == nil { first = f.timecode }
    if f.dropFrame { dfSeen = true }
    if let l = last {
        if !MTCEngine.isSuccessor(l.timecode, f.timecode) {
            gaps += 1
            if gaps <= 5 { print("  gap: \(l.timecode.formatted()) -> \(f.timecode.formatted()) at \(String(format: "%.2f", f.endTime / sr)) s") }
        } else {
            worstJitter = max(worstJitter, abs((f.endTime - l.endTime) - sr / 24))
        }
    }
    last = f
}
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
var pos = 0.0, relocs = 0, notLocked = 0
while file.framePosition < file.length {
    try file.read(into: buffer, frameCount: 256)
    let n = Int(buffer.frameLength); if n == 0 { break }
    let p = buffer.floatChannelData![0]
    for i in 0..<n { peak = max(peak, abs(p[i])) }
    decoder.process(p, count: n, startTime: pos, ticksPerSample: 1)
    pos += Double(n)
    let s = engine.snapshot(now: pos)
    if pos > sr, pos < Double(file.length) - sr, s.status != .locked { notLocked += 1 }
    relocs = s.relocations
}
let s = engine.snapshot(now: pos)
print("  sample rate \(Int(sr)) Hz, peak level \(String(format: "%.1f", 20 * log10(peak))) dBFS")
print("  decoded \(frames) frames (expected \(Int(Double(file.length) / sr * 24))), first \(first?.formatted() ?? "-"), last \(last?.timecode.formatted() ?? "-")")
print("  rate detected: \(s.rate?.label ?? "none"), drop-frame flag: \(dfSeen ? "yes" : "no")")
print("  discontinuities: \(gaps), output relocations: \(relocs), buffers not LOCKED mid-file: \(notLocked)")
print("  worst frame-timing deviation: \(String(format: "%.2f", worstJitter)) samples")
