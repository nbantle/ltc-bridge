// macOS audio capture via CoreAudio's AUHAL, reading one channel of any input
// device (e.g. Dante Virtual Soundcard) with a small IO buffer.

import AudioToolbox
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
}

enum HostClock {
    static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1_000_000_000.0 * Double(info.denom) / Double(info.numer)
    }()

    static var now: Double { Double(mach_absolute_time()) }
}

enum AudioDevices {
    static func inputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, inputChannels: channels)
        }
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return rate
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

/// Captures a single channel from an input device and feeds an LTCDecoder.
final class AudioInput {
    let device: AudioDevice
    let channel: Int
    private(set) var sampleRate: Double = 0
    private var unit: AudioUnit?
    private var decoder: LTCDecoder?
    private var buffer: UnsafeMutablePointer<Float>
    private let bufferCapacity = 8192
    private var ticksPerSample = 0.0
    private var sampleClock: SampleClock?
    private let onFrame: (LTCFrame) -> Void
    private let onGap: (Double) -> Void

    /// Updated from the audio thread; read by the UI and watchdog.
    private(set) var lastCallbackTime: Double = 0
    private(set) var peakLevel: Float = 0
    private(set) var framesPerCallback = 0

    init(device: AudioDevice, channel: Int, onFrame: @escaping (LTCFrame) -> Void, onGap: @escaping (Double) -> Void) {
        self.device = device
        self.channel = channel
        self.onFrame = onFrame
        self.onGap = onGap
        buffer = .allocate(capacity: bufferCapacity)
    }

    deinit {
        stop()
        buffer.deallocate()
    }

    func start() throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw AudioError("AUHAL not found") }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "create audio unit")
        guard let unit = newUnit else { throw AudioError("create audio unit") }
        self.unit = unit

        var one: UInt32 = 1, zero: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "disable output")

        var deviceID = device.id
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "select device")

        // Ask for a small per-process IO buffer (~5 ms) for low latency.
        var frames: UInt32 = 256
        var bufAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device.id, &bufAddress, 0, nil, 4, &frames)

        var hwFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hwFormat, &size), "read format")
        sampleRate = hwFormat.mSampleRate > 0 ? hwFormat.mSampleRate : AudioDevices.nominalSampleRate(device.id)
        ticksPerSample = HostClock.ticksPerSecond / sampleRate
        sampleClock = SampleClock(sampleRate: sampleRate, ticksPerSecond: HostClock.ticksPerSecond)

        // Mono float output, mapped to the chosen device channel.
        var client = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                 mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "set format")
        var map: [Int32] = [Int32(channel)]
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &map, 4), "map channel")

        let decoder = LTCDecoder(sampleRate: sampleRate)
        decoder.onFrame = onFrame
        self.decoder = decoder

        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, timeStamp, bus, frameCount, _ in
            let input = Unmanaged<AudioInput>.fromOpaque(refCon).takeUnretainedValue()
            return input.render(flags, timeStamp, bus, frameCount)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set callback")

        try check(AudioUnitInitialize(unit), "initialize")
        try check(AudioOutputUnitStart(unit), "start")
        lastCallbackTime = HostClock.now
    }

    func stop() {
        guard let unit = unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        _ timeStamp: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frameCount: UInt32) -> OSStatus {
        guard let unit = unit, let decoder = decoder else { return noErr }
        let count = min(Int(frameCount), bufferCapacity)
        var list = AudioBufferList(mNumberBuffers: 1,
                                   mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4),
                                                         mData: UnsafeMutableRawPointer(buffer)))
        let status = AudioUnitRender(unit, flags, timeStamp, bus, UInt32(count), &list)
        guard status == noErr else { return status }

        let now = HostClock.now
        let ts = timeStamp.pointee
        let observed = ts.mFlags.contains(.hostTimeValid)
            ? Double(ts.mHostTime)
            : now - Double(count) * ticksPerSample
        let clock = sampleClock!
        let start = clock.timestamp(observed: observed, frames: count)
        decoder.process(buffer, count: count, startTime: start, ticksPerSample: clock.currentTicksPerSample)
        peakLevel = decoder.peakLevel
        framesPerCallback = count
        onGap(now - lastCallbackTime)
        lastCallbackTime = now
        return noErr
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw AudioError("\(what) failed (\(status))") }
    }
}

struct AudioError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
