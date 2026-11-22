import AVFoundation
import Foundation
import MediaToolbox
import os

/// 全局音效参数中枢（响度平衡开关 + 5 段均衡器增益），实时同步到当前播放会话的音频处理抽头。
final class AudioEffectsHub: @unchecked Sendable {
    static let shared = AudioEffectsHub()

    struct Configuration: Equatable, Sendable {
        var loudnessEnabled: Bool = true
        var bandGainsDB: [Double] = Array(repeating: 0, count: EqualizerSpec.bandCount)
    }

    private struct State: Sendable {
        var config = Configuration()
        var activeHandles: [ObjectIdentifier: WeakTapBox] = [:]
    }

    private final class WeakTapBox: @unchecked Sendable {
        weak var context: AudioTapContext?
        init(_ context: AudioTapContext) { self.context = context }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func configure(loudnessEnabled: Bool, bandGainsDB: [Double]) {
        let normalizedBands = (0..<EqualizerSpec.bandCount).map {
            $0 < bandGainsDB.count ? EqualizerSpec.clampGain(bandGainsDB[$0]) : 0
        }
        let targets: [AudioTapContext] = state.withLock { s in
            s.config = Configuration(loudnessEnabled: loudnessEnabled, bandGainsDB: normalizedBands)
            s.activeHandles = s.activeHandles.filter { $0.value.context != nil }
            return s.activeHandles.values.compactMap(\.context)
        }
        for target in targets {
            target.updateParameters(loudnessEnabled: loudnessEnabled, bandGainsDB: normalizedBands)
        }
    }

    var currentConfiguration: Configuration {
        state.withLock { $0.config }
    }

    fileprivate func register(_ context: AudioTapContext) {
        let id = ObjectIdentifier(context)
        let config = state.withLock { s -> Configuration in
            s.activeHandles = s.activeHandles.filter { $0.value.context != nil }
            s.activeHandles[id] = WeakTapBox(context)
            return s.config
        }
        context.updateParameters(loudnessEnabled: config.loudnessEnabled, bandGainsDB: config.bandGainsDB)
    }

    fileprivate func unregister(_ context: AudioTapContext) {
        let id = ObjectIdentifier(context)
        state.withLock { _ = $0.activeHandles.removeValue(forKey: id) }
    }
}

/// 单个播放项绑定的响度 + EQ 句柄，异步测出响度后也可平滑推入实时管线。
final class AudioTapHandle: @unchecked Sendable {
    private let context: AudioTapContext
    private weak var hub: AudioEffectsHub?

    fileprivate init(context: AudioTapContext, hub: AudioEffectsHub) {
        self.context = context
        self.hub = hub
    }

    func setTrackLoudnessGain(_ gain: Float) {
        context.setTrackLoudnessGain(gain)
    }

    func detach() {
        hub?.unregister(context)
    }
}

/// 实时音频处理上下文。由 `MTAudioProcessingTap` 回调持有并在 finalize 时释放。
private final class AudioTapContext: @unchecked Sendable {
    private struct MutableState: Sendable {
        var processor = AudioEffectsProcessor()
        /// 沉浸模式用的三段电平分析；`AudioFeatureMeter` 关闭时完全不跑。
        var bandSplitter = AudioBandSplitter()
        var loudnessEnabled: Bool = true
        var trackLoudnessGain: Double = 1.0
        var bandGainsDB: [Double] = Array(repeating: 0, count: EqualizerSpec.bandCount)
        var isSupportedFloatPCM: Bool = false
        var isInterleaved: Bool = false
        var channelCount: Int = 2
    }

    private let lock = OSAllocatedUnfairLock(initialState: MutableState())

    /// 起音格子的暂存区：初始化时一次分配好，音频线程只往里写。一次回调最多切出
    /// 帧数 / 格长 个格子（4096 帧约 8 格），256 格足够任何正常的缓冲长度。
    /// 只有音频线程（`process` 串行调用）读写它，不需要锁。
    private let onsetScratch = UnsafeMutableBufferPointer<AudioOnsetFrame>.allocate(capacity: 256)

    deinit {
        onsetScratch.deallocate()
    }

    init(trackLoudnessGain: Float, config: AudioEffectsHub.Configuration) {
        let gain = min(max(Double(trackLoudnessGain), 0.35), 1.8)
        lock.withLock { s in
            s.loudnessEnabled = config.loudnessEnabled
            s.trackLoudnessGain = gain
            s.bandGainsDB = config.bandGainsDB
            s.processor.update(
                bandGainsDB: config.bandGainsDB,
                loudnessGain: config.loudnessEnabled ? gain : 1.0,
                snapGain: true
            )
        }
    }

    func setTrackLoudnessGain(_ gain: Float) {
        let clamped = min(max(Double(gain), 0.35), 1.8)
        lock.withLock { s in
            s.trackLoudnessGain = clamped
            s.processor.update(
                bandGainsDB: s.bandGainsDB,
                loudnessGain: s.loudnessEnabled ? clamped : 1.0
            )
        }
    }

    func updateParameters(loudnessEnabled: Bool, bandGainsDB: [Double]) {
        lock.withLock { s in
            s.loudnessEnabled = loudnessEnabled
            s.bandGainsDB = bandGainsDB
            s.processor.update(
                bandGainsDB: bandGainsDB,
                loudnessGain: loudnessEnabled ? s.trackLoudnessGain : 1.0
            )
        }
    }

    func prepare(format: AudioStreamBasicDescription) {
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && format.mBitsPerChannel == 32
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = max(1, Int(format.mChannelsPerFrame))
        let sr = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        lock.withLock { s in
            s.isSupportedFloatPCM = isFloat
            s.isInterleaved = !isNonInterleaved
            s.channelCount = channels
            let effectiveGain = s.loudnessEnabled ? s.trackLoudnessGain : 1.0
            s.processor.prepare(sampleRate: sr, channelCount: channels, bandGainsDB: s.bandGainsDB, loudnessGain: effectiveGain)
            s.bandSplitter.prepare(sampleRate: sr)
        }
    }

    func unprepare() {
        lock.withLock { s in
            s.processor.resetStates()
            s.bandSplitter.reset()
        }
    }

    /// - Parameter mediaTime: 这块缓冲开头在歌曲里的秒数（抽头的 `timeRangeOut`），起音格子靠它对齐歌曲时间。
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int, mediaTime: Double?) {
        nonisolated(unsafe) let rawBufferList = bufferList
        nonisolated(unsafe) let scratch = onsetScratch
        // 开关在进锁前读一次、电平在出锁后发布：两把锁不嵌套，也不把界面读快照的等待带进 EQ 临界区。
        let meter = AudioFeatureMeter.shared
        let meterEnabled = meter.isEnabled
        let (levels, onsetCount): (AudioBandLevels?, Int) = lock.withLock { s in
            guard s.isSupportedFloatPCM, frames > 0 else { return (nil, 0) }
            var onsetCount = 0
            let abl = UnsafeMutableAudioBufferListPointer(rawBufferList)
            if s.isInterleaved || abl.count == 1 {
                guard let first = abl.first, let raw = first.mData else { return (nil, 0) }
                let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                let floats = raw.bindMemory(to: Float.self, capacity: count)
                let pointer = UnsafeMutableBufferPointer(start: floats, count: count)
                s.processor.processInterleaved(pointer, frameCount: frames, stride: Int(first.mNumberChannels))
                // 分析的是 EQ / 响度处理之后、即将送去播放的同一块缓冲。
                guard meterEnabled else { return (nil, 0) }
                let levels = s.bandSplitter.analyzeInterleaved(
                    UnsafeBufferPointer(pointer), frameCount: frames, stride: Int(first.mNumberChannels),
                    mediaTime: mediaTime, onsets: scratch, onsetCount: &onsetCount
                )
                return (levels, onsetCount)
            } else {
                var pointers: [UnsafeMutableBufferPointer<Float>] = []
                pointers.reserveCapacity(abl.count)
                for buf in abl {
                    guard let raw = buf.mData else { return (nil, 0) }
                    let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                    let floats = raw.bindMemory(to: Float.self, capacity: count)
                    pointers.append(UnsafeMutableBufferPointer(start: floats, count: count))
                }
                s.processor.processPlanar(pointers, frameCount: frames)
                guard meterEnabled else { return (nil, 0) }
                let levels = s.bandSplitter.analyzePlanar(pointers, frameCount: frames, mediaTime: mediaTime,
                                                          onsets: scratch, onsetCount: &onsetCount)
                return (levels, onsetCount)
            }
        }
        if let levels {
            meter.publish(levels)
        }
        if onsetCount > 0 {
            meter.publishOnsets(UnsafeBufferPointer(rebasing: scratch[0..<onsetCount]))
        }
    }
}

/// 为 `AVAsset` 构造带有 `MTAudioProcessingTap` 的 `AVAudioMix`，挂载响度自动平衡与 5 段 EQ。
enum AudioProcessingTap {
    static func buildAudioMix(for asset: AVAsset,
                              trackLoudnessGain: Float = 1.0,
                              hub: AudioEffectsHub = .shared) async -> (mix: AVAudioMix, handle: AudioTapHandle)? {
        guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
              let audioTrack = audioTracks.first else {
            return nil
        }
        let context = AudioTapContext(trackLoudnessGain: trackLoudnessGain, config: hub.currentConfiguration)
        let retained = Unmanaged.passRetained(context).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained,
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<AudioTapContext>.fromOpaque(storage).release()
            },
            prepare: { tap, _, processingFormat in
                let storage = MTAudioProcessingTapGetStorage(tap)
                let ctx = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
                ctx.prepare(format: processingFormat.pointee)
            },
            unprepare: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                let ctx = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
                ctx.unprepare()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                var framesRead: CMItemCount = 0
                var timeRange = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, &timeRange, &framesRead
                )
                numberFramesOut.pointee = framesRead
                guard status == noErr, framesRead > 0 else { return }
                let storage = MTAudioProcessingTapGetStorage(tap)
                let ctx = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
                let start = timeRange.start
                let mediaTime: Double? = timeRange.isValid && start.isNumeric ? start.seconds : nil
                ctx.process(bufferList: bufferListInOut, frames: Int(framesRead), mediaTime: mediaTime)
            }
        )

        var tapOut: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tapOut
        )
        guard status == noErr, let createdTap = tapOut else {
            Unmanaged<AudioTapContext>.fromOpaque(retained).release()
            return nil
        }

        let params = AVMutableAudioMixInputParameters(track: audioTrack)
        params.audioTapProcessor = createdTap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        hub.register(context)
        return (mix, AudioTapHandle(context: context, hub: hub))
    }
}
