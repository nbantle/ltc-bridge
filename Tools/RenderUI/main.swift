// Renders the app's views offscreen to PNGs for design review.
import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/ui"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func model(_ status: SyncStatus, tc: String, loop: Bool = false) -> AppModel {
    let m = AppModel(live: false)
    m.status = status
    m.timecode = tc
    m.rateLabel = "24 fps"
    m.levelDB = status == .noSignal ? -80 : -9
    m.rawLTC = status == .locked ? tc : "—"
    m.inputMessage = "48000 Hz"
    m.devices = [AudioDevice(id: 1, uid: "dvs", name: "Dante Virtual Soundcard", inputChannels: 64)]
    m.selectedDeviceUID = "dvs"
    m.loopWarning = loop
    m.interfaces = [NetworkInterface(name: "en0", address: "192.168.1.20", broadcast: "192.168.1.255")]
    m.destinations = [MIDIDestination(id: 7, name: "IAC Driver Timecode", kind: .iac),
                      MIDIDestination(id: 9, name: "IAC Driver Lyrics", kind: .iac),
                      MIDIDestination(id: 8, name: "Network Session 1", kind: .network)]
    m.destinationIDs = status == .noSignal ? [] : [7, 8]
    m.artNetChoice = "192.168.1.255"
    var seed: UInt32 = 3
    m.history = (0..<420).map { i in
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let st: SyncStatus = i < 60 ? .noSignal : (i == 250 ? .freewheel : (i > 380 && status == .noSignal ? .noSignal : .locked))
        return HistorySample(status: st, levelDB: -12 + Float(seed >> 28) - 8)
    }
    m.dropoutCount = 1
    if status == .noSignal { m.artNetChoice = "off" }
    if status == .test { m.testRunning = true }
    return m
}

func render<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat? = nil) {
    let host = NSHostingView(rootView: view
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: width, height: height, alignment: .top)
        .clipped()
        .background(Theme.background)
        .preferredColorScheme(.dark))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let size = NSSize(width: width, height: height ?? host.fittingSize.height)
    window.setContentSize(size); host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    print("wrote \(name).png \(Int(size.width))x\(Int(size.height))")
}

let states: [(SyncStatus, String, String)] = [(.locked, "03:00:46:08", "locked"), (.freewheel, "03:00:46:19", "freewheel"), (.noSignal, "03:00:47:02", "stopped"), (.test, "01:00:12:03", "test")]
for (status, tc, name) in states {
    render(MainView(model: model(status, tc: tc), viewMode: .constant(.timecode), keepOnTop: .constant(false)),
           "timecode-\(name)", width: MainView.width, height: 197)
    render(MainView(model: model(status, tc: tc, loop: status == .noSignal), viewMode: .constant(.routing), keepOnTop: .constant(status == .locked)),
           "routing-\(name)", width: MainView.width)
}
