import AppKit
import CoreMIDI
import SwiftUI

enum ViewMode: String {
    case timecode
    case routing
}

// MARK: - Theme

enum Theme {
    static let background = Color(hex: 0x141416)
    static let card = Color(hex: 0x222226)
    static let control = Color(hex: 0x2E2E33)
    static let stroke = Color.white.opacity(0.07)
    static let secondary = Color(hex: 0x8E8E96)
    static let green = Color(hex: 0x3DDC84)
    static let amber = Color(hex: 0xFFB020)
    static let red = Color(hex: 0xFF453A)
    static let blue = Color(hex: 0x4DA3FF)

    static func color(_ status: SyncStatus) -> Color {
        switch status {
        case .locked: return green
        case .freewheel: return amber
        case .noSignal: return red
        case .test: return blue
        }
    }
}

extension SyncStatus {
    /// MTC is flowing from a live or test source (not freewheeling or stopped).
    var isActive: Bool { self == .locked || self == .test }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Root

struct RootView: View {
    @ObservedObject var model: AppModel
    @Binding var viewMode: ViewMode
    @Binding var keepOnTop: Bool
    @StateObject private var measured = MeasuredHeight()

    var body: some View {
        MainView(model: model, viewMode: $viewMode, keepOnTop: $keepOnTop,
                 stackCards: measured.stackCards, stackBottom: measured.stackBottom)
            .ignoresSafeArea()   // content runs under the hidden title bar; TopBar sits beside the traffic lights
            .onPreferenceChange(HeaderHeightKey.self) { if measured.header != $0 { measured.header = $0 } }
            .onPreferenceChange(RoutingHeightKey.self) { if measured.routing != $0 { measured.routing = $0 } }
            // Width is free. Height: never shorter than the timecode panel, and locked to it
            // in the Timecode view (once the shrink animation has finished).
            // SwiftUI adds the hidden title bar's height to these limits, so subtract it.
            .frame(minWidth: MainView.minWidth, maxWidth: .infinity,
                   minHeight: max(0, measured.header - measured.titleBar),
                   maxHeight: measured.locked ? max(0, measured.header - measured.titleBar) : .infinity,
                   alignment: .top)
            // Measured here, outside the content, so it's the window's width.
            .background(GeometryReader { Color.clear.preference(key: WidthKey.self, value: $0.size.width) })
            .onPreferenceChange(WidthKey.self) { measured.setWidth($0) }
            .ignoresSafeArea()
            .background(Theme.background.ignoresSafeArea())
            .background(WindowConfigurator(keepOnTop: keepOnTop, viewMode: viewMode, measured: measured,
                                           headerHeight: measured.header, routingHeight: measured.routing))
            .preferredColorScheme(.dark)
            .animation(.easeInOut(duration: 0.25), value: model.status)
    }
}

/// Measured natural heights (a plain ObservableObject, since the @State macro isn't
/// available with the Command Line Tools toolchain).
final class MeasuredHeight: ObservableObject {
    @Published var header: CGFloat = 0
    @Published var routing: CGFloat = 0
    /// True when the window height is locked to the timecode panel (Timecode view).
    @Published var locked = false
    /// Height of the hidden title bar area the content extends under.
    @Published var titleBar: CGFloat = 0
    /// Layout breakpoints, published only when crossed (not on every pixel of a resize).
    @Published private(set) var stackCards = false
    @Published private(set) var stackBottom = false

    func setWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        let cards = width < 700, bottom = width < 620
        if cards != stackCards { stackCards = cards }
        if bottom != stackBottom { stackBottom = bottom }
    }
}

struct WidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct HeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct RoutingHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Top-right controls: view switcher and keep-on-top pin.
struct TopBar: View {
    @Binding var viewMode: ViewMode
    @Binding var keepOnTop: Bool

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Button { keepOnTop.toggle() } label: {
                Image(systemName: keepOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(keepOnTop ? .black : Theme.secondary)
                    .frame(width: 26, height: 22)
                    .background(Capsule().fill(keepOnTop ? Theme.green : Theme.control))
            }
            .buttonStyle(.plain)
            .help("Keep window on top")
            PillSwitch(options: [(ViewMode.timecode, "Timecode"), (ViewMode.routing, "Routing")], selection: $viewMode)
        }
        .frame(height: 28)
    }
}

/// TXL-style segmented pill: the active segment is filled green.
struct PillSwitch<T: Equatable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                let active = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(active ? .black : Theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                        .background(Capsule().fill(active ? Theme.green : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(1)
        .background(Capsule().fill(Theme.control))
    }
}

struct TimecodeText: View {
    let text: String
    let status: SyncStatus
    let size: CGFloat

    var body: some View {
        let color = Theme.color(status)
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundColor(color)
            .shadow(color: color.opacity(status.isActive ? 0.6 : 0.25), radius: size * 0.12)
            .lineLimit(1)
            .fixedSize()
    }
}

struct StatusPill: View {
    let status: SyncStatus

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .tracking(0.8)
            .foregroundColor(.black)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Capsule().fill(Theme.color(status)))
    }
}

// MARK: - Main view

/// The timecode panel is always shown at the same size and position; in Routing mode
/// the rest of the controls slide in below it.
struct MainView: View {
    /// Default width on first launch; the window can then be resized.
    static let width: CGFloat = 780
    static let minWidth: CGFloat = 520
    /// Shared by the sliding content and the window resize so they move together.
    static let duration = 0.42
    static let curve: (Double, Double, Double, Double) = (0.33, 0.0, 0.2, 1.0)
    static let transition = Animation.timingCurve(curve.0, curve.1, curve.2, curve.3, duration: duration)

    @ObservedObject var model: AppModel
    @Binding var viewMode: ViewMode
    @Binding var keepOnTop: Bool
    var stackCards = false
    var stackBottom = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                TopBar(viewMode: $viewMode, keepOnTop: $keepOnTop)
                timecodeCard
            }
            .padding(.horizontal, 18).padding(.top, 6)
            .padding(.bottom, 18)
            .background(GeometryReader { Color.clear.preference(key: HeaderHeightKey.self, value: $0.size.height) })
            .zIndex(1)

            // Always built (so switching never stalls to create or destroy views); the window
            // height reveals or hides it, and it slides and fades in step with the resize.
            // It scrolls if the window is shorter than the controls.
            let showing = viewMode == .routing
            ScrollView(.vertical) {
                routingSection
                    .padding(.horizontal, 18).padding(.bottom, 16)
                    .background(GeometryReader { Color.clear.preference(key: RoutingHeightKey.self, value: $0.size.height) })
            }
            .opacity(showing ? 1 : 0)
            .offset(y: showing ? 0 : -28)
            .allowsHitTesting(showing)
            .accessibilityHidden(!showing)
            .animation(Self.transition, value: viewMode)
        }
    }

    private var routingSection: some View {
        VStack(spacing: 12) {
            // Side by side when there's room, stacked on narrow (e.g. half-screen) windows.
            // One set of views that re-arranges, so nothing is built twice.
            let cardsLayout = stackCards ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            cardsLayout {
                inputCard
                Wire(status: model.status, paused: viewMode != .routing, vertical: stackCards)
                outputCard
            }
            .fixedSize(horizontal: false, vertical: true)
            historyCard
            let bottomLayout = stackBottom ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            bottomLayout {
                testCard
                appCard
            }
            .fixedSize(horizontal: false, vertical: true)
            warnings
            HStack {
                Text(footerText)
                    .font(.caption).foregroundColor(Theme.secondary)
                Spacer()
                Button("Save Diagnostics") { model.saveDiagnostics() }.controlSize(.small)
            }
        }
    }

    private var timecodeCard: some View {
        let color = Theme.color(model.status)
        return VStack(spacing: 10) {
            LiveTimecode(live: model.live.timecode, status: model.status, size: 64)
            HStack(spacing: 12) {
                StatusPill(status: model.status)
                Text(model.rateLabel).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(Theme.secondary)
                if model.loopWarning, viewMode == .timecode {
                    Text("Input repeating: ignored").font(.caption).foregroundColor(Theme.amber)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.card)
                RoundedRectangle(cornerRadius: 12).fill(color.opacity(model.status.isActive ? 0.16 : 0.11))
                RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.8), lineWidth: 2)
            }
        )
    }

    private var inputCard: some View {
        Card(title: "LTC INPUT", icon: "waveform") {
            Row("Device") {
                Picker("", selection: $model.selectedDeviceUID) {
                    if model.selectedDevice == nil && !model.selectedDeviceUID.isEmpty {
                        Text("(Not connected)").tag(model.selectedDeviceUID)
                    }
                    ForEach(model.devices) { Text($0.name).tag($0.uid) }
                }.labelsHidden()
            }
            Row("Channel") {
                Picker("", selection: $model.channel) {
                    ForEach(0..<max(model.selectedDevice?.inputChannels ?? 1, 1), id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                }.labelsHidden()
            }
            Row("Level") { LiveLevelMeter(live: model.live.levelDB) }
            Row("LTC in") {
                HStack {
                    LiveRawLTC(live: model.live.rawLTC)
                    Spacer()
                    Text(model.inputMessage).font(.caption).foregroundColor(Theme.secondary)
                }
            }
        }
    }

    private var outputCard: some View {
        Card(title: "MTC OUTPUT", icon: "pianokeys") {
            Row("Send to", alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    if model.destinations.isEmpty && model.missingDestinations.isEmpty {
                        Text("No MIDI ports yet. Add an IAC bus in Audio MIDI Setup.")
                            .font(.caption).foregroundColor(Theme.amber).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.destinations) { dest in
                        Toggle(isOn: Binding(get: { model.destinationIDs.contains(dest.id) },
                                             set: { _ in model.toggleDestination(dest.id) })) {
                            HStack(spacing: 6) {
                                Text(dest.name).font(.system(size: 12)).lineLimit(1)
                                KindBadge(kind: dest.kind)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    ForEach(model.missingDestinations, id: \.id) { missing in
                        Toggle(isOn: Binding(get: { true }, set: { _ in model.toggleDestination(missing.id) })) {
                            Text("\(missing.name) (not connected)").font(.system(size: 12)).foregroundColor(Theme.secondary).lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                        .help("This port isn't available right now. MTC resumes to it when it comes back. Untick to forget it.")
                    }
                    Button("Set Up IAC or Network MIDI…") { model.openAudioMIDISetup() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            Row("Art-Net") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $model.artNetChoice) {
                        Text("Off").tag("off")
                        ForEach(model.interfaces) { Text("\($0.name) · \($0.broadcast)").tag($0.broadcast) }
                        if model.artNetChoice != "off", model.artNetChoice != "custom",
                           !model.interfaces.contains(where: { $0.broadcast == model.artNetChoice }) {
                            Text("\(model.artNetChoice) (not connected)").tag(model.artNetChoice)
                        }
                        Text("Custom IP…").tag("custom")
                    }.labelsHidden()
                    if model.artNetChoice == "custom" {
                        TextField("192.168.1.50", text: $model.artNetCustomIP, onCommit: model.applyArtNet)
                            .textFieldStyle(.roundedBorder)
                            .foregroundColor(model.artNetValid ? .primary : Theme.red)
                    }
                }
            }
            Row("Offset") {
                TextField("00:00:00:00", text: $model.offsetText, onCommit: model.applyOffset)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(model.offsetValid ? .primary : Theme.red)
                    .frame(width: 130)
            }
            Row("Freewheel") {
                Stepper("\(model.freewheelFrames) frames", value: $model.freewheelFrames, in: 0...120)
            }
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 11, weight: .bold))
                Text("SIGNAL HISTORY").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1.2)
                Text("· last 5 min").font(.system(size: 11)).foregroundColor(Theme.secondary)
                Spacer()
                DropoutCount(store: model.historyStore)
            }
            .foregroundColor(Theme.secondary)
            LiveHistoryStrip(store: model.historyStore)
                .frame(height: 30)
            HStack {
                Text("now"); Spacer(); Text("5 min ago")
            }
            .font(.system(size: 9)).foregroundColor(Theme.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
    }

    private var testCard: some View {
        Card(title: "TEST GENERATOR", icon: "play.circle", minWidth: 330) {
            Row("Start at") {
                TextField("01:00:00:00", text: $model.testStartText, onCommit: { if model.testRunning { model.startTest() } })
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(model.testError ? Theme.red : .primary)
                    .frame(width: 130)
                    .disabled(model.testRunning)
            }
            Row("Rate") {
                PillSwitch(options: FrameRate.allCases.map { ($0, $0.label.replacingOccurrences(of: " fps", with: "")) },
                           selection: $model.testRate)
                    .disabled(model.testRunning)
            }
            HStack {
                Button { model.testRunning ? model.stopTest() : model.startTest() } label: {
                    Label(model.testRunning ? "Stop Test" : "Start Test", systemImage: model.testRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 14).frame(height: 26)
                        .background(Capsule().fill(model.testRunning ? Theme.red : Theme.blue))
                }
                .buttonStyle(.plain)
                Text("Sends MTC without Ableton. Incoming LTC is ignored while running.")
                    .font(.caption).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appCard: some View {
        Card(title: "APP", icon: "gearshape", minWidth: 240) {
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            if !model.loginNote.isEmpty {
                Text(model.loginNote).font(.caption).foregroundColor(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Status light in menu bar", isOn: model.menuBar.binding)
            Text("Closing the window keeps timecode running. Reopen it from the menu bar or Dock.")
                .font(.caption).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footerText: String {
        let names = model.connectedOutputNames
        if names.isEmpty { return "Choose where to send MTC under MTC Output → Send to." }
        return "In your lighting software, select “\(names[0])” as the MIDI timecode input."
    }

    @ViewBuilder private var warnings: some View {
        if model.hasNoOutput {
            WarningRow(icon: "exclamationmark.octagon.fill", color: Theme.red,
                       text: "MTC isn't going anywhere. Tick a port under MTC Output → Send to (for example an IAC bus).") {
                Button("Audio MIDI Setup") { model.openAudioMIDISetup() }.controlSize(.small)
            }
        }
        if model.micDenied {
            WarningRow(icon: "mic.slash.fill", color: Theme.red,
                       text: "LTC Bridge needs audio input permission to hear timecode.") {
                Button("Open Settings") { model.openPrivacySettings() }.controlSize(.small)
            }
        }
        if model.loopWarning {
            WarningRow(icon: "repeat", color: Theme.amber,
                       text: "The input is replaying the same short piece of timecode (a stuck audio buffer upstream). Ignoring it.") { EmptyView() }
        }
        if model.jumpWarning {
            WarningRow(icon: "exclamationmark.triangle.fill", color: Theme.amber,
                       text: "Incoming timecode keeps jumping. Check the source or channel.") { EmptyView() }
        }
    }
}

/// Small label showing what kind of MIDI port a destination is.
struct KindBadge: View {
    let kind: MIDIDestination.Kind
    var body: some View {
        Text(kind.rawValue.uppercased())
            .font(.system(size: 8, weight: .heavy, design: .rounded)).tracking(0.6)
            .foregroundColor(kind == .iac ? Theme.green : (kind == .network ? Theme.blue : Theme.secondary))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder((kind == .iac ? Theme.green : (kind == .network ? Theme.blue : Theme.secondary)).opacity(0.6)))
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    /// Narrowest the card can get before the layout stacks cards vertically.
    var minWidth: CGFloat = 300
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1.2)
            }
            .foregroundColor(Theme.secondary)
            content
        }
        .padding(14)
        .frame(minWidth: minWidth, idealWidth: minWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
    }
}

struct Row<Content: View>: View {
    let label: String
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    init(_ label: String, alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) {
        self.label = label
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundColor(Theme.secondary).frame(width: 66, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 24)
    }
}

struct WarningRow<Accessory: View>: View {
    let icon: String
    let color: Color
    let text: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            accessory
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.5)))
    }
}

/// Patch cable between the input and output cards; the dashes flow while timecode is running.
struct Wire: View {
    let status: SyncStatus
    var paused = false
    var vertical = false

    var body: some View {
        let color = Theme.color(status)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || !status.isActive)) { context in
            Canvas { g, size in
                let r: CGFloat = 5
                let length = vertical ? size.height : size.width
                func point(_ along: CGFloat) -> CGPoint {
                    vertical ? CGPoint(x: size.width / 2, y: along) : CGPoint(x: along, y: size.height / 2)
                }
                var path = Path()
                path.move(to: point(r + 4))
                path.addLine(to: point(length - r - 4))
                g.stroke(path, with: .color(color.opacity(0.22)), lineWidth: 4)
                if status == .noSignal {
                    g.stroke(path, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5]))
                } else {
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = status.isActive ? -CGFloat((t * 36).truncatingRemainder(dividingBy: 14)) : 0
                    g.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6], dashPhase: phase))
                }
                for along in [r + 2, length - r - 2] {
                    let c = point(along)
                    let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    g.fill(dot, with: .color(Theme.background))
                    g.stroke(dot, with: .color(.white.opacity(0.85)), lineWidth: 2)
                }
            }
        }
        .frame(minWidth: vertical ? nil : 50, idealWidth: vertical ? nil : 60, maxWidth: vertical ? .infinity : 90,
               minHeight: vertical ? 44 : nil, maxHeight: vertical ? 44 : nil)
        .overlay(Text("MTC").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundColor(color)
                    .offset(x: vertical ? 26 : 0, y: vertical ? 0 : -14))
    }
}

// MARK: - Leaf views for fast-changing values
// Each observes only the small object it needs, so 30 updates a second touch these views
// and nothing else.

struct LiveTimecode: View {
    @ObservedObject var live: LiveValue<String>
    let status: SyncStatus
    let size: CGFloat
    var body: some View { TimecodeText(text: live.value, status: status, size: size) }
}

struct LiveLevelMeter: View {
    @ObservedObject var live: LiveValue<Float>
    var body: some View { LevelMeter(db: live.value) }
}

struct LiveRawLTC: View {
    @ObservedObject var live: LiveValue<String>
    var body: some View {
        Text(live.value)
            .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundColor(live.value == "—" ? Theme.secondary : Theme.green)
    }
}

struct LiveHistoryStrip: View {
    @ObservedObject var store: HistoryStore
    var body: some View { HistoryStrip(samples: store.samples, capacity: AppModel.historyLength) }
}

struct DropoutCount: View {
    @ObservedObject var store: HistoryStore
    var body: some View {
        Text(store.dropoutCount == 0 ? "No dropouts" : "\(store.dropoutCount) dropout\(store.dropoutCount == 1 ? "" : "s")")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(store.dropoutCount == 0 ? Theme.secondary : Theme.amber)
    }
}

/// Timeline of recent signal state: bar height is the input level, color is the status.
struct HistoryStrip: View {
    let samples: [HistorySample]
    let capacity: Int

    var body: some View {
        Canvas { g, size in
            let w = size.width / CGFloat(capacity)
            g.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Color.black.opacity(0.25)))
            // Newest on the left; older samples move right.
            for (i, sample) in samples.reversed().enumerated() {
                let x = CGFloat(i) * w
                let color = Theme.color(sample.status)
                let fraction = CGFloat(min(max((sample.levelDB + 60) / 60, 0), 1))
                // Dropouts (freewheel) are drawn full height so they stand out.
                let height = sample.status == .noSignal ? 3 : (sample.status == .freewheel ? size.height : max(4, size.height * fraction))
                let rect = CGRect(x: x, y: size.height - height, width: max(w, sample.status == .freewheel ? 2 : 1), height: height)
                g.fill(Path(rect), with: .color(sample.status == .noSignal ? color.opacity(0.45) : color))
            }
        }
    }
}

/// LED-style segmented meter.
struct LevelMeter: View {
    var db: Float
    private let segments = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                let threshold = -60 + Float(i) * (60 / Float(segments))
                let color: Color = i >= segments - 2 ? Theme.red : (i >= segments - 6 ? Theme.amber : Theme.green)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(db > threshold ? color : color.opacity(0.13))
            }
        }
        .frame(height: 12)
    }
}

/// Applies window-level settings SwiftUI doesn't expose on macOS 13, and sizes the window
/// height when switching views (top edge held in place):
/// - Timecode view: height locked to the timecode panel; width still resizable.
/// - Routing view: freely resizable; returns to the height you last gave it, or fits the
///   controls (limited to the screen) the first time.
struct WindowConfigurator: NSViewRepresentable {
    var keepOnTop: Bool
    var viewMode: ViewMode
    let measured: MeasuredHeight
    // Passed by value too, so SwiftUI calls updateNSView when they change.
    var headerHeight: CGFloat
    var routingHeight: CGFloat

    final class Coordinator {
        var mode: ViewMode?
        var routingWindowHeight: CGFloat?   // content height the user last had in Routing view
        let animator = WindowHeightAnimator()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        let mode = viewMode, header = headerHeight, routing = routingHeight, measured = self.measured
        DispatchQueue.main.async {
            guard let window = view.window, let content = window.contentView, header > 0 else { return }
            let titleBar = window.frame.height - window.contentLayoutRect.height
            if abs(measured.titleBar - titleBar) > 0.5 { measured.titleBar = titleBar }
            window.level = keepOnTop ? .floating : .normal
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Theme.background)
            window.styleMask.insert([.resizable, .fullSizeContentView])
            guard mode != c.mode, mode == .timecode || routing > 0 else { return }

            let first = c.mode == nil
            if c.mode == .routing { c.routingWindowHeight = content.frame.height }
            c.mode = mode

            let target: CGFloat
            if mode == .timecode {
                target = header
            } else {
                let fit = header + routing
                let screen = window.screen?.visibleFrame ?? .zero
                let room = window.frame.maxY - screen.minY - (window.frame.height - content.frame.height)
                target = max(header, min(c.routingWindowHeight ?? fit, fit, room > 0 ? room : fit))
                if measured.locked { measured.locked = false }
            }
            c.animator.animate(window, toContentHeight: target, animated: !first) {
                // Lock the height only once the shrink has finished.
                if mode == .timecode, c.mode == .timecode, !measured.locked { measured.locked = true }
            }
        }
    }
}

/// Resizes a window's height along the same curve as the SwiftUI transition, one step per
/// screen refresh, keeping the top edge fixed. (AppKit's own animated resize cuts short
/// when shrinking a SwiftUI window.)
final class WindowHeightAnimator {
    private var timer: Timer?
    private var start: (height: CGFloat, time: CFTimeInterval) = (0, 0)
    private var target: CGFloat = 0
    private weak var window: NSWindow?
    private var completion: (() -> Void)?

    func animate(_ window: NSWindow, toContentHeight height: CGFloat, animated: Bool, completion: (() -> Void)? = nil) {
        guard let content = window.contentView else { return }
        let chrome = window.frame.height - content.frame.height
        let targetFrameHeight = height + chrome
        self.completion = completion
        guard abs(targetFrameHeight - (timer == nil ? window.frame.height : target)) > 0.5 else { finish(); return }
        self.window = window
        target = targetFrameHeight
        guard animated else { setHeight(targetFrameHeight); finish(); return }
        start = (window.frame.height, CACurrentMediaTime())
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.step() }
            RunLoop.main.add(t, forMode: .common)   // keeps running during mouse tracking
            timer = t
        }
        step()
    }

    private func step() {
        let progress = min((CACurrentMediaTime() - start.time) / MainView.duration, 1)
        let eased = Self.bezier(progress, MainView.curve)
        setHeight(start.height + (target - start.height) * CGFloat(eased))
        if progress >= 1 { timer?.invalidate(); timer = nil; finish() }
    }

    private func finish() {
        let done = completion
        completion = nil
        done?()
    }

    private func setHeight(_ height: CGFloat) {
        guard let window = window else { return }
        var frame = window.frame
        let h = height.rounded()
        frame.origin.y += frame.height - h   // AppKit origin is bottom-left; keep the top edge still
        frame.size.height = h
        window.setFrame(frame, display: true)
    }

    /// Evaluates a CSS-style cubic bezier timing curve at time x.
    static func bezier(_ x: Double, _ c: (Double, Double, Double, Double)) -> Double {
        func coord(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
        }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<30 {   // solve coordX(t) = x by bisection
            t = (lo + hi) / 2
            if coord(t, c.0, c.2) < x { lo = t } else { hi = t }
        }
        return coord(t, c.1, c.3)
    }
}
