// The tap -> private aggregate -> IOProc pipeline for one routed app.
//
// The aggregate-device creation dictionary and the create/teardown ordering are
// adapted from AudioRouter (https://github.com/RaidrDev/AudioRouter), MIT License.
// See NOTICE. The render block below is an independent implementation.

import Accelerate
import AudioToolbox
import CoreAudio
import Darwin
import os

private let log = Logger(subsystem: "dev.perappvolume.engine", category: "Route")

/// State shared between the control thread and the real-time render block.
///
/// Lives in a single heap allocation captured by value by the IO block, so the block
/// holds no class reference and does no ARC traffic. Every field is word-sized, so
/// plain loads/stores across the boundary are atomic on the platforms we target;
/// a torn read is impossible and a stale read costs at most one callback.
private struct RenderState {
    var targetGain: Float = 1        // written by control thread
    var currentGain: Float = 1       // render-owned, ramps toward targetGain
    var sampleRate: Float = 48000    // set once before the IOProc starts
    var level: Float = 0             // post-gain RMS of the chosen input buffer
    var callbackCount: Int32 = 0
    var nonzeroCallbackCount: Int32 = 0  // callbacks whose input carried any energy
    var inputBufferCount: Int32 = 0
    var chosenChannels: Int32 = 0
    var chosenFrames: Int32 = 0
    var outputChannels: Int32 = 0
}

/// Routes one app's audio to one output device, at a settable gain.
///
/// While the route is running the app is muted on its normal output (the tap's
/// `.mutedWhenTapped` behavior) and its audio is played on `device` instead. The mute
/// only holds while the IOProc is reading, so stopping the route hands the audio back
/// to the default device.
public final class Route {
    /// UID prefix for the private aggregates we create. `kAudioAggregateDeviceIsPrivateKey`
    /// hides them from other processes but not from us, so they would otherwise turn up in
    /// `AudioOutputDevice.all()` as pickable destinations. Matching on the UID rather than
    /// the name avoids colliding with a device the user happens to have named the same.
    static let aggregateUIDPrefix = "PerAppVolume-"

    public let process: AudioProcess
    public let device: AudioOutputDevice

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var state: UnsafeMutablePointer<RenderState>?
    private var tapFormat = AudioStreamBasicDescription()
    private let ioQueue = DispatchQueue(
        label: "dev.perappvolume.ioproc", qos: .userInteractive)

    public init(process: AudioProcess, device: AudioOutputDevice) {
        self.process = process
        self.device = device
    }

    deinit { stop() }

    public private(set) var isRunning = false

    /// Linear gain applied to the routed audio, clamped to 0...2.
    /// Safe to set while running; the render block ramps toward it over ~20 ms.
    public var gain: Float {
        get { state?.pointee.targetGain ?? storedGain }
        set {
            let clamped = min(max(newValue, 0), 2)
            storedGain = clamped
            state?.pointee.targetGain = clamped
        }
    }
    private var storedGain: Float = 1

    /// Post-gain RMS of the audio last written, for the POC's level readout.
    public var level: Float { state?.pointee.level ?? 0 }

    /// Render-block callback counts since this pipeline started: every callback, and
    /// those whose tap input carried any energy. Both monotonic while the route runs.
    /// `callbacks` still climbing while `nonzero` sits still means the tap has gone
    /// silent even though Core Audio is still driving us.
    public var tapActivity: (callbacks: Int, nonzero: Int) {
        guard let state else { return (0, 0) }
        return (Int(state.pointee.callbackCount), Int(state.pointee.nonzeroCallbackCount))
    }

    /// One-line summary of what the render block is actually seeing. A level that
    /// stays at 0 while the app plays means the tap is delivering silence (TCC denied,
    /// or the wrong process); a moving level with a silent speaker means the output
    /// write is wrong.
    public var diagnostics: String {
        guard let state else { return "not running" }
        let s = state.pointee
        return String(
            format: "cb=%d in=%d ch=%d frames=%d out=%d rms=%.4f gain=%.2f",
            s.callbackCount, s.inputBufferCount, s.chosenChannels, s.chosenFrames,
            s.outputChannels, s.level, s.currentGain)
    }

    // MARK: - Lifecycle

    /// Blocks for a short settle delay after creating the aggregate; call off the main thread.
    public func start() throws {
        guard !isRunning else { return }
        do {
            try startPipeline()
            isRunning = true
        } catch {
            tearDown()
            throw error
        }
    }

    public func stop() {
        tearDown()
        isRunning = false
    }

    private func startPipeline() throws {
        // 1. Tap the app's process objects, muting them on their normal output for as
        //    long as we are reading the tap.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: process.objectIDs)
        let tapUID = UUID()
        tapDescription.uuid = tapUID
        tapDescription.name = "PerAppVolume-\(process.id)"
        tapDescription.muteBehavior = .mutedWhenTapped

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check("AudioHardwareCreateProcessTap",
                  AudioHardwareCreateProcessTap(tapDescription, &newTapID))
        tapID = newTapID

        // 2. The tap's real format decides the render math — never assume stereo/48k.
        tapFormat = try tapID.read(kAudioTapPropertyFormat,
                                   default: AudioStreamBasicDescription())
        log.notice("""
            tap \(self.tapID, privacy: .public) for \(self.process.id, privacy: .public): \
            \(self.tapFormat.mSampleRate, privacy: .public) Hz \
            \(self.tapFormat.mChannelsPerFrame, privacy: .public) ch \
            flags=\(self.tapFormat.mFormatFlags, privacy: .public) \
            bits=\(self.tapFormat.mBitsPerChannel, privacy: .public)
            """)
        // Verified on this hardware to be 32-bit float PCM, but the render block does raw
        // Float pointer math, so anything else must be rejected rather than misread. The
        // message carries the actual ASBD: a failure here is otherwise undiagnosable.
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32 else {
            throw CoreAudioError(
                call: """
                    unsupported tap format (expected 32-bit float PCM, got \
                    \(tapFormat.mSampleRate) Hz, \(tapFormat.mChannelsPerFrame) ch, \
                    \(tapFormat.mBitsPerChannel) bits, formatID \(tapFormat.mFormatID), \
                    flags \(tapFormat.mFormatFlags))
                    """,
                status: kAudioFormatUnsupportedDataFormatError)
        }

        // 3. A PRIVATE aggregate holding BOTH the destination device (as main sub-device)
        //    and the tap. The tap MUST be in the creation dictionary — setting the tap
        //    list afterwards via AudioObjectSetPropertyData silently does nothing.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PerAppVolume-\(process.id)",
            kAudioAggregateDeviceUIDKey: Route.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID.uuidString,
                kAudioSubTapDriftCompensationKey: 1,
            ]],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try check("AudioHardwareCreateAggregateDevice",
                  AudioHardwareCreateAggregateDevice(description as CFDictionary,
                                                     &newAggregateID))
        aggregateID = newAggregateID

        // 4. Let the aggregate settle before driving it; starting immediately after
        //    creation has been observed to produce a dead IOProc.
        usleep(200_000)

        let renderState = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
        renderState.initialize(to: RenderState())
        renderState.pointee.targetGain = storedGain
        renderState.pointee.currentGain = storedGain
        renderState.pointee.sampleRate = Float(tapFormat.mSampleRate)
        state = renderState

        // 5. One IOProc: tapped audio in, destination device out, same callback.
        //    The block captures only `renderState` (a POD pointer) by value.
        var newProcID: AudioDeviceIOProcID?
        try check("AudioDeviceCreateIOProcIDWithBlock",
                  AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue) {
                      _, inputData, _, outputData, _ in
                      Route.render(input: inputData, output: outputData, state: renderState)
                  })
        guard let newProcID else {
            throw CoreAudioError(call: "AudioDeviceCreateIOProcIDWithBlock returned nil proc",
                                 status: kAudioHardwareUnspecifiedError)
        }
        ioProcID = newProcID

        // 6. This is what triggers the system-audio-recording permission prompt.
        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, newProcID))
        log.notice("""
            routing \(self.process.name, privacy: .public) -> \
            \(self.device.name, privacy: .public) (aggregate \(self.aggregateID, privacy: .public))
            """)
    }

    private func tearDown() {
        var ioProcDestroyed = true
        if aggregateID.isValid, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            let status = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            if status != noErr {
                // The render block may still be live; leaking the state is the only
                // safe option — freeing it would let the block read released memory.
                ioProcDestroyed = false
                log.error("AudioDeviceDestroyIOProcID failed (\(status)); leaking render state")
            }
        }
        ioProcID = nil

        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if let state, ioProcDestroyed {
            storedGain = state.pointee.targetGain
            state.deallocate()
        }
        state = nil
    }

    // MARK: - Real-time render

    /// Runs on the audio thread. No allocation, no locks, no ARC, no `self`.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               state: UnsafeMutablePointer<RenderState>) {
        let inBufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBufs = UnsafeMutableAudioBufferListPointer(output)

        state.pointee.callbackCount &+= 1
        state.pointee.inputBufferCount = Int32(inBufs.count)

        // The tap is not necessarily buffer 0: a composite output device (powered
        // speakers with a line-in, a USB I/O box) contributes its own input streams to
        // this list. Pick the buffer carrying the most energy. Known limitation: a live
        // line-in louder than the tapped app would win.
        var bestBuffer: AudioBuffer?
        var bestMeanSquare: Float = -1
        for buffer in inBufs {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard samples > 0 else { continue }
            var meanSquare: Float = 0
            vDSP_measqv(data.assumingMemoryBound(to: Float.self), 1, &meanSquare,
                        vDSP_Length(min(samples, 1024)))
            if meanSquare > bestMeanSquare {
                bestMeanSquare = meanSquare
                bestBuffer = buffer
            }
        }

        guard let inBuffer = bestBuffer, let inRaw = inBuffer.mData else {
            for out in outBufs where out.mData != nil {
                memset(out.mData, 0, Int(out.mDataByteSize))
            }
            state.pointee.level = 0
            return
        }

        // Two free counters for the watchdog: callbacks still arriving but none of them
        // carrying energy is the signature of the macOS 26 tap going all-zero.
        if bestMeanSquare > 0 { state.pointee.nonzeroCallbackCount &+= 1 }

        let inChannels = Int(inBuffer.mNumberChannels)
        let inFrames = Int(inBuffer.mDataByteSize) / (MemoryLayout<Float>.size * inChannels)
        let src = inRaw.assumingMemoryBound(to: Float.self)
        state.pointee.chosenChannels = Int32(inChannels)
        state.pointee.chosenFrames = Int32(inFrames)

        // Gain ramp: one pole toward the target across the block (~20 ms time constant),
        // linearly interpolated within it, so a slider drag doesn't zipper. The ramp is a
        // function of the frame index alone, so every output channel sees the same curve.
        let startGain = state.pointee.currentGain
        let target = state.pointee.targetGain
        let sampleRate = state.pointee.sampleRate
        let alpha: Float = sampleRate > 0
            ? 1 - expf(-Float(inFrames) / (0.020 * sampleRate))
            : 1
        let endGain = startGain + (target - startGain) * alpha
        state.pointee.currentGain = endGain
        let gainStep = inFrames > 0 ? (endGain - startGain) / Float(inFrames) : 0

        // Fan the tap's channels onto the output, walking a running global channel index
        // across the buffer list. This covers interleaved output (one buffer, N channels)
        // and non-interleaved output (N single-channel buffers) with the same code. A mono
        // tap feeds every output channel; otherwise output channel N takes source channel N.
        var globalChannel = 0
        var totalOutChannels = 0
        for out in outBufs {
            guard let outRaw = out.mData, out.mNumberChannels > 0 else { continue }
            let outChannels = Int(out.mNumberChannels)
            let outFrames = Int(out.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
            let dst = outRaw.assumingMemoryBound(to: Float.self)
            let frames = min(inFrames, outFrames)
            totalOutChannels += outChannels

            for localChannel in 0..<outChannels {
                let sourceChannel = inChannels == 1 ? 0 : globalChannel + localChannel
                if sourceChannel < inChannels {
                    var frame = 0
                    while frame < frames {
                        dst[frame * outChannels + localChannel] =
                            src[frame * inChannels + sourceChannel]
                            * (startGain + gainStep * Float(frame))
                        frame += 1
                    }
                } else {
                    var frame = 0
                    while frame < frames { dst[frame * outChannels + localChannel] = 0; frame += 1 }
                }
                // Silence any frames the tap did not cover.
                var frame = frames
                while frame < outFrames { dst[frame * outChannels + localChannel] = 0; frame += 1 }
            }
            globalChannel += outChannels
        }

        state.pointee.outputChannels = Int32(totalOutChannels)
        state.pointee.level = bestMeanSquare > 0 ? bestMeanSquare.squareRoot() * endGain : 0
    }
}
