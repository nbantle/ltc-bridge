// Owns the audio input, MTC engine and MIDI output, persists settings, and
// keeps the input running across device dropouts (e.g. Dante Virtual Soundcard restarts).

import AVFoundation
import AppKit
import Combine
import CoreMIDI
import Foundation
import ServiceManagement
import SwiftUI

/// One value that changes many times a second. Each gets its own object so only the view
/// showing it redraws: e.g. meter movement doesn't redraw the big timecode.
final class LiveValue<T: Equatable>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { if value != newValue { value = newValue } }
}

final class LiveValues {
    let timecode = LiveValue("--:--:--:--")
    let levelDB = LiveValue<Float>(-80)
    let rawLTC = LiveValue("—")
}

/// Signal-history samples, updated twice a second; only the history strip watches it.
final class HistoryStore: ObservableObject {
    @Published var samples: [HistorySample] = []
    @Published var dropoutCount = 0
}

/// The menu bar icon's visibility. SwiftUI's MenuBarExtra writes this binding back every
/// time it refreshes the icon, so writes are ignored unless the value really changes;
/// otherwise the write triggers another refresh and the app spins at 100% CPU.
final class MenuBarSettings: ObservableObject {
    @Published private(set) var showIcon: Bool

    init() { showIcon = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true }

    var binding: Binding<Bool> {
        Binding(get: { self.showIcon }, set: { self.set($0) })
    }

    func set(_ value: Bool) {
        guard value != showIcon else { return }
        showIcon = value
        UserDefaults.standard.set(value, forKey: "showMenuBarIcon")
    }
}

/// One slice of the signal-history strip.
struct HistorySample {
    var status: SyncStatus
    var levelDB: Float
}

final class AppModel: ObservableObject {
    // Settings
    @Published var devices: [AudioDevice] = []
    @Published var selectedDeviceUID: String { didSet { settingsChanged(restart: true) } }
    @Published var channel: Int { didSet { settingsChanged(restart: true) } }
    @Published var destinations: [MIDIDestination] = []
    /// Where MTC is sent: any mix of IAC buses, network sessions and other MIDI ports.
    @Published var destinationIDs: [MIDIUniqueID] { didSet { settingsChanged(restart: false) } }
    /// Last known names of chosen ports, so ones that are currently missing can still be shown.
    private var destinationNames: [String: String]
    @Published var interfaces: [NetworkInterface] = []
    /// "off", an interface broadcast address, or "custom".
    @Published var artNetChoice: String { didSet { applyArtNet() } }
    @Published var artNetCustomIP: String
    @Published var artNetValid = true
    @Published var launchAtLogin = false
    @Published var loginNote = ""
    let menuBar = MenuBarSettings()

    // Test generator
    @Published var testStartText: String
    @Published var testRate: FrameRate
    @Published var testRunning = false
    @Published var testError = false
    @Published var offsetText: String
    @Published var offsetValid = true
    @Published var freewheelFrames: Int { didSet { settingsChanged(restart: false) } }

    // Live display
    let live = LiveValues()
    @Published var status = SyncStatus.noSignal
    @Published var rateLabel = "—"
    @Published var inputMessage = ""
    @Published var micDenied = false
    @Published var jumpWarning = false
    @Published var loopWarning = false

    // Signal history: one sample per half second for the last 5 minutes.
    static let historyLength = 600
    let historyStore = HistoryStore()
    private var sliceStatus: SyncStatus?
    private var sliceLevel: Float = -80
    private var sliceTicks = 0
    private var previousStatus = SyncStatus.noSignal
    private var dropoutTimes: [Double] = []

    /// The live model, for the app delegate (quit confirmation).
    static weak var current: AppModel?
    /// The app's single live model. The App struct holds it without observing it, so model
    /// changes don't rebuild the scenes (window + menu bar icon).
    static let shared = AppModel()

    // Forwarders that only publish when the value actually changes.
    var timecode: String {
        get { live.timecode.value }
        set { live.timecode.set(newValue) }
    }
    var levelDB: Float {
        get { live.levelDB.value }
        set { live.levelDB.set(newValue) }
    }
    var rawLTC: String {
        get { live.rawLTC.value }
        set { live.rawLTC.set(newValue) }
    }
    var history: [HistorySample] {
        get { historyStore.samples }
        set { historyStore.samples = newValue }
    }
    var dropoutCount: Int {
        get { historyStore.dropoutCount }
        set { if historyStore.dropoutCount != newValue { historyStore.dropoutCount = newValue } }
    }
    var showMenuBarIcon: Bool {
        get { menuBar.showIcon }
        set { menuBar.set(newValue) }
    }

    private let engine = MTCEngine(ticksPerSecond: HostClock.ticksPerSecond)
    private let artNet = ArtNetOutput()
    private lazy var scheduler = MTCScheduler(engine: engine)
    private var midi: MIDIOutput?
    private var clock: MTCClockThread?
    private var input: AudioInput?
    private var displayTimer: Timer?
    private var watchdogTimer: Timer?
    private var activity: NSObjectProtocol?
    private var offsetRate: FrameRate = .fps30
    private var loading = true
    private let defaults = UserDefaults.standard
    private let isLive: Bool
    private var shownFrame: Int?
    private var shownGeneration = -1
    private var relocationTimes: [Double] = []
    private var lastRelocations = 0
    private var meterDB: Float = -80

    /// `live: false` builds a model with no audio/MIDI, for rendering screenshots of the UI.
    init(live: Bool = true) {
        self.isLive = live
        selectedDeviceUID = defaults.string(forKey: "deviceUID") ?? ""
        channel = defaults.object(forKey: "channel") as? Int ?? 0
        var ids = (defaults.array(forKey: "destinationIDs") as? [Int] ?? []).map { MIDIUniqueID(truncatingIfNeeded: $0) }
        let legacy = defaults.integer(forKey: "destinationID")   // single destination from v1.0-1.3
        if ids.isEmpty, legacy != 0 { ids = [MIDIUniqueID(truncatingIfNeeded: legacy)] }
        // v1.8 had an on/off switch for extra ports; if it was off, those ports weren't in use.
        if defaults.object(forKey: "alsoToEnabled") as? Bool == false { ids = [] }
        destinationIDs = ids
        destinationNames = defaults.dictionary(forKey: "destinationNames") as? [String: String] ?? [:]
        artNetChoice = defaults.string(forKey: "artNetChoice") ?? "off"
        artNetCustomIP = defaults.string(forKey: "artNetCustomIP") ?? ""
        testStartText = defaults.string(forKey: "testStart") ?? "01:00:00:00"
        testRate = FrameRate(rawValue: defaults.integer(forKey: "testRate")) ?? .fps24
        offsetText = defaults.string(forKey: "offset") ?? "00:00:00:00"
        freewheelFrames = defaults.object(forKey: "freewheelFrames") as? Int ?? 10
        loading = false
        guard live else { return }
        AppModel.current = self

        // Keep macOS from throttling timers while the app is in the background.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Generating MIDI timecode")

        do {
            let midi = try MIDIOutput()
            self.midi = midi
            let clock = MTCClockThread(scheduler: scheduler, output: midi, artNet: artNet)
            clock.start()
            self.clock = clock
        } catch {
            inputMessage = "MIDI error: \(error.localizedDescription)"
        }

        engine.freewheelFrames = freewheelFrames
        applyOffset()
        refreshLists()
        midi?.setDestinations(activeDestinationIDs)
        applyArtNet()
        refreshLoginItem()

        requestMicrophoneAccess()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.updateDisplay() }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.watchdog() }

        // For CPU profiling from the command line: LTC_AUTOSTART_TEST=1 starts the generator.
        if ProcessInfo.processInfo.environment["LTC_AUTOSTART_TEST"] != nil { startTest() }
    }

    var selectedDevice: AudioDevice? { devices.first { $0.uid == selectedDeviceUID } }

    // MARK: - Settings

    private func settingsChanged(restart: Bool) {
        guard !loading, isLive else { return }
        defaults.set(selectedDeviceUID, forKey: "deviceUID")
        defaults.set(channel, forKey: "channel")
        defaults.set(destinationIDs.map { Int($0) }, forKey: "destinationIDs")
        defaults.removeObject(forKey: "destinationID")
        defaults.removeObject(forKey: "alsoToEnabled")
        defaults.removeObject(forKey: "virtualSourceUniqueID")
        for dest in destinations where destinationIDs.contains(dest.id) { destinationNames[String(dest.id)] = dest.name }
        destinationNames = destinationNames.filter { key, _ in destinationIDs.contains { String($0) == key } }
        defaults.set(destinationNames, forKey: "destinationNames")
        defaults.set(freewheelFrames, forKey: "freewheelFrames")
        engine.freewheelFrames = freewheelFrames
        midi?.setDestinations(activeDestinationIDs)
        if restart { restartInput() }
    }

    func applyOffset() {
        if let frames = Timecode.parseOffset(offsetText, rate: offsetRate) {
            offsetValid = true
            engine.offsetFrames = frames
            defaults.set(offsetText, forKey: "offset")
        } else {
            offsetValid = false
        }
    }

    var activeDestinationIDs: [MIDIUniqueID] { destinationIDs }

    /// Chosen ports that aren't present right now (e.g. a network session that's disconnected).
    var missingDestinations: [(id: MIDIUniqueID, name: String)] {
        destinationIDs.filter { id in !destinations.contains { $0.id == id } }
            .map { ($0, destinationNames[String($0)] ?? "MIDI port \($0)") }
    }

    /// Names of the ports MTC is reaching right now.
    var connectedOutputNames: [String] {
        destinations.filter { destinationIDs.contains($0.id) }.map(\.name)
    }

    /// True when MTC isn't going anywhere (no MIDI port reachable and Art-Net off).
    var hasNoOutput: Bool { connectedOutputNames.isEmpty && artNetTarget == nil }

    func toggleDestination(_ id: MIDIUniqueID) {
        if let i = destinationIDs.firstIndex(of: id) { destinationIDs.remove(at: i) } else { destinationIDs.append(id) }
    }

    func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
    }

    // MARK: - Art-Net

    var artNetTarget: String? {
        switch artNetChoice {
        case "off": return nil
        case "custom": return artNetCustomIP.trimmingCharacters(in: .whitespaces)
        default: return artNetChoice
        }
    }

    func applyArtNet() {
        guard isLive, !loading else { return }
        defaults.set(artNetChoice, forKey: "artNetChoice")
        defaults.set(artNetCustomIP, forKey: "artNetCustomIP")
        let target = artNetTarget
        artNetValid = artNet.setTarget(target?.isEmpty == true ? nil : target)
    }

    // MARK: - Test generator

    func startTest() {
        guard let tc = Timecode.parse(testStartText, rate: testRate) else { testError = true; return }
        testError = false
        defaults.set(testStartText, forKey: "testStart")
        defaults.set(testRate.rawValue, forKey: "testRate")
        engine.startTest(from: tc, rate: testRate, now: HostClock.now)
        testRunning = true
    }

    func stopTest() {
        engine.stopTest()
        testRunning = false
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginNote = "Couldn't change: \(error.localizedDescription)"
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        switch status {
        case .requiresApproval: loginNote = "Approve in System Settings → General → Login Items"
        case .enabled: loginNote = Bundle.main.bundlePath.hasPrefix("/Applications") ? "" : "Move the app to Applications first"
        default: if !loginNote.hasPrefix("Couldn't") { loginNote = "" }
        }
    }

    // MARK: - Audio input lifecycle

    private func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            restartInput()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.micDenied = !granted
                    if granted { self.restartInput() }
                }
            }
        default:
            micDenied = true
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func restartInput() {
        input?.stop()
        input = nil
        engine.reset()
        guard !micDenied else { return }
        guard let device = selectedDevice else {
            inputMessage = selectedDeviceUID.isEmpty ? "Choose an input device" : "Waiting for device…"
            return
        }
        if channel >= device.inputChannels { channel = 0; return }  // didSet restarts
        let engine = self.engine
        let newInput = AudioInput(device: device, channel: channel,
                                  onFrame: { engine.ingest($0) },
                                  onGap: { engine.reportInputGap($0) })
        do {
            try newInput.start()
            input = newInput
            inputMessage = "\(Int(newInput.sampleRate)) Hz"
        } catch {
            inputMessage = "Can't open device: \(error.localizedDescription)"
        }
    }

    private func refreshLists() {
        let newDevices = AudioDevices.inputDevices()
        if newDevices != devices { devices = newDevices }
        if selectedDeviceUID.isEmpty, let first = devices.first {
            selectedDeviceUID = first.uid
        }
        let newDest = MIDIOutput.destinations()
        if newDest != destinations {
            destinations = newDest
            midi?.setDestinations(activeDestinationIDs)   // re-resolve ports that (re)appeared
        }
        let newInterfaces = ArtNetOutput.interfaces()
        if newInterfaces != interfaces { interfaces = newInterfaces }
    }

    private func watchdog() {
        refreshLists()
        refreshLoginItem()
        guard !micDenied else { return }
        if let input = input {
            let stale = (HostClock.now - input.lastCallbackTime) / HostClock.ticksPerSecond > 2
            let gone = selectedDevice?.id != input.device.id
            let rateChanged = AudioDevices.nominalSampleRate(input.device.id) != input.sampleRate
            if stale || gone || rateChanged {
                inputMessage = "Reconnecting…"
                restartInput()
            }
        } else if selectedDevice != nil {
            restartInput()
        }
    }

    // MARK: - Diagnostics

    /// Writes recent LTC activity to a CSV on the Desktop and reveals it.
    func saveDiagnostics() {
        let entries = engine.recentLog()
        let now = HostClock.now
        var text = "LTC Bridge diagnostics\n"
        text += "device,\(selectedDevice?.name ?? "none"),channel,\(channel + 1),sample rate,\(input.map { Int($0.sampleRate) } ?? 0),buffer frames,\(input?.framesPerCallback ?? 0)\n"
        text += "status,\(status.rawValue),rate,\(rateLabel),offset,\(offsetText),freewheel,\(freewheelFrames)\n"
        text += "dropouts in last 5 min,\(dropoutCount),art-net,\(artNetTarget ?? "off")\n\n"
        text += "seconds ago,ltc,drop frame,action,timing error (frames)\n"
        for e in entries {
            let ago = (now - e.time) / HostClock.ticksPerSecond
            text += String(format: "%.4f,%@,%@,%@,%.3f\n", ago, e.timecode.formatted(), e.dropFrame ? "yes" : "no", e.action, e.error)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appendingPathComponent("LTC Bridge Log \(formatter.string(from: Date())).csv")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            inputMessage = "Couldn't save log"
        }
    }

    // MARK: - Display

    private func updateDisplay() {
        let now = HostClock.now
        let snap = engine.snapshot(now: now)
        if snap.status != status { status = snap.status }

        if let rate = snap.rate {
            if rate.label != rateLabel { rateLabel = rate.label }
            if rate != offsetRate { offsetRate = rate; applyOffset() }
            if snap.status != .noSignal {
                // Never step backwards from tiny timing corrections; only on a real jump.
                var frame = Int(snap.position(at: now).rounded(.down))
                if snap.generation == shownGeneration, let shown = shownFrame, frame < shown { frame = shown }
                shownFrame = frame
                shownGeneration = snap.generation
                timecode = Timecode(frameCount: frame, rate: rate).formatted(dropFrame: rate.isDropFrame)
            }
        } else if rateLabel != "—" {
            rateLabel = "—"
        }

        if let ltc = snap.lastLTC, snap.lastLTCAge < 0.5 {
            rawLTC = ltc.formatted()
        } else if rawLTC != "—" {
            rawLTC = "—"
        }

        // Warn if the output keeps jumping: a looping or glitching source.
        if snap.relocations != lastRelocations {
            lastRelocations = snap.relocations
            relocationTimes.append(now)
        }
        relocationTimes.removeAll { (now - $0) / HostClock.ticksPerSecond > 10 }
        if snap.looping != loopWarning { loopWarning = snap.looping }
        let warn = relocationTimes.count >= 4 && !snap.looping
        if warn != jumpWarning { jumpWarning = warn }

        let peak = input?.peakLevel ?? 0
        let db = peak > 0 ? max(20 * log10(peak), -80) : -80
        // Fast attack, slow release, then snapped to the meter's 2.5 dB segments so the
        // meter only redraws when a segment actually lights or goes out.
        meterDB = db > meterDB ? db : max(db, meterDB - 1.5)
        levelDB = max(-80, (meterDB / 2.5).rounded(.down) * 2.5)
        if testRunning != (snap.status == .test) { testRunning = snap.status == .test }

        updateHistory(status: snap.status, db: db, now: now)
    }

    /// A dropout is LTC vanishing briefly (freewheel) and then coming back.
    private func updateHistory(status: SyncStatus, db: Float, now: Double) {
        if previousStatus == .freewheel, status == .locked { dropoutTimes.append(now) }
        previousStatus = status

        // Each slice shows the worst thing that happened in it.
        func rank(_ s: SyncStatus) -> Int { [.noSignal: 0, .test: 1, .locked: 2, .freewheel: 3][s]! }
        if let current = sliceStatus { if rank(status) > rank(current) { sliceStatus = status } } else { sliceStatus = status }
        sliceLevel = max(sliceLevel, db)
        sliceTicks += 1
        guard sliceTicks >= 15 else { return }

        var samples = history
        samples.append(HistorySample(status: sliceStatus ?? status, levelDB: sliceLevel))
        if samples.count > Self.historyLength { samples.removeFirst(samples.count - Self.historyLength) }
        history = samples
        sliceStatus = nil; sliceLevel = -80; sliceTicks = 0
        dropoutTimes.removeAll { (now - $0) / HostClock.ticksPerSecond > 300 }
        if dropoutTimes.count != dropoutCount { dropoutCount = dropoutTimes.count }
    }
}
