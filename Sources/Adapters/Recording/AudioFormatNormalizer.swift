import AVFoundation
import CoreMedia

/// 音频格式归一化器：把任意来源（16k/24k AirPods 蓝牙麦、44.1k 单声道 USB 麦、48k 立体声系统声…）
/// 的 CMSampleBuffer 统一成固定的 48kHz / 2 声道 / Float32 / 非交错 LPCM，并精确保留给定 PTS。
///
/// 设计约定：
/// - **零锁**：内部无任何同步原语，调用方必须保证串行调用（本工程由 `ActiveSession.mediaQueue` 保证）；
/// - **绝不崩溃**：任何异常（样本未就绪、ASBD 读不出、分配/转换失败）一律返回 nil + 节流日志；
/// - **热插拔自愈**：源 ASBD 变化（换设备/蓝牙切换码率）时自动重建 `AVAudioConverter`；
/// - **纯净封装**：不碰 AVAssetWriter，便于后续 Wave 3（双轨 PCM 实时混音）直接复用。
///
/// 之所以要归一化：`AVAssetWriterInput` 的 AAC `outputSettings` 里写死 48kHz/2ch，
/// 若直接喂 44.1k 单声道（USB 麦）或 16k（蓝牙麦）样本，声道/采样率不匹配会导致写入失败或输出异常。
final class AudioFormatNormalizer: @unchecked Sendable {
    /// 目标采样率（Hz）
    private let targetSampleRate: Double
    /// 目标声道数
    private let targetChannels: AVAudioChannelCount

    /// 目标规范格式（standardFormat = Float32 / 非交错）
    private let targetFormat: AVAudioFormat?
    /// 目标格式对应的 CMAudioFormatDescription（含 Stereo 声道布局）
    private let targetFormatDescription: CMAudioFormatDescription?

    // MARK: 源格式状态（仅调用方串行访问）
    private var sourceFormat: AVAudioFormat?
    private var sourceASBD: AudioStreamBasicDescription?
    private var converter: AVAudioConverter?

    // MARK: 节流日志
    private var failureCount = 0

    init(targetSampleRate: Double = 48_000, targetChannels: AVAudioChannelCount = 2) {
        self.targetSampleRate = targetSampleRate
        self.targetChannels = targetChannels
        let format = AVAudioFormat(
            standardFormatWithSampleRate: targetSampleRate,
            channels: targetChannels
        )
        self.targetFormat = format
        self.targetFormatDescription = format.flatMap { Self.makeFormatDescription(for: $0) }
    }

    // MARK: - 公共接口

    /// 归一化单个音频样本，返回 48kHz / 2ch / Float32 / 非交错 LPCM 的新样本，PTS 精确等于 `pts`。
    /// 任何异常返回 nil（绝不抛异常、绝不崩溃）。
    func normalize(_ sampleBuffer: CMSampleBuffer, presentationTimeStamp pts: CMTime) -> CMSampleBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            reportFailure("dataNotReady")
            return nil
        }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else {
            reportFailure("emptySample")
            return nil
        }
        guard pts.isValid else {
            reportFailure("invalidPTS")
            return nil
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            reportFailure("noASBD")
            return nil
        }
        let inputASBD = asbdPointer.pointee
        guard inputASBD.mSampleRate > 0, inputASBD.mChannelsPerFrame > 0 else {
            reportFailure("badASBD")
            return nil
        }

        // 快路径：源已是目标格式（48k/2ch/Float32/非交错）⇒ 无需转换，只换时间戳
        if conformsToTarget(inputASBD) {
            invalidateConverter()
            if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), pts) == 0 {
                return sampleBuffer
            }
            if let retimed = copyWithTiming(sampleBuffer, presentationTimeStamp: pts) {
                return retimed
            }
            reportFailure("retime")
            return nil
        }

        guard ensureConverter(for: inputASBD) else { return nil }
        guard let sourceFormat,
              let converter,
              let targetFormat,
              let targetFormatDescription else {
            reportFailure("converterMissing")
            return nil
        }
        guard frameCount <= Int(Int32.max), frameCount <= Int(AVAudioFrameCount.max) else {
            reportFailure("tooManyFrames", extra: ["frames": "\(frameCount)"])
            return nil
        }

        // 1) 源样本 → AVAudioPCMBuffer（安全拷贝，兼容 interleaved / non-interleaved 两种布局）
        guard let inputPCM = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            reportFailure("allocInput")
            return nil
        }
        inputPCM.frameLength = AVAudioFrameCount(frameCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputPCM.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            reportFailure("copyPCM", extra: ["status": "\(copyStatus)"])
            return nil
        }

        // 2) 转换到目标格式（采样率 + 声道数同时处理，单声道会按 channelMap 双耳居中）
        let ratio = targetSampleRate / inputASBD.mSampleRate
        let capacity = Double(frameCount) * max(0.25, min(ratio, 8.0)) + 1024
        guard capacity < Double(UInt32.max),
              let outputPCM = AVAudioPCMBuffer(
                  pcmFormat: targetFormat,
                  frameCapacity: AVAudioFrameCount(capacity)
              ) else {
            reportFailure("allocOutput")
            return nil
        }

        let feeder = InputFeeder()
        var conversionError: NSError?
        nonisolated(unsafe) let inputBuffer = inputPCM
        let conversionStatus = converter.convert(
            to: outputPCM,
            error: &conversionError
        ) { _, statusPointer in
            if feeder.provided {
                statusPointer.pointee = .noDataNow
                return nil
            }
            feeder.provided = true
            statusPointer.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            reportFailure("convert", extra: ["err": conversionError.localizedDescription])
            return nil
        }
        guard conversionStatus != .error else {
            reportFailure("convertStatusError")
            return nil
        }
        // 返回的是状态而不是帧数：实际产出帧数以 outputPCM.frameLength 为准
        let producedFrames = outputPCM.frameLength
        guard producedFrames > 0, producedFrames <= outputPCM.frameCapacity else {
            // 重采样转换器内部会缓存尾部数据，单个小包无输出属正常现象：丢弃但不视为致命
            reportFailure("zeroOut", extra: ["in": "\(frameCount)"])
            return nil
        }

        // 3) AVAudioPCMBuffer → 带精确 pts 的 CMSampleBuffer
        guard let output = makeSampleBuffer(
            from: outputPCM,
            frames: producedFrames,
            presentationTimeStamp: pts,
            formatDescription: targetFormatDescription
        ) else {
            reportFailure("makeSampleBuffer")
            return nil
        }
        return output
    }

    /// 清空转换器状态（收尾/失败清理时调用，下次 normalize 会用新源格式重建）
    func reset() {
        invalidateConverter()
        failureCount = 0
    }

    /// 只清空重采样器的内部滤波器延迟线（暂停→恢复时调用）
    ///
    /// 暂停期间硬件/蓝牙链路可能仍吐出几十毫秒的旧样本，若不清空，恢复后头几个包会混入暂停前的
    /// 滤波尾巴（听感上是恢复瞬间的「回音 / 咔哒」）。
    /// 与 `reset()` 的区别：**不销毁** sourceFormat / sourceASBD / converter —— 源设备没变，重建纯属浪费，
    /// 还会刷一条 rebuild 日志；这里只把滤波器状态归零。
    func flushState() {
        converter?.reset()
    }

    // MARK: - 转换器管理

    private func ensureConverter(for inputASBD: AudioStreamBasicDescription) -> Bool {
        if let sourceASBD, converter != nil, Self.equalASBD(sourceASBD, inputASBD) {
            return true
        }
        // 源格式变了（设备热插拔 / 蓝牙码率切换），全部重建
        invalidateConverter()

        var asbd = inputASBD
        guard let source = AVAudioFormat(streamDescription: &asbd) else {
            reportFailure("badSourceFormat", extra: Self.asbdSummary(inputASBD))
            return false
        }
        guard let targetFormat else {
            reportFailure("targetFormatUnavailable")
            return false
        }
        guard let newConverter = AVAudioConverter(from: source, to: targetFormat) else {
            reportFailure("converterCreate", extra: Self.asbdSummary(inputASBD))
            return false
        }
        // 单声道人声必须双耳居中：不做 channelMap 时部分路径会只填左声道
        if inputASBD.mChannelsPerFrame == 1 && targetChannels == 2 {
            newConverter.channelMap = [0, 0]
        }
        newConverter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        sourceFormat = source
        sourceASBD = inputASBD
        converter = newConverter
        Log.event(.recording, "recording.audio.normalizer.rebuild", Self.asbdSummary(inputASBD))
        return true
    }

    private func invalidateConverter() {
        converter = nil
        sourceFormat = nil
        sourceASBD = nil
    }

    // MARK: - 样本构造

    private func makeSampleBuffer(
        from pcm: AVAudioPCMBuffer,
        frames: AVAudioFrameCount,
        presentationTimeStamp pts: CMTime,
        formatDescription: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        let bufferList = pcm.mutableAudioBufferList
        let audioBufferList = UnsafeMutableAudioBufferListPointer(bufferList)
        guard audioBufferList.count > 0 else {
            reportFailure("emptyBufferList")
            return nil
        }
        // 按实际产出帧数收缩每个 plane 的字节数（AVAudioPCMBuffer 的 mDataByteSize 是 frameCapacity 的量）
        let bytesPerFrame = UInt32(max(1, pcm.format.streamDescription.pointee.mBytesPerFrame))
        let planeBytes = UInt32(frames) * bytesPerFrame
        for index in 0..<audioBufferList.count {
            audioBufferList[index].mDataByteSize = planeBytes
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(targetSampleRate.rounded())),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            reportFailure("sampleBufferCreate", extra: ["status": "\(status)"])
            return nil
        }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: bufferList
        )
        guard status == noErr else {
            reportFailure("setDataBuffer", extra: ["status": "\(status)"])
            return nil
        }
        return sampleBuffer
    }

    /// 复用原样本数据，只把时间戳平移到 `pts`（快路径专用）
    private func copyWithTiming(_ sampleBuffer: CMSampleBuffer, presentationTimeStamp pts: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr, count > 0 else { return nil }

        var infos = Array(repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count
        ) == noErr, count > 0, infos[0].presentationTimeStamp.isValid else { return nil }

        let delta = CMTimeSubtract(pts, infos[0].presentationTimeStamp)
        for index in 0..<count {
            if infos[index].presentationTimeStamp.isValid {
                infos[index].presentationTimeStamp = CMTimeAdd(infos[index].presentationTimeStamp, delta)
            }
            if infos[index].decodeTimeStamp.isValid {
                infos[index].decodeTimeStamp = CMTimeAdd(infos[index].decodeTimeStamp, delta)
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &infos,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }

    // MARK: - 工具

    private func conformsToTarget(_ asbd: AudioStreamBasicDescription) -> Bool {
        guard abs(asbd.mSampleRate - targetSampleRate) < 0.5 else { return false }
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return false }
        guard asbd.mChannelsPerFrame == targetChannels else { return false }
        guard asbd.mBitsPerChannel == 32 else { return false }
        let flags = asbd.mFormatFlags
        guard (flags & kAudioFormatFlagIsFloat) != 0 else { return false }
        guard (flags & kAudioFormatFlagIsNonInterleaved) != 0 else { return false }
        return asbd.mBytesPerFrame == 4 && asbd.mFramesPerPacket == 1
    }

    private static func equalASBD(_ lhs: AudioStreamBasicDescription, _ rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerPacket == rhs.mBytesPerPacket
            && lhs.mFramesPerPacket == rhs.mFramesPerPacket
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
            && abs(lhs.mSampleRate - rhs.mSampleRate) < 0.5
    }

    private static func makeFormatDescription(for format: AVAudioFormat) -> CMAudioFormatDescription? {
        var asbd = format.streamDescription.pointee
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        layout.mNumberChannelDescriptions = 0
        // AudioChannelLayout 尾部是柔性数组 mChannelDescriptions；tag 型布局（Stereo）无附加描述，
        // 尺寸只算 3 个 UInt32 头部，避免把 1 个元素的可变尾数组也算进去。
        let layoutSize = MemoryLayout<UInt32>.size * 3
        var description: CMAudioFormatDescription?
        let status = withUnsafePointer(to: &layout) { layoutPointer in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: layoutSize,
                layout: layoutPointer,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr else { return nil }
        return description
    }

    /// 单次投喂标记：AVAudioConverter 的输入 block 是 @Sendable，用引用类型承载「已经给过一次」状态（无锁，只在同一次 convert 调用内使用）
    private final class InputFeeder: @unchecked Sendable {
        var provided = false
    }

    private static func asbdSummary(_ asbd: AudioStreamBasicDescription) -> [String: String] {
        [
            "rate": String(format: "%.0f", asbd.mSampleRate),
            "ch": "\(asbd.mChannelsPerFrame)",
            "bits": "\(asbd.mBitsPerChannel)",
            "interleaved": (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 ? "true" : "false",
        ]
    }

    /// 节流日志：前 3 次与每 50 次记录，避免坏设备持续刷屏
    private func reportFailure(_ reason: String, extra: [String: String] = [:]) {
        failureCount += 1
        let count = failureCount
        guard count <= 3 || count % 50 == 0 else { return }
        var fields = extra
        fields["reason"] = reason
        fields["n"] = "\(count)"
        Log.error(.recording, "recording.audio.normalizeFail", fields)
    }
}
