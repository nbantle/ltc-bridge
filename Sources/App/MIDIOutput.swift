// macOS MIDI output: sends MTC to existing MIDI destinations such as IAC buses and
// network sessions. (A virtual source is optional; only the self-test uses one.)

import CoreMIDI
import Foundation

struct MIDIDestination: Identifiable, Hashable {
    enum Kind: String { case iac = "IAC", network = "Network", device = "Device", app = "App" }
    let id: MIDIUniqueID
    let name: String
    let kind: Kind
}

final class MIDIOutput {
    private var client = MIDIClientRef()
    private var source: MIDIEndpointRef?
    private var outPort = MIDIPortRef()
    private let lock = NSLock()
    private var destinations: [MIDIEndpointRef] = []

    /// - Parameter virtualSourceName: also publish MTC on a virtual source with this name
    ///   (nil = destinations only).
    init(virtualSourceName: String? = nil) throws {
        try check(MIDIClientCreateWithBlock("LTC Bridge" as CFString, &client, nil), "create MIDI client")
        try check(MIDIOutputPortCreate(client, "Output" as CFString, &outPort), "create output port")
        if let name = virtualSourceName {
            var endpoint = MIDIEndpointRef()
            try check(MIDISourceCreate(client, name as CFString, &endpoint), "create virtual source")
            source = endpoint
        }
    }

    deinit {
        if let source = source { MIDIEndpointDispose(source) }
        MIDIClientDispose(client)
    }

    static func destinations() -> [MIDIDestination] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { i in
            let endpoint = MIDIGetDestination(i)
            var id: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id)
            guard let name = string(endpoint, kMIDIPropertyDisplayName) else { return nil }
            // Endpoints inherit the driver owner from their device.
            let owner = string(endpoint, kMIDIPropertyDriverOwner) ?? ""
            let kind: MIDIDestination.Kind
            if owner.contains("IACDriver") || name.hasPrefix("IAC Driver") { kind = .iac }
            else if owner.contains("RTPDriver") || owner.contains("Network") || name.contains("Network") || name.contains("Session") { kind = .network }
            else if owner.isEmpty { kind = .app }   // another app's virtual destination
            else { kind = .device }
            return MIDIDestination(id: id, name: name, kind: kind)
        }
    }

    private static func string(_ object: MIDIObjectRef, _ property: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// The destinations MTC is sent to, e.g. IAC buses or network MIDI sessions.
    func setDestinations(_ ids: [MIDIUniqueID]) {
        let endpoints: [MIDIEndpointRef] = ids.compactMap { id in
            var object = MIDIObjectRef()
            var type = MIDIObjectType.destination
            return MIDIObjectFindByUniqueID(id, &object, &type) == noErr ? object : nil
        }
        lock.lock(); destinations = endpoints; lock.unlock()
    }

    /// Sends messages immediately. Called from the MTC scheduler thread.
    func send(_ messages: [[UInt8]]) {
        guard !messages.isEmpty else { return }
        let bytes = messages.reduce(0) { $0 + $1.count }
        let capacity = 64 + bytes + messages.count * 16
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 4)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: MIDIPacketList.self)
        var packet = MIDIPacketListInit(list)
        let now = mach_absolute_time()
        for message in messages {
            packet = message.withUnsafeBufferPointer {
                MIDIPacketListAdd(list, capacity, packet, now, message.count, $0.baseAddress!)
            }
        }
        if let source = source { MIDIReceived(source, list) }
        lock.lock(); let dests = destinations; lock.unlock()
        for dest in dests { MIDISend(outPort, dest, list) }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw AudioError("\(what) failed (\(status))") }
    }
}

/// Real-time thread that drives MTCScheduler and sends its output.
final class MTCClockThread {
    private let scheduler: MTCScheduler
    private let output: MIDIOutput
    private let artNet: ArtNetOutput?
    private var thread: Thread?
    private var stopped = false

    init(scheduler: MTCScheduler, output: MIDIOutput, artNet: ArtNetOutput? = nil) {
        self.scheduler = scheduler
        self.output = output
        self.artNet = artNet
    }

    func start() {
        let t = Thread { [unowned self] in self.run() }
        t.name = "MTC clock"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() { stopped = true }

    private func run() {
        Self.makeRealtime()
        let maxSleep = 0.005 * HostClock.ticksPerSecond
        while !stopped {
            let now = HostClock.now
            let result = scheduler.poll(now: now)
            output.send(result.messages)
            if !result.frames.isEmpty { artNet?.send(result.frames, rate: result.rate) }
            let wake = min(result.wakeAt, HostClock.now + maxSleep)
            if wake > HostClock.now { mach_wait_until(UInt64(wake)) }
        }
    }

    /// Time-constraint scheduling so quarter-frames go out within microseconds of their due time.
    private static func makeRealtime() {
        let ms = HostClock.ticksPerSecond / 1000
        var policy = thread_time_constraint_policy_data_t(period: UInt32(2 * ms), computation: UInt32(0.3 * ms),
                                                          constraint: UInt32(1 * ms), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }
}
