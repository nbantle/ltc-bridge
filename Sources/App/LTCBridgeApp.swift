import AppKit
import SwiftUI

@main
struct LTCBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Not observed here: observing the model would rebuild both scenes on every change.
    private let model = AppModel.shared
    @ObservedObject private var menuBar = AppModel.shared.menuBar
    @AppStorage("viewMode") private var viewMode = ViewMode.routing
    @AppStorage("keepOnTop") private var keepOnTop = false

    var body: some Scene {
        Window("LTC Bridge", id: "main") {
            RootView(model: model, viewMode: $viewMode, keepOnTop: $keepOnTop)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: MainView.width, height: 200)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(before: .toolbar) {
                Button("Timecode Only") { viewMode = .timecode }.keyboardShortcut("1")
                Button("Routing") { viewMode = .routing }.keyboardShortcut("2")
                Toggle("Keep on Top", isOn: $keepOnTop).keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
            }
        }

        MenuBarExtra(isInserted: menuBar.binding) {
            MenuBarMenu(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Closing the window must not stop MTC; the app keeps running in the Dock and menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.current, model.status != .noSignal else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Timecode is running"
        alert.informativeText = "Quitting LTC Bridge stops MIDI timecode to your lighting software."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// The dot itself; redraws only when the model publishes (status or settings changes).
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View { Image(nsImage: StatusDot.image(for: model.status)) }
}

/// Contents of the menu bar icon's menu.
struct MenuBarMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(model.status.rawValue)  \(model.timecode)")
        Text("\(model.selectedDevice?.name ?? "No input"), channel \(model.channel + 1)")
        Text(model.connectedOutputNames.isEmpty ? "Output: none selected" : "Output: " + model.connectedOutputNames.joined(separator: ", "))
        if model.dropoutCount > 0 { Text("\(model.dropoutCount) dropout\(model.dropoutCount == 1 ? "" : "s") in last 5 min") }
        Divider()
        Button("Show LTC Bridge") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Hide Menu Bar Icon") { model.showMenuBarIcon = false }
        Divider()
        Button("Quit LTC Bridge") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// A full-color dot for the menu bar (not a template image, so it keeps its color).
enum StatusDot {
    private static var cache: [SyncStatus: NSImage] = [:]

    static func image(for status: SyncStatus) -> NSImage {
        if let cached = cache[status] { return cached }
        let color: NSColor
        switch status {
        case .locked: color = NSColor(Theme.green)
        case .freewheel: color = NSColor(Theme.amber)
        case .noSignal: color = NSColor(Theme.red)
        case .test: color = NSColor(Theme.blue)
        }
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)); ring.lineWidth = 1; ring.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = status.rawValue
        cache[status] = image
        return image
    }
}
