// Creates a private MIDI destination, records the MTC sent to it, and reports what arrived.
// Usage: mtc_monitor <seconds> [destination name]
import CoreMIDI
import Foundation

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "5") ?? 5
let name = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "LTC Bridge Monitor"
var ticksPerMs: Double = { var i = mach_timebase_info_data_t(); mach_timebase_info(&i); return 1_000_000.0 * Double(i.denom) / Double(i.numer) }()
final class Box { var items: [(Double, [UInt8])] = []; let lock = NSLock() }
let box = Box()
var client = MIDIClientRef(); MIDIClientCreateWithBlock("MTC Monitor" as CFString, &client, nil)
var dest = MIDIEndpointRef()
MIDIDestinationCreateWithBlock(client, name as CFString, &dest) { list, _ in
    let now = Double(mach_absolute_time()) / ticksPerMs
    var p = list.pointee.packet
    for _ in 0..<list.pointee.numPackets {
        let bytes = withUnsafeBytes(of: p.data) { Array($0.prefix(Int(p.length))) }
        box.lock.lock(); box.items.append((now, bytes)); box.lock.unlock()
        p = MIDIPacketNext(&p).pointee
    }
}
print("monitor ready: \(name)"); fflush(stdout)
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
box.lock.lock(); let items = box.items; box.lock.unlock()
var qf: [(Double, UInt8)] = [], full = 0
for (t, b) in items { if b.first == 0xF1, b.count >= 2 { qf.append((t, b[1])) } else if b.first == 0xF0 { full += 1 } }
print("received: \(items.count) messages, \(qf.count) quarter-frames, \(full) full-frame")
guard qf.count > 16 else { exit(1) }
var pieces = [Int](repeating: 0, count: 8), decoded: [(Double, String, Int)] = [], order = 0, expect = Int(qf[0].1 >> 4)
for (t, v) in qf {
    let piece = Int(v >> 4); if piece != expect { order += 1 }; expect = (piece + 1) & 7; pieces[piece] = Int(v & 15)
    if piece == 7 {
        let h = pieces[6] | ((pieces[7] & 1) << 4), m = pieces[4] | (pieces[5] << 4), s = pieces[2] | (pieces[3] << 4), f = pieces[0] | (pieces[1] << 4)
        decoded.append((t, String(format: "%02d:%02d:%02d:%02d", h, m, s, f), pieces[7] >> 1))
    }
}
let gaps = zip(qf.dropFirst(), qf).map { $0.0 - $1.0 }.filter { $0 < 30 }
let mean = gaps.reduce(0, +) / Double(gaps.count)
let sd = (gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)).squareRoot()
let rates = ["24", "25", "29.97DF", "30"]
print(String(format: "quarter-frame spacing: mean %.2f ms (expect %.2f at %@ fps), jitter (sd) %.2f ms, max %.2f ms", mean, 1000.0 / Double([24, 25, 29.97, 30][decoded.last!.2]) / 4, rates[decoded.last!.2], sd, gaps.max()!))
print("out of order: \(order); first \(decoded.first!.1), last \(decoded.last!.1), cycles \(decoded.count)")
