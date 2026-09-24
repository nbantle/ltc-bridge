// Opens the real view in a real window, switches between Timecode and Routing, and
// samples the window frame during the animation. Also saves mid-animation snapshots.
import AppKit
import SwiftUI

final class Holder: ObservableObject {
    @Published var mode: ViewMode = .timecode
    @Published var onTop = false
}

struct Harness: View {
    @ObservedObject var holder: Holder
    let model: AppModel
    var body: some View {
        RootView(model: model, viewMode: $holder.mode, keepOnTop: $holder.onTop)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let model = AppModel(live: false)
model.status = .locked; model.timecode = "03:00:46:08"; model.rateLabel = "24 fps"
model.devices = [AudioDevice(id: 1, uid: "dvs", name: "Dante Virtual Soundcard", inputChannels: 64)]
model.selectedDeviceUID = "dvs"
let holder = Holder()
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 780, height: 300),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.contentView = NSHostingView(rootView: Harness(holder: holder, model: model))
if let screen = NSScreen.main { window.setFrameTopLeftPoint(NSPoint(x: 200, y: screen.visibleFrame.maxY - 20)) }
window.orderFront(nil)

let out = "build/transition"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func snapshot(_ name: String) {
    guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

spin(1.0)
print(String(format: "timecode view: %.0f x %.0f, top edge %.0f", window.frame.width, window.frame.height, window.frame.maxY))
snapshot("0-timecode")

func run(to mode: ViewMode, label: String) {
    let startTop = window.frame.maxY
    holder.mode = mode
    var heights: [Double] = []
    var times: [Double] = []
    var tops: Set<Int> = []
    let t0 = Date()
    var shot = 0
    while Date().timeIntervalSince(t0) < 0.8 {
        spin(1.0 / 60)
        heights.append(window.frame.height)
        times.append(Date().timeIntervalSince(t0) * 1000)
        tops.insert(Int(window.frame.maxY.rounded()))
        let elapsed = Date().timeIntervalSince(t0)
    }
    snapshot("\(label)-end")
    let firstMove = heights.firstIndex { abs($0 - heights[0]) > 1 } ?? -1
    let settled = heights.lastIndex { abs($0 - heights.last!) > 1 }.map { $0 + 1 } ?? -1
    print("  timeline (ms: height): " + zip(times, heights).prefix(40).map { "\(Int($0.0)): \(Int($0.1))" }.joined(separator: ", "))
    var worstGap = 0.0
    for i in 1..<times.count where i <= max(settled, 1) { worstGap = max(worstGap, times[i] - times[i - 1]) }
    print("  starts moving at \(firstMove >= 0 ? Int(times[firstMove]) : -1) ms, settles at \(settled >= 0 && settled < times.count ? Int(times[settled]) : -1) ms, longest frame \(Int(worstGap)) ms")
    let distinct = Set(heights.map { Int($0) }).count
    print(String(format: "%@: height %.0f -> %.0f over %d distinct steps; top edge %@ (start %.0f)",
                 label, heights.first ?? 0, heights.last ?? 0, distinct,
                 tops.count == 1 ? "fixed" : "MOVED \(tops.sorted())", startTop))
}
run(to: .routing, label: "1-open")
spin(0.3)
run(to: .timecode, label: "2-close")
let maxH = window.contentMaxSize.height
print(String(format: "timecode view: max height %@ (content %.0f)", maxH > 10000 ? "UNLOCKED" : String(format: "locked to %.0f", maxH), window.contentView!.frame.height))

// Resize: half of a 1280-wide screen, then give the Routing view a custom height.
func resize(width: CGFloat? = nil, contentHeight: CGFloat? = nil) {
    var f = window.frame
    let chrome = f.height - window.contentView!.frame.height
    if let w = width { f.size.width = w }
    if let h = contentHeight { let newH = h + chrome; f.origin.y += f.height - newH; f.size.height = newH }
    window.setFrame(f, display: true)
    spin(0.4)
}
resize(width: 640)
print(String(format: "narrow timecode view: %.0f x %.0f, top edge %.0f", window.frame.width, window.contentView!.frame.height, window.frame.maxY))
snapshot("3-narrow-timecode")
holder.mode = .routing; spin(0.8)
print(String(format: "narrow routing view: %.0f x %.0f (fits controls), top edge %.0f", window.frame.width, window.contentView!.frame.height, window.frame.maxY))
snapshot("4-narrow-routing")
resize(contentHeight: 520)
holder.mode = .timecode; spin(0.8)
holder.mode = .routing; spin(0.8)
print(String(format: "after dragging routing to 520 and switching away and back: %.0f (expect 520), top edge %.0f", window.contentView!.frame.height, window.frame.maxY))
snapshot("5-narrow-routing-scrolled")
resize(width: 900)
snapshot("6-wide-routing")
print(String(format: "wide routing view: %.0f x %.0f", window.frame.width, window.contentView!.frame.height))
