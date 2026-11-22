import Accelerate
@preconcurrency import AVFoundation
import Foundation

enum VoiceAudioDSPError: Error, LocalizedError, Sendable {
    case unreadableAudioFile(String)
    case unsupportedAudioFormat(String)
    case resampleFailed(String)
    case writeFailed(String)
    case invalidFFTSize(Int)

    var errorDescription: String? {
        switch self {
        case .unreadableAudioFile(let detail):
            return "无法读取音频文件: \(detail)"
        case .unsupportedAudioFormat(let detail):
            return "不支持的音频格式: \(detail)"
        case .resampleFailed(let detail):
            return "音频重采样失败: \(detail)"
        case .writeFailed(let detail):
            return "音频导出失败: \(detail)"
        case .invalidFFTSize(let nFFT):
            return "无效或不受支持的 FFT 大小: \(nFFT)"
        }
    }
}

/// 纯原生音频解码、重采样、Accelerate(vDSP) STFT/ISTFT、梅尔谱与混音工具。
enum VoiceAudioDSP {
    // scipy.signal.butter(N=5, Wn=48, btype="high", fs=16000, output="sos")
    private static let butter48HzSOS: [[Double]] = [
        [0.9699606451838447, -0.9699606451838447, 0.0, 1.0, -0.9813258904926881, 0.0],
        [1.0, -2.0, 1.0, 1.0, -1.9696106864374547, 0.9699606452559844],
        [1.0, -2.0, 1.0, 1.0, -1.9880652422382208, 0.9884184800471566],
    ]
    private static let butter48HzZI: [[Double]] = [
        [-0.9699606451838447, 0.0],
        [0.0, 0.0],
        [0.0, 0.0],
    ]

    private static let rmvpeMelBasis: [Float] = makeMelFilterBank(
        sampleRate: 16_000,
        nFFT: 1024,
        nMels: 128,
        fMin: 30,
        fMax: 8_000
    )

    // MARK: - 音频读写与重采样

    static func audioDurationSeconds(url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else {
            return 0
        }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return 0 }
        return Double(file.length) / sr
    }

    static func decodeMono(url: URL, targetSampleRate: Double) throws -> [Float] {
        let stereo = try decodeStereo(url: url, targetSampleRate: targetSampleRate)
        let n = stereo.left.count
        guard n > 0 else { return [] }
        var mono = [Float](repeating: 0, count: n)
        var half: Float = 0.5
        vDSP_vadd(stereo.left, 1, stereo.right, 1, &mono, 1, vDSP_Length(n))
        vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(n))
        return mono
    }

    static func decodeStereo(url: URL, targetSampleRate: Double) throws -> (left: [Float], right: [Float]) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw VoiceAudioDSPError.unreadableAudioFile("\(url.lastPathComponent): \(error.localizedDescription)")
        }

        guard let readFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.fileFormat.sampleRate,
            channels: file.fileFormat.channelCount,
            interleaved: false
        ) else {
            throw VoiceAudioDSPError.unsupportedAudioFormat(url.lastPathComponent)
        }

        let totalFrames = AVAudioFrameCount(max(file.length, 0))
        if totalFrames == 0 {
            return ([], [])
        }

        var rawChannels: [[Float]] = Array(
            repeating: [Float](repeating: 0, count: Int(totalFrames)),
            count: Int(readFormat.channelCount)
        )
        var readOffset = 0
        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: chunkFrames) else {
            throw VoiceAudioDSPError.unsupportedAudioFormat("无法分配读取缓冲")
        }

        file.framePosition = 0
        while readOffset < Int(totalFrames) {
            try Task.checkCancellation()
            let remaining = AVAudioFrameCount(Int(totalFrames) - readOffset)
            let toRead = min(chunkFrames, remaining)
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: toRead)
            let got = Int(buffer.frameLength)
            if got == 0 { break }
            guard let ptrs = buffer.floatChannelData else {
                throw VoiceAudioDSPError.unreadableAudioFile("空 Float32 声道指针")
            }
            for ch in 0..<Int(readFormat.channelCount) {
                rawChannels[ch].replaceSubrange(
                    readOffset..<(readOffset + got),
                    with: UnsafeBufferPointer(start: ptrs[ch], count: got)
                )
            }
            readOffset += got
        }

        if readOffset < Int(totalFrames) {
            for ch in 0..<rawChannels.count {
                rawChannels[ch].removeSubrange(readOffset..<Int(totalFrames))
            }
        }

        let leftRaw = rawChannels[0]
        let rightRaw = rawChannels.count > 1 ? rawChannels[1] : rawChannels[0]

        let sourceSR = file.fileFormat.sampleRate
        if abs(sourceSR - targetSampleRate) < 0.5 {
            return (leftRaw, rightRaw)
        }
        let leftOut = try resample(leftRaw, from: sourceSR, to: targetSampleRate)
        let rightOut = try resample(rightRaw, from: sourceSR, to: targetSampleRate)
        let minLen = min(leftOut.count, rightOut.count)
        if leftOut.count == rightOut.count {
            return (leftOut, rightOut)
        }
        return (Array(leftOut.prefix(minLen)), Array(rightOut.prefix(minLen)))
    }

    static func resample(_ samples: [Float], from sourceSR: Double, to targetSR: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        if abs(sourceSR - targetSR) < 0.5 { return samples }

        guard let inFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSR,
            channels: 1,
            interleaved: false
        ),
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSR,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw VoiceAudioDSPError.resampleFailed("无法构造 AVAudioConverter (\(sourceSR) -> \(targetSR))")
        }

        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let ratio = targetSR / sourceSR
        let inChunkCap: Int = 16_384
        let outChunkCap: AVAudioFrameCount = 32_768
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(inChunkCap)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outChunkCap) else {
            throw VoiceAudioDSPError.resampleFailed("无法分配重采样缓冲")
        }

        var output: [Float] = []
        output.reserveCapacity(Int(Double(samples.count) * ratio) + 256)

        final class InputFeedState: @unchecked Sendable {
            var offset = 0
        }
        let feedState = InputFeedState()

        while true {
            var err: NSError?
            outBuffer.frameLength = 0
            let status = converter.convert(to: outBuffer, error: &err) { packetCount, outStatus in
                let remaining = samples.count - feedState.offset
                guard remaining > 0 else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let count = min(inChunkCap, remaining, max(Int(packetCount), 1))
                inBuffer.frameLength = AVAudioFrameCount(count)
                if let dst = inBuffer.floatChannelData?[0] {
                    samples.withUnsafeBufferPointer { src in
                        if let base = src.baseAddress {
                            dst.update(from: base + feedState.offset, count: count)
                        }
                    }
                }
                feedState.offset += count
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let err {
                throw VoiceAudioDSPError.resampleFailed(err.localizedDescription)
            }
            if outBuffer.frameLength > 0, let ptr = outBuffer.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error || status == .inputRanDry {
                break
            }
        }
        return output
    }

    static func aacCompatibleSampleRate(for sampleRate: Int) -> Int {
        switch sampleRate {
        case 32_000, 44_100, 48_000:
            return sampleRate
        default:
            return 44_100
        }
    }

    /// 导出 256kbps AAC `.m4a` 文件；若源采样率不支持 AAC（如 40kHz）则自动高质量重采样至 44.1kHz。
    static func writeM4A(
        left: [Float],
        right: [Float],
        sampleRate: Double,
        to outputURL: URL
    ) throws -> (url: URL, duration: TimeInterval, sampleRate: Int) {
        let count = min(left.count, right.count)
        let targetSRInt = aacCompatibleSampleRate(for: Int(sampleRate.rounded()))
        let targetSR = Double(targetSRInt)

        let outLeft: [Float]
        let outRight: [Float]
        if abs(sampleRate - targetSR) >= 0.5 {
            outLeft = try resample(Array(left.prefix(count)), from: sampleRate, to: targetSR)
            outRight = try resample(Array(right.prefix(count)), from: sampleRate, to: targetSR)
        } else {
            outLeft = Array(left.prefix(count))
            outRight = Array(right.prefix(count))
        }
        let finalCount = min(outLeft.count, outRight.count)

        let fm = FileManager.default
        let dir = outputURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSR,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ]
        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSR,
            channels: 2,
            interleaved: false
        ) else {
            throw VoiceAudioDSPError.writeFailed("无法创建写入格式")
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw VoiceAudioDSPError.writeFailed("\(outputURL.lastPathComponent): \(error.localizedDescription)")
        }

        let chunkCap = 32_768
        guard let buf = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(chunkCap)) else {
            throw VoiceAudioDSPError.writeFailed("无法分配写入缓冲")
        }

        var offset = 0
        while offset < finalCount {
            let n = min(chunkCap, finalCount - offset)
            buf.frameLength = AVAudioFrameCount(n)
            if let chData = buf.floatChannelData {
                outLeft.withUnsafeBufferPointer { srcL in
                    if let p = srcL.baseAddress {
                        chData[0].update(from: p + offset, count: n)
                    }
                }
                outRight.withUnsafeBufferPointer { srcR in
                    if let p = srcR.baseAddress {
                        chData[1].update(from: p + offset, count: n)
                    }
                }
            }
            try file.write(from: buf)
            offset += n
        }

        let duration = targetSR > 0 ? Double(finalCount) / targetSR : 0
        return (outputURL, duration, targetSRInt)
    }

    /// 写入无损 PCM16 WAV（供 separation / conversion 中间缓存复用，零编码压缩损失）。
    static func writeWAV(
        left: [Float],
        right: [Float]?,
        sampleRate: Double,
        to outputURL: URL
    ) throws {
        let channels: AVAudioChannelCount = right == nil ? 1 : 2
        let count = right.map { min(left.count, $0.count) } ?? left.count
        let fm = FileManager.default
        try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw VoiceAudioDSPError.writeFailed("无法创建 WAV 音频格式")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw VoiceAudioDSPError.writeFailed("\(outputURL.lastPathComponent): \(error.localizedDescription)")
        }

        let chunkCap = 32_768
        guard let buf = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(chunkCap)) else {
            throw VoiceAudioDSPError.writeFailed("无法分配 WAV 写缓冲")
        }
        var offset = 0
        while offset < count {
            let n = min(chunkCap, count - offset)
            buf.frameLength = AVAudioFrameCount(n)
            if let ch = buf.floatChannelData {
                left.withUnsafeBufferPointer { lSrc in
                    if let p = lSrc.baseAddress { ch[0].update(from: p + offset, count: n) }
                }
                if let right {
                    right.withUnsafeBufferPointer { rSrc in
                        if let p = rSrc.baseAddress { ch[1].update(from: p + offset, count: n) }
                    }
                }
            }
            try file.write(from: buf)
            offset += n
        }
    }

    /// 将立体声或单声道人声与立体声伴奏混合，并限幅在 [-0.99, 0.99] 防止削波。
    static func mixVocalAndInstrumental(
        vocalLeft: [Float],
        vocalRight: [Float]?,
        instLeft: [Float],
        instRight: [Float],
        vocalGain: Float = 1.0,
        instGain: Float = 1.0
    ) -> (left: [Float], right: [Float]) {
        let vR = vocalRight ?? vocalLeft
        let n = max(vocalLeft.count, instLeft.count)
        guard n > 0 else { return ([], []) }

        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)

        let vLen = min(vocalLeft.count, vR.count)
        let iLen = min(instLeft.count, instRight.count)

        for i in 0..<n {
            let vl = i < vLen ? vocalLeft[i] * vocalGain : 0
            let vr = i < vLen ? vR[i] * vocalGain : 0
            let il = i < iLen ? instLeft[i] * instGain : 0
            let ir = i < iLen ? instRight[i] * instGain : 0
            outL[i] = vl + il
            outR[i] = vr + ir
        }

        var peakL: Float = 0
        var peakR: Float = 0
        vDSP_maxmgv(outL, 1, &peakL, vDSP_Length(n))
        vDSP_maxmgv(outR, 1, &peakR, vDSP_Length(n))
        let peak = max(peakL, peakR)
        if peak > 0.99 {
            var scale = 0.99 / peak
            vDSP_vsmul(outL, 1, &scale, &outL, 1, vDSP_Length(n))
            vDSP_vsmul(outR, 1, &scale, &outR, 1, vDSP_Length(n))
        }
        return (outL, outR)
    }

    // MARK: - 高通滤波与 RMS 包络匹配

    /// 5 阶 48Hz Butterworth 高通零相位滤波 (`scipy.signal.sosfiltfilt` 等价实现)。
    static func butterworthHighPass48Hz16k(_ input: [Float]) -> [Float] {
        guard input.count > 12 else { return input }
        let padLen = min(15, input.count - 1)
        var extended = [Double]()
        extended.reserveCapacity(input.count + 2 * padLen)

        let first = Double(input[0])
        for i in stride(from: padLen, through: 1, by: -1) {
            extended.append(2.0 * first - Double(input[i]))
        }
        for v in input {
            extended.append(Double(v))
        }
        let last = Double(input[input.count - 1])
        for i in 1...padLen {
            extended.append(2.0 * last - Double(input[input.count - 1 - i]))
        }

        let forward = sosFilter(extended, sos: butter48HzSOS, ziTemplate: butter48HzZI)
        let reversed = Array(forward.reversed())
        let backward = sosFilter(reversed, sos: butter48HzSOS, ziTemplate: butter48HzZI)
        let unreversed = Array(backward.reversed())

        var out = [Float](repeating: 0, count: input.count)
        for i in 0..<input.count {
            out[i] = Float(unreversed[padLen + i])
        }
        return out
    }

    private static func sosFilter(_ x: [Double], sos: [[Double]], ziTemplate: [[Double]]) -> [Double] {
        var signal = x
        let x0 = signal.first ?? 0.0
        for sIdx in 0..<sos.count {
            let section = sos[sIdx]
            let b0 = section[0], b1 = section[1], b2 = section[2]
            let a1 = section[4], a2 = section[5]
            var z0 = ziTemplate[sIdx][0] * x0
            var z1 = ziTemplate[sIdx][1] * x0
            for i in 0..<signal.count {
                let xi = signal[i]
                let yi = b0 * xi + z0
                z0 = b1 * xi - a1 * yi + z1
                z1 = b2 * xi - a2 * yi
                signal[i] = yi
            }
        }
        return signal
    }

    /// 匹配原人声与转换人声的 RMS 能量包络（对应 RVC `pipeline.py` 的 `change_rms`）。
    static func matchRMS(
        input: [Float],
        inputSampleRate: Int,
        output: [Float],
        outputSampleRate: Int,
        outputMixRate: Float
    ) -> [Float] {
        guard !input.isEmpty, !output.isEmpty, outputMixRate < 0.999 else {
            return output
        }
        let rms1 = frameRMS(signal: input, frameLength: (inputSampleRate / 2) * 2, hopLength: max(inputSampleRate / 2, 1))
        let rms2 = frameRMS(signal: output, frameLength: (outputSampleRate / 2) * 2, hopLength: max(outputSampleRate / 2, 1))
        let interp1 = linearInterpolate(rms1, toCount: output.count)
        let interp2 = linearInterpolate(rms2, toCount: output.count)

        let exp1 = 1.0 - outputMixRate
        let exp2 = outputMixRate - 1.0
        var scaled = [Float](repeating: 0, count: output.count)
        for i in 0..<output.count {
            let r1 = max(interp1[i], 0)
            let r2 = max(interp2[i], 1e-6)
            let gain = powf(r1, exp1) * powf(r2, exp2)
            scaled[i] = output[i] * gain
        }
        return scaled
    }

    private static func frameRMS(signal: [Float], frameLength: Int, hopLength: Int) -> [Float] {
        let fl = max(frameLength, 2)
        let hl = max(hopLength, 1)
        let pad = fl / 2
        var padded = [Float](repeating: 0, count: pad + signal.count + pad)
        padded.replaceSubrange(pad..<(pad + signal.count), with: signal)

        let numFrames = max(1 + (padded.count - fl) / hl, 1)
        var rms = [Float](repeating: 0, count: numFrames)
        let invFl = 1.0 / Float(fl)
        padded.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<numFrames {
                let start = i * hl
                guard start + fl <= padded.count else { break }
                var sumSq: Float = 0
                vDSP_svesq(base + start, 1, &sumSq, vDSP_Length(fl))
                rms[i] = sqrtf(sumSq * invFl)
            }
        }
        return rms
    }

    private static func linearInterpolate(_ values: [Float], toCount targetCount: Int) -> [Float] {
        guard !values.isEmpty, targetCount > 0 else { return [] }
        if values.count == 1 { return [Float](repeating: values[0], count: targetCount) }
        var out = [Float](repeating: 0, count: targetCount)
        let inCount = Float(values.count)
        let outCountF = Float(targetCount)
        let scale = inCount / outCountF
        for i in 0..<targetCount {
            let realIdx = (Float(i) + 0.5) * scale - 0.5
            if realIdx <= 0 {
                out[i] = values[0]
            } else if realIdx >= inCount - 1 {
                out[i] = values[values.count - 1]
            } else {
                let lo = Int(floorf(realIdx))
                let hi = min(lo + 1, values.count - 1)
                let frac = realIdx - Float(lo)
                out[i] = values[lo] * (1.0 - frac) + values[hi] * frac
            }
        }
        return out
    }

    // MARK: - RMVPE Mel Spectrogram (sr=16000, nFFT=1024, hop=160, nMels=128, 30..8000 Hz HTK)

    /// 计算与 `rmvpe.MelSpectrogram` 等价的 `[128, nFrames]` row-major 对数梅尔频谱。
    static func rmvpeLogMelSpectrogram(audio16k: [Float]) throws -> (data: [Float], frames: Int) {
        let nFFT = 1024
        let hop = 160
        let nMels = 128
        let nBins = nFFT / 2 + 1 // 513
        let pad = nFFT / 2       // 512

        let padded = reflectPad1D(audio16k, pad: pad)
        let nFrames = max((padded.count - nFFT) / hop + 1, 1)
        let window = hannWindowPeriodic(length: nFFT)

        guard let dftSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nFFT), .FORWARD) else {
            throw VoiceAudioDSPError.invalidFFTSize(nFFT)
        }
        defer { vDSP_DFT_DestroySetup(dftSetup) }

        let half = nFFT / 2
        var windowed = [Float](repeating: 0, count: nFFT)
        var inR = [Float](repeating: 0, count: half)
        var inI = [Float](repeating: 0, count: half)
        var outR = [Float](repeating: 0, count: half)
        var outI = [Float](repeating: 0, count: half)

        // magMatrix shape: [nBins, nFrames] row-major
        var magnitudes = [Float](repeating: 0, count: nBins * nFrames)

        padded.withUnsafeBufferPointer { padPtr in
            guard let base = padPtr.baseAddress else { return }
            for t in 0..<nFrames {
                let start = t * hop
                guard start + nFFT <= padded.count else { break }
                vDSP_vmul(base + start, 1, window, 1, &windowed, 1, vDSP_Length(nFFT))
                for k in 0..<half {
                    inR[k] = windowed[2 * k]
                    inI[k] = windowed[2 * k + 1]
                }
                vDSP_DFT_Execute(dftSetup, &inR, &inI, &outR, &outI)

                // DC & Nyquist (vDSP scale 2x -> * 0.5)
                magnitudes[0 * nFrames + t] = abs(outR[0] * 0.5)
                magnitudes[(nBins - 1) * nFrames + t] = abs(outI[0] * 0.5)
                for k in 1..<half {
                    let re = outR[k] * 0.5
                    let im = outI[k] * 0.5
                    magnitudes[k * nFrames + t] = hypotf(re, im)
                }
            }
        }

        // [nMels, nBins] x [nBins, nFrames] -> [nMels, nFrames]
        var melOut = [Float](repeating: 0, count: nMels * nFrames)
        vDSP_mmul(
            rmvpeMelBasis, 1,
            magnitudes, 1,
            &melOut, 1,
            vDSP_Length(nMels),
            vDSP_Length(nFrames),
            vDSP_Length(nBins)
        )

        var logMin: Float = 1e-5
        var logMax: Float = Float.greatestFiniteMagnitude
        vDSP_vclip(melOut, 1, &logMin, &logMax, &melOut, 1, vDSP_Length(melOut.count))
        var count32 = Int32(melOut.count)
        vvlogf(&melOut, melOut, &count32)

        return (melOut, nFrames)
    }

    // MARK: - MDX-Net STFT / ISTFT

    /// 对立体声分块执行与 `audio_separator.uvr_lib_v5.stft.STFT` 一致的 STFT。
    /// 返回布局 `[4, dimF, frames]`（通道依次为 L_real, L_imag, R_real, R_imag）。
    static func mdxSTFT(
        left: [Float],
        right: [Float],
        nFFT: Int,
        hopLength: Int,
        dimF: Int
    ) throws -> (tensor: [Float], frames: Int) {
        let trim = nFFT / 2
        let padL = reflectPad1D(left, pad: trim)
        let padR = reflectPad1D(right, pad: trim)
        let nFrames = max((padL.count - nFFT) / hopLength + 1, 1)

        guard let dftSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nFFT), .FORWARD) else {
            throw VoiceAudioDSPError.invalidFFTSize(nFFT)
        }
        defer { vDSP_DFT_DestroySetup(dftSetup) }

        let window = hannWindowPeriodic(length: nFFT)
        let half = nFFT / 2
        let clampedDimF = min(dimF, half + 1)
        let planeStride = clampedDimF * nFrames
        var out = [Float](repeating: 0, count: 4 * planeStride)

        var windowed = [Float](repeating: 0, count: nFFT)
        var inR = [Float](repeating: 0, count: half)
        var inI = [Float](repeating: 0, count: half)
        var outR = [Float](repeating: 0, count: half)
        var outI = [Float](repeating: 0, count: half)

        for (chIdx, padSignal) in [padL, padR].enumerated() {
            let realBase = (chIdx * 2) * planeStride
            let imagBase = (chIdx * 2 + 1) * planeStride

            padSignal.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                for t in 0..<nFrames {
                    let start = t * hopLength
                    guard start + nFFT <= padSignal.count else { break }
                    vDSP_vmul(base + start, 1, window, 1, &windowed, 1, vDSP_Length(nFFT))
                    for k in 0..<half {
                        inR[k] = windowed[2 * k]
                        inI[k] = windowed[2 * k + 1]
                    }
                    vDSP_DFT_Execute(dftSetup, &inR, &inI, &outR, &outI)

                    if clampedDimF > 0 {
                        out[realBase + t] = outR[0] * 0.5
                        out[imagBase + t] = 0
                    }
                    let loopEnd = min(clampedDimF, half)
                    for f in 1..<loopEnd {
                        out[realBase + f * nFrames + t] = outR[f] * 0.5
                        out[imagBase + f * nFrames + t] = outI[f] * 0.5
                    }
                    if clampedDimF == half + 1 {
                        out[realBase + half * nFrames + t] = outI[0] * 0.5
                        out[imagBase + half * nFrames + t] = 0
                    }
                }
            }
        }

        return (out, nFrames)
    }

    /// 执行与 `audio_separator.uvr_lib_v5.stft.STFT.inverse` 一致的 ISTFT，返回 `[targetLength]` 左右声道。
    static func mdxISTFT(
        tensor: [Float],
        dimF: Int,
        frames: Int,
        nFFT: Int,
        hopLength: Int,
        targetLength: Int
    ) throws -> (left: [Float], right: [Float]) {
        guard let invSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nFFT), .INVERSE) else {
            throw VoiceAudioDSPError.invalidFFTSize(nFFT)
        }
        defer { vDSP_DFT_DestroySetup(invSetup) }

        let window = hannWindowPeriodic(length: nFFT)
        let half = nFFT / 2
        let trim = nFFT / 2
        let planeStride = dimF * frames
        let rawLen = nFFT + (frames - 1) * hopLength
        let invScale = 1.0 / Float(nFFT)

        var inR = [Float](repeating: 0, count: half)
        var inI = [Float](repeating: 0, count: half)
        var outR = [Float](repeating: 0, count: half)
        var outI = [Float](repeating: 0, count: half)
        var frameBuf = [Float](repeating: 0, count: nFFT)

        func reconstructChannel(_ chIdx: Int) -> [Float] {
            let realBase = (chIdx * 2) * planeStride
            let imagBase = (chIdx * 2 + 1) * planeStride
            var acc = [Float](repeating: 0, count: rawLen)
            var winSq = [Float](repeating: 0, count: rawLen)

            for t in 0..<frames {
                inR.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
                inI.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
                if dimF > 0 {
                    inR[0] = tensor[realBase + t]
                }
                if dimF == half + 1 {
                    inI[0] = tensor[realBase + half * frames + t]
                }
                let copyEnd = min(dimF, half)
                for f in 1..<copyEnd {
                    inR[f] = tensor[realBase + f * frames + t]
                    inI[f] = tensor[imagBase + f * frames + t]
                }

                vDSP_DFT_Execute(invSetup, &inR, &inI, &outR, &outI)
                for k in 0..<half {
                    frameBuf[2 * k] = outR[k] * invScale
                    frameBuf[2 * k + 1] = outI[k] * invScale
                }

                let start = t * hopLength
                for i in 0..<nFFT {
                    let w = window[i]
                    acc[start + i] += frameBuf[i] * w
                    winSq[start + i] += w * w
                }
            }

            var out = [Float](repeating: 0, count: targetLength)
            for i in 0..<targetLength {
                let idx = trim + i
                guard idx < rawLen else { break }
                let denom = winSq[idx]
                out[i] = denom > 1e-11 ? (acc[idx] / denom) : 0
            }
            return out
        }

        return (reconstructChannel(0), reconstructChannel(1))
    }

    // MARK: - 通用 DSP 辅助

    static func hannWindowPeriodic(length: Int) -> [Float] {
        guard length > 0 else { return [] }
        var w = [Float](repeating: 0, count: length)
        let denom = Float(length)
        for i in 0..<length {
            w[i] = 0.5 * (1.0 - cosf(2.0 * Float.pi * Float(i) / denom))
        }
        return w
    }

    static func hannWindowSymmetric(length: Int) -> [Float] {
        guard length > 1 else { return [Float](repeating: 1, count: max(length, 0)) }
        var w = [Float](repeating: 0, count: length)
        let denom = Float(length - 1)
        for i in 0..<length {
            w[i] = 0.5 * (1.0 - cosf(2.0 * Float.pi * Float(i) / denom))
        }
        return w
    }

    static func reflectPad1D(_ input: [Float], pad: Int) -> [Float] {
        guard pad > 0, input.count > 1 else {
            if pad <= 0 { return input }
            let val = input.first ?? 0
            return [Float](repeating: val, count: pad + input.count + pad)
        }
        let n = input.count
        var out = [Float](repeating: 0, count: pad + n + pad)

        func reflectedIndex(_ idx: Int) -> Int {
            var p = idx
            let period = 2 * (n - 1)
            p = ((p % period) + period) % period
            return p < n ? p : (period - p)
        }

        for i in 0..<pad {
            out[i] = input[reflectedIndex(pad - i)]
        }
        out.replaceSubrange(pad..<(pad + n), with: input)
        for i in 0..<pad {
            out[pad + n + i] = input[reflectedIndex(n - 2 - i)]
        }
        return out
    }

    private static func makeMelFilterBank(
        sampleRate: Double,
        nFFT: Int,
        nMels: Int,
        fMin: Double,
        fMax: Double
    ) -> [Float] {
        func hzToMelHTK(_ hz: Double) -> Double {
            2595.0 * log10(1.0 + hz / 700.0)
        }
        func melToHzHTK(_ mel: Double) -> Double {
            700.0 * (pow(10.0, mel / 2595.0) - 1.0)
        }

        let nBins = nFFT / 2 + 1
        let melMin = hzToMelHTK(fMin)
        let melMax = hzToMelHTK(fMax)
        let mels = (0..<(nMels + 2)).map { i in
            melToHzHTK(melMin + (melMax - melMin) * Double(i) / Double(nMels + 1))
        }
        let fftFreqs = (0..<nBins).map { i in
            (sampleRate * 0.5) * Double(i) / Double(nBins - 1)
        }

        var weights = [Float](repeating: 0, count: nMels * nBins)
        for m in 0..<nMels {
            let fLower = mels[m]
            let fCenter = mels[m + 1]
            let fUpper = mels[m + 2]
            let lowerSlope = fCenter - fLower
            let upperSlope = fUpper - fCenter
            let enorm = 2.0 / max(fUpper - fLower, 1e-12)
            for k in 0..<nBins {
                let f = fftFreqs[k]
                let lower = (f - fLower) / max(lowerSlope, 1e-12)
                let upper = (fUpper - f) / max(upperSlope, 1e-12)
                let val = max(0.0, min(lower, upper)) * enorm
                weights[m * nBins + k] = Float(val)
            }
        }
        return weights
    }
}
