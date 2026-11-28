import AVFoundation
import CoreMedia
import Foundation

/// 双轨实时 PCM 混音器：把「系统声」与「麦克风」两条 48kHz/2ch/Float32/非交错轨道，
/// 按主时钟（录制起点 PTS）对齐混成单一轨，输出严格单调、零重叠、零空洞的 CMSampleBuffer 序列。
///
/// 设计约定（与 `AudioFormatNormalizer` 一致，便于复用同一套调用纪律）：
/// - **零锁**：内部无任何同步原语，调用方必须保证串行调用（本工程由 `ActiveSession.mediaQueue` 保证）；
/// - **零外部依赖**：不引用工程内 Log / Ports，可被 `swiftc` 单独编译验证（诊断全部通过 `stats` 暴露）；
/// - **绝不崩溃**：空包 / 未就绪 / 非法 PTS / 非规范格式 / 超大跳跃一律安全忽略或安全推进游标；
/// - **样本索引即真源**：输出 PTS 由「块起始样本序号」反算，绝不按包 PTS 直接拼接，
///   因此上下游包乱序、迟到、部分重叠都不会破坏时间轴连续性。
///
/// 缓冲模型：每轨一条固定容量非交错 L/R 环形缓冲（默认 2s = 96000 样本/声道）。
/// 消费即清零，所以「未写入槽位」天然是 0.0 —— 单轨暂缺时读到的就是静音，无需额外分支填零。
final class AudioTrackMixer: @unchecked Sendable {
    enum Source: Sendable {
        case system
        case microphone
    }

    struct Config: Sendable {
        /// 目标采样率（Hz），同时也是输出 PTS 的时基
        var sampleRate: Double = 48_000
        /// 目标声道数（本项目固定立体声）
        var channels: Int = 2
        /// 输出块大小（帧），默认 1024（≈21.3ms）
        var chunkFrames: Int = 1_024
        /// 抖动窗：缺轨时最多等这么久就补静音，超过就认为该轨断流
        var jitterWindowSeconds: Double = 0.060
        /// 每轨环形缓冲容量（秒），必须明显大于抖动窗
        var bufferCapacitySeconds: Double = 2.0
        /// 包边界吸附容差（秒）：±2.5ms 内视为同一位置，消除舍入咔嗒声
        var snapToleranceSeconds: Double = 0.0025
        /// 软削波拐点（低于它完全线性）
        var softClipKnee: Float = 0.85
        /// 软削波上限（严格小于 1.0，绝不硬削波）
        var softClipCeiling: Float = 0.99
        /// 系统声增益
        var systemGain: Float = 1.0
        /// 麦克风增益
        var microphoneGain: Float = 1.0
        init() {}
    }

    /// 全部诊断出口（本类不写日志，调用方自行汇报）
    struct Stats: Sendable {
        var emittedChunks: Int = 0
        var sysPacketsPushed: Int = 0
        var micPacketsPushed: Int = 0
        var latePacketsDropped: Int = 0
        var silenceFallbackChunks: Int = 0
        var overflowFlushes: Int = 0
        var clippedSamples: Int = 0
    }

    let config: Config
    private(set) var stats: Stats = Stats()
    /// 已经吐出的样本总数（绝对样本序号的下一个位置，即下一个待输出样本索引）
    private(set) var emittedSamples: Int64 = 0
    private(set) var lastEmittedEndPTS: CMTime?

    var isAnchored: Bool { anchorPTS != nil }

    // MARK: - 私有状态（仅调用方串行队列内访问）

    /// 主时钟锚点：整条时间轴的原点
    private var anchorPTS: CMTime?
    /// 已观测到的最新样本序号（随 push 末端与 advanceClock 推进），用于抖动窗兜底判定
    private var latestClockSample: Int64 = 0

    private var systemTrack: Track
    private var microphoneTrack: Track

    /// 输出 PTS 时基（与 sampleRate 一致，保证 PTS 是整数 tick，比较无浮点误差）
    private let sampleRateTimescale: CMTimeScale
    /// 每轨环形缓冲容量（样本/声道）
    private let capacitySamples: Int64
    private let jitterWindowSamples: Int64
    private let snapToleranceSamples: Int64

    /// 规范输出格式（48kHz / 2ch / Float32 / 非交错）
    private let targetFormat: AVAudioFormat?
    private let targetFormatDescription: CMAudioFormatDescription?
    /// 混音输出暂存（复用，capacity = chunkFrames）
    private let scratchBuffer: AVAudioPCMBuffer?
    /// 输入拷贝暂存（复用，按最大包帧数增长）
    private var inputBuffer: AVAudioPCMBuffer?

    // MARK: - 初始化

    init(config: Config = Config()) {
        self.config = config

        let rate = config.sampleRate.isFinite && config.sampleRate > 0 ? config.sampleRate : 48_000
        let channels = max(1, config.channels)
        let chunkFrames = max(1, config.chunkFrames)

        self.sampleRateTimescale = CMTimeScale(rate.rounded())
        // 容量至少容纳两个块，避免配置异常时环形缓冲装不下一个待输出块
        let rawCapacity = Int64((config.bufferCapacitySeconds * rate).rounded())
        self.capacitySamples = max(Int64(chunkFrames) * 2, rawCapacity)
        self.jitterWindowSamples = max(0, Int64((config.jitterWindowSeconds * rate).rounded()))
        self.snapToleranceSamples = max(0, Int64((config.snapToleranceSeconds * rate).rounded()))

        let bufferFrames = Int(min(Int64(Int32.max), self.capacitySamples))
        self.systemTrack = Track(capacity: bufferFrames)
        self.microphoneTrack = Track(capacity: bufferFrames)

        let format = AVAudioFormat(
            standardFormatWithSampleRate: rate,
            channels: AVAudioChannelCount(channels)
        )
        self.targetFormat = format
        self.targetFormatDescription = format.flatMap { Self.makeFormatDescription(for: $0) }
        self.scratchBuffer = format.flatMap {
            AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: AVAudioFrameCount(chunkFrames))
        }
    }

    // MARK: - 主时钟

    /// 锚定时间轴原点。幂等：已锚定时直接忽略（暂停恢复不需要重新锚定，时间轴保持连续）。
    func anchor(at startPTS: CMTime) {
        guard anchorPTS == nil, startPTS.isValid, startPTS.isNumeric else { return }
        anchorPTS = startPTS
        emittedSamples = 0
        latestClockSample = 0
        systemTrack.clearAll(from: 0)
        microphoneTrack.clearAll(from: 0)
    }

    // MARK: - 投喂

    /// 投入一个包，返回因此「就绪」的输出块（可能 0 个，也可能多个）。
    func push(_ sampleBuffer: CMSampleBuffer, source: Source, adjustedPTS: CMTime) -> [CMSampleBuffer] {
        guard anchorPTS != nil else { return [] }
        guard adjustedPTS.isValid, adjustedPTS.isNumeric else { return [] }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return [] }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= Int(Int32.max) else { return [] }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              Self.isCanonical(formatDescription, sampleRate: config.sampleRate, channels: max(1, config.channels))
        else { return [] }
        guard let inputPCM = ensureInputBuffer(frames: frameCount),
              let channelData = prepareInput(inputPCM, from: sampleBuffer, frames: frameCount)
        else { return [] }

        switch source {
        case .system: stats.sysPacketsPushed += 1
        case .microphone: stats.micPacketsPushed += 1
        }

        let srcL = channelData.0
        let srcR = channelData.1
        let startIdx = sampleIndex(for: adjustedPTS)
        let frames = Int64(frameCount)

        // 1) 整包过期：不回退游标，只把当前已就绪的块交出去
        if startIdx + frames <= emittedSamples {
            stats.latePacketsDropped += 1
            return takeReady()
        }

        // 2) 部分重叠（含 PTS 早于锚点的负索引）：只裁掉已被消费的头部
        var start = startIdx
        var skip: Int64 = 0
        if start < emittedSamples {
            skip = emittedSamples - start
            start = emittedSamples
            stats.latePacketsDropped += 1
        }
        var count = frameCount - Int(skip)
        guard count > 0 else {
            stats.latePacketsDropped += 1
            return takeReady()
        }

        // 3) 包边界微抖动吸附：整体平移写入起点与上一包末端对齐，保留全部未消费采样，消除相位跳跃与咔嗒声
        start = snappedStart(start, source: source)

        var output: [CMSampleBuffer] = []

        // 4) 防溢出：先把最老的槽位按时间顺序混音吐出腾出空间，避免白白丢弃已缓冲音频
        if start + Int64(count) > emittedSamples + capacitySamples {
            stats.overflowFlushes += 1
            let needReleaseUntil = start + Int64(count) - capacitySamples
            let maxDrainSpan = capacitySamples * 4
            if needReleaseUntil > emittedSamples && (needReleaseUntil - emittedSamples) <= maxDrainSpan {
                output += emitRange(upTo: needReleaseUntil)
            } else {
                output += takeReady()
            }
        }
        // 仍然装不下（如设备恢复时时间戳极端大幅前跳）：安全推进游标 + 清空环形缓冲，绝不越界
        if start + Int64(count) > emittedSamples + capacitySamples {
            emittedSamples = start
            latestClockSample = max(latestClockSample, start)
            systemTrack.clearAll(from: start)
            microphoneTrack.clearAll(from: start)
            let capacityInt = Int(capacitySamples)
            if count > capacityInt {
                // 只保留包尾最近的 capacityInt 帧
                skip += Int64(count - capacityInt)
                start += Int64(count - capacityInt)
                count = capacityInt
            }
        }

        // 5) 写入环形缓冲（槽位索引 = 绝对样本序号 % capacity）
        switch source {
        case .system:
            systemTrack.write(offset: start, count: count, left: srcL, right: srcR, skip: Int(skip))
            systemTrack.writtenEnd = max(systemTrack.writtenEnd, start + Int64(count))
            systemTrack.hasReceivedPacket = true
        case .microphone:
            microphoneTrack.write(offset: start, count: count, left: srcL, right: srcR, skip: Int(skip))
            microphoneTrack.writtenEnd = max(microphoneTrack.writtenEnd, start + Int64(count))
            microphoneTrack.hasReceivedPacket = true
        }

        latestClockSample = max(latestClockSample, start + Int64(count))
        output += takeReady()
        return output
    }

    /// 外部时钟推进（设备切换空档 / 定时器打点）。返回因此就绪的输出块。
    func advanceClock(to adjustedPTS: CMTime) -> [CMSampleBuffer] {
        guard anchorPTS != nil, adjustedPTS.isValid, adjustedPTS.isNumeric else { return [] }
        latestClockSample = max(latestClockSample, sampleIndex(for: adjustedPTS))
        return takeReady()
    }

    // MARK: - 收尾

    /// 暂停前收口：把 [已输出, cutoff] 全部吐完（缺数据处天然是静音），
    /// 然后彻底清空环形缓冲并回卷两轨游标，保证暂停前后的样本绝不串台。
    func flushForPause(upTo cutoffPTS: CMTime) -> [CMSampleBuffer] {
        guard anchorPTS != nil, cutoffPTS.isValid, cutoffPTS.isNumeric else { return [] }
        let target = max(emittedSamples, sampleIndex(for: cutoffPTS))
        let output = emitRange(upTo: target)
        systemTrack.clearAll(from: emittedSamples)
        microphoneTrack.clearAll(from: emittedSamples)
        latestClockSample = emittedSamples
        lastEmittedEndPTS = pts(forSampleIndex: emittedSamples)
        return output
    }

    /// 录制结束收口：把 [已输出, endPTS] 全部吐完（含末尾不足一块的余数）。
    func flushFinal(upTo endPTS: CMTime) -> [CMSampleBuffer] {
        guard anchorPTS != nil, endPTS.isValid, endPTS.isNumeric else { return [] }
        let target = max(emittedSamples, sampleIndex(for: endPTS))
        let output = emitRange(upTo: target)
        lastEmittedEndPTS = pts(forSampleIndex: emittedSamples)
        return output
    }

    /// 全量复位（换会话 / 换设备后重建）：清时钟、清缓冲、清诊断。
    func reset() {
        anchorPTS = nil
        emittedSamples = 0
        latestClockSample = 0
        lastEmittedEndPTS = nil
        systemTrack.clearAll(from: 0)
        microphoneTrack.clearAll(from: 0)
        stats = Stats()
        inputBuffer = nil
    }

    // MARK: - 样本序号 / PTS

    private func sampleIndex(for pts: CMTime) -> Int64 {
        guard let anchorPTS else { return emittedSamples }
        let seconds = CMTimeSubtract(pts, anchorPTS).seconds
        guard seconds.isFinite else { return emittedSamples }
        let index = (seconds * config.sampleRate).rounded()
        guard index.isFinite, index > Double(Int64.min / 2), index < Double(Int64.max / 2) else {
            return emittedSamples
        }
        return Int64(index)
    }

    /// 输出块 PTS：严格由「块起始样本序号」反算，保证 100% 单调、零重叠、零空洞
    private func pts(forSampleIndex index: Int64) -> CMTime {
        guard let anchorPTS else { return .zero }
        return CMTimeAdd(anchorPTS, CMTime(value: index, timescale: sampleRateTimescale))
    }

    private func snappedStart(_ start: Int64, source: Source) -> Int64 {
        switch source {
        case .system:
            guard systemTrack.hasReceivedPacket, systemTrack.writtenEnd >= emittedSamples else { return start }
            let delta = start - systemTrack.writtenEnd
            return abs(delta) <= snapToleranceSamples ? systemTrack.writtenEnd : start
        case .microphone:
            guard microphoneTrack.hasReceivedPacket, microphoneTrack.writtenEnd >= emittedSamples else { return start }
            let delta = start - microphoneTrack.writtenEnd
            return abs(delta) <= snapToleranceSamples ? microphoneTrack.writtenEnd : start
        }
    }

    // MARK: - 输出调度

    /// 非阻塞吐出：两块都够 ⇒ 立即混音；只有时钟越过抖动窗才补静音，绝不为了等某轨而阻塞。
    private func takeReady() -> [CMSampleBuffer] {
        guard anchorPTS != nil else { return [] }
        var output: [CMSampleBuffer] = []
        let chunk = Int64(max(1, config.chunkFrames))
        while true {
            let need = emittedSamples + chunk
            let bothReady = systemTrack.writtenEnd >= need && microphoneTrack.writtenEnd >= need
            let clockReady = latestClockSample >= need + jitterWindowSamples
            if bothReady {
                guard let buffer = emitChunk(frames: Int(chunk), silenceFallback: false) else { break }
                output.append(buffer)
            } else if clockReady {
                guard let buffer = emitChunk(frames: Int(chunk), silenceFallback: true) else { break }
                output.append(buffer)
            } else {
                break
            }
        }
        return output
    }

    private func emitRange(upTo target: Int64) -> [CMSampleBuffer] {
        var output: [CMSampleBuffer] = []
        let chunk = Int64(max(1, config.chunkFrames))
        while emittedSamples < target {
            let frames = Int(min(chunk, target - emittedSamples))
            guard let buffer = emitChunk(frames: frames, silenceFallback: false) else { break }
            output.append(buffer)
        }
        return output
    }

    /// 混一个块：两轨按样本序号对齐读取（读完即清零），加增益后过软限幅器。
    private func emitChunk(frames: Int, silenceFallback: Bool) -> CMSampleBuffer? {
        guard frames > 0,
              let scratchBuffer,
              let formatDescription = targetFormatDescription,
              frames <= Int(scratchBuffer.frameCapacity),
              let channelData = scratchBuffer.floatChannelData
        else { return nil }

        let planeCount = Int(scratchBuffer.format.channelCount)
        guard planeCount >= 1 else { return nil }
        let outL = channelData[0]
        let outR = planeCount >= 2 ? channelData[1] : channelData[0]

        let systemGain = config.systemGain
        let microphoneGain = config.microphoneGain
        let knee = config.softClipKnee
        let ceiling = max(config.softClipCeiling, knee + 1e-4)
        let span = ceiling - knee

        var clipped = 0
        for i in 0..<frames {
            let index = emittedSamples + Int64(i)
            let (sysL, sysR) = systemTrack.consume(index)
            let (micL, micR) = microphoneTrack.consume(index)
            let mixedL = sysL * systemGain + micL * microphoneGain
            let mixedR = sysR * systemGain + micR * microphoneGain
            let (shapedL, clippedL) = Self.softClip(mixedL, knee: knee, ceiling: ceiling, span: span)
            let (shapedR, clippedR) = Self.softClip(mixedR, knee: knee, ceiling: ceiling, span: span)
            outL[i] = shapedL
            outR[i] = shapedR
            if clippedL { clipped += 1 }
            if clippedR { clipped += 1 }
        }

        let startIndex = emittedSamples
        scratchBuffer.frameLength = AVAudioFrameCount(frames)
        let presentationTimeStamp = pts(forSampleIndex: startIndex)
        guard let sampleBuffer = makeSampleBuffer(
            from: scratchBuffer,
            frames: frames,
            presentationTimeStamp: presentationTimeStamp,
            formatDescription: formatDescription
        ) else { return nil }

        emittedSamples = startIndex + Int64(frames)
        stats.emittedChunks += 1
        stats.clippedSamples += clipped
        if silenceFallback { stats.silenceFallbackChunks += 1 }
        lastEmittedEndPTS = pts(forSampleIndex: emittedSamples)
        return sampleBuffer
    }

    /// 软限幅：|x| ≤ knee 线性直通；超过则用 tanh 平滑压向 ceiling（渐近逼近，永不硬削波）
    @inline(__always)
    private static func softClip(_ x: Float, knee: Float, ceiling: Float, span: Float) -> (Float, Bool) {
        let magnitude = abs(x)
        guard magnitude > knee else { return (x, false) }
        let shaped = knee + span * tanh((magnitude - knee) / span)
        return (x < 0 ? -shaped : shaped, true)
    }

    // MARK: - 输入 / 输出缓冲

    private func ensureInputBuffer(frames: Int) -> AVAudioPCMBuffer? {
        if let inputBuffer, Int(inputBuffer.frameCapacity) >= frames { return inputBuffer }
        guard let targetFormat else { return nil }
        let capacity = max(frames, max(config.chunkFrames * 8, 4_096))
        guard capacity < Int(UInt32.max) else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(capacity)
        ) else { return nil }
        inputBuffer = buffer
        return buffer
    }

    /// 用 `CMSampleBufferCopyPCMDataIntoAudioBufferList` 安全拷贝进规范格式缓冲
    /// （绝不假设 CMBlockBuffer 单段连续），成功则返回左右声道指针。
    private func prepareInput(
        _ pcm: AVAudioPCMBuffer,
        from sampleBuffer: CMSampleBuffer,
        frames: Int
    ) -> (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)? {
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr, let channelData = pcm.floatChannelData else { return nil }
        let planeCount = Int(pcm.format.channelCount)
        guard planeCount >= 1 else { return nil }
        // 单声道（异常配置下）退化：右声道复用左声道，听感居中
        return (channelData[0], planeCount >= 2 ? channelData[1] : channelData[0])
    }

    private func makeSampleBuffer(
        from pcm: AVAudioPCMBuffer,
        frames: Int,
        presentationTimeStamp pts: CMTime,
        formatDescription: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        let bufferList = pcm.mutableAudioBufferList
        let audioBufferList = UnsafeMutableAudioBufferListPointer(bufferList)
        guard audioBufferList.count > 0 else { return nil }
        // 按实际帧数收缩每个 plane 的字节数（AVAudioPCMBuffer 的 mDataByteSize 是 frameCapacity 的量）
        let bytesPerFrame = UInt32(max(1, pcm.format.streamDescription.pointee.mBytesPerFrame))
        let planeBytes = UInt32(frames) * bytesPerFrame
        for index in 0..<audioBufferList.count {
            audioBufferList[index].mDataByteSize = planeBytes
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRateTimescale),
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
        guard status == noErr, let sampleBuffer else { return nil }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: bufferList
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - 格式

    private static func isCanonical(
        _ formatDescription: CMAudioFormatDescription,
        sampleRate: Double,
        channels: Int
    ) -> Bool {
        guard let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return false
        }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return false }
        guard abs(asbd.mSampleRate - sampleRate) < 0.5 else { return false }
        guard asbd.mChannelsPerFrame == UInt32(max(1, channels)) else { return false }
        guard asbd.mBitsPerChannel == 32 else { return false }
        let flags = asbd.mFormatFlags
        guard (flags & kAudioFormatFlagIsFloat) != 0 else { return false }
        guard (flags & kAudioFormatFlagIsNonInterleaved) != 0 else { return false }
        guard asbd.mBytesPerFrame == 4, asbd.mFramesPerPacket == 1 else { return false }
        return true
    }

    private static func makeFormatDescription(for format: AVAudioFormat) -> CMAudioFormatDescription? {
        var asbd = format.streamDescription.pointee
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = asbd.mChannelsPerFrame == 1
            ? kAudioChannelLayoutTag_Mono
            : kAudioChannelLayoutTag_Stereo
        layout.mNumberChannelDescriptions = 0
        // AudioChannelLayout 尾部是柔性数组 mNumberChannelDescriptions；tag 型布局无附加描述，
        // 尺寸只算 3 个 UInt32 头部（与 AudioFormatNormalizer 完全一致）。
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

    // MARK: - 环形缓冲

    /// 单轨环形缓冲：绝对样本序号 → 槽位序号（取模），消费即清零。
    ///
    /// 不变量：
    /// - 任意时刻 `writtenEnd - emittedSamples <= capacity`（写入前由 push 保证）；
    /// - 因此「写入位置」与「尚未消费的数据」不会落在同一个槽位上；
    /// - 槽位被消费后立即写 0.0，未写入槽位天然是 0.0 ⇒ 缺轨读到的就是静音。
    private struct Track {
        let capacity: Int
        var left: [Float]
        var right: [Float]
        /// 下一个待写入的绝对样本序号
        var writtenEnd: Int64 = 0
        var hasReceivedPacket = false

        init(capacity: Int) {
            let value = max(1, capacity)
            self.capacity = value
            self.left = [Float](repeating: 0, count: value)
            self.right = [Float](repeating: 0, count: value)
        }

        @inline(__always)
        private func slot(for index: Int64) -> Int {
            let modulo = index % Int64(capacity)
            return modulo < 0 ? Int(modulo) + capacity : Int(modulo)
        }

        @inline(__always)
        mutating func write(
            offset: Int64,
            count: Int,
            left srcLeft: UnsafeMutablePointer<Float>,
            right srcRight: UnsafeMutablePointer<Float>,
            skip: Int
        ) {
            for i in 0..<count {
                let position = slot(for: offset + Int64(i))
                left[position] = srcLeft[skip + i]
                right[position] = srcRight[skip + i]
            }
        }

        /// 读一个样本并立即清零（消费即清空，保证不会重复输出）
        @inline(__always)
        mutating func consume(_ index: Int64) -> (Float, Float) {
            let position = slot(for: index)
            let leftValue = left[position]
            let rightValue = right[position]
            left[position] = 0
            right[position] = 0
            return (leftValue, rightValue)
        }

        /// 清空全部槽位并把写入游标回卷到 `index`
        mutating func clearAll(from index: Int64) {
            for i in 0..<capacity {
                left[i] = 0
                right[i] = 0
            }
            writtenEnd = index
            hasReceivedPacket = false
        }
    }
}
