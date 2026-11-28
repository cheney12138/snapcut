import AVFoundation
import CoreMedia
import Foundation

/// AudioTrackMixer 真实验证入口（不依赖 App，纯 AVFoundation/CoreMedia 构造真实 CMSampleBuffer）。
/// 由 scripts/test-audio-mixer.sh 编译运行：AudioTrackMixer + 本文件。
///
/// 8 个场景全部按「真实样本流」推进：造 48kHz/2ch/Float32/非交错 PCM 包 → push 进混音器 →
/// 读回输出块的 PTS 与样本，逐点比对波形 / 时间轴 / 诊断计数。
@main
struct TestAudioMixerMain {
    static func main() {
        do {
            let ctx = try MixerTestContext()
            try test1LinearMix(ctx: ctx)
            try test2SoftClip(ctx: ctx)
            try test3SingleTrackSilenceFallback(ctx: ctx)
            try test4BothSilentAdvanceClock(ctx: ctx)
            try test5HotPlugReconnect(ctx: ctx)
            try test6LateAndOverlappingPackets(ctx: ctx)
            try test7PacketJitterSnapping(ctx: ctx)
            try test8PauseResumeAndFinal(ctx: ctx)
            print("[TestAudioMixer] ALL PASS ✅")
        } catch {
            print("[TestAudioMixer] FAILED ❌: \(error)")
            exit(1)
        }
    }

    // MARK: - 场景 1：双路正弦波线性区精准叠加

    static func test1LinearMix(ctx: MixerTestContext) throws {
        print("[TestAudioMixer] 场景1: 440Hz(0.3) + 880Hz(0.3) 线性区精准叠加")
        let mixer = AudioTrackMixer()
        mixer.anchor(at: ctx.anchor)
        let system = Wave(leftAmp: 0.3, rightAmp: 0.3, frequency: 440, rightPhase: 0.5)
        let microphone = Wave(leftAmp: 0.3, rightAmp: 0.3, frequency: 880, rightPhase: 1.1)
        let total = 4_800

        var collector = OutputCollector(ctx: ctx)
        var start = 0
        while start < total {
            let count = min(mixer.config.chunkFrames, total - start)
            let outputs = try pushPacket(
                mixer, ctx: ctx, start: start, count: count, system: system, microphone: microphone
            )
            try collector.append(outputs)
            start += count
        }
        try collector.append(mixer.flushFinal(upTo: ctx.pts(at: total)))

        try expectEqual(collector.totalFrames, Int64(total), "总输出帧数")
        try expectEqual(mixer.emittedSamples, Int64(total), "emittedSamples")
        try expectTrue(mixer.stats.emittedChunks > 0, "emittedChunks > 0")
        try expectEqual(mixer.stats.clippedSamples, 0, "clippedSamples")

        var maxError: Float = 0
        for i in 0..<total {
            let expectedLeft = system.left(i) + microphone.left(i)
            let expectedRight = system.right(i) + microphone.right(i)
            maxError = max(maxError, abs(collector.left[i] - expectedLeft), abs(collector.right[i] - expectedRight))
        }
        try expectTrue(maxError < 1e-5, "叠加误差 \(maxError) < 1e-5")
        print("[TestAudioMixer] 场景1 PASS（maxError=\(maxError)）")
    }

    // MARK: - 场景 2：双路满幅叠加软削波

    static func test2SoftClip(ctx: MixerTestContext) throws {
        print("[TestAudioMixer] 场景2: 0.8 + 0.8 = 1.6 软削波（严格落在 (0.85, 0.99) 内，无硬削波）")
        let mixer = AudioTrackMixer()
        mixer.anchor(at: ctx.anchor)
        let system = Wave(leftAmp: 0.8, rightAmp: 0.8, frequency: 440)
        let microphone = Wave(leftAmp: 0.8, rightAmp: 0.8, frequency: 440)
        let total = 4_800

        var collector = OutputCollector(ctx: ctx)
        var start = 0
        while start < total {
            let count = min(mixer.config.chunkFrames, total - start)
            let outputs = try pushPacket(
                mixer, ctx: ctx, start: start, count: count, system: system, microphone: microphone
            )
            try collector.append(outputs)
            start += count
        }
        try collector.append(mixer.flushFinal(upTo: ctx.pts(at: total)))
        try expectEqual(collector.totalFrames, Int64(total), "总输出帧数")

        let knee = mixer.config.softClipKnee
        let ceiling = mixer.config.softClipCeiling
        var maxAbs: Float = 0
        var peakIndex = 0
        var peakSumAbs: Float = 0
        var overCeiling = 0
        var underKnee = 0
        var signFlips = 0
        for i in 0..<total {
            let sum = system.left(i) + microphone.left(i)
            let out = collector.left[i]
            maxAbs = max(maxAbs, abs(out), abs(collector.right[i]))
            // 严格上限：渐近逼近 ceiling，绝不越界（更不会出现 ±1.0 硬削波）
            if abs(out) > ceiling + 1e-6 || abs(collector.right[i]) > ceiling + 1e-6 { overCeiling += 1 }
            // 进入软削波区后仍然保号、且高于拐点
            if abs(sum) > knee + 0.01 {
                if abs(out) <= knee { underKnee += 1 }
                if (sum > 0) != (out > 0) { signFlips += 1 }
            }
            if abs(sum) > peakSumAbs {
                peakSumAbs = abs(sum)
                peakIndex = i
            }
        }
        try expectEqual(overCeiling, 0, "越 ceiling 的样本数")
        try expectEqual(underKnee, 0, "进入软削波区却未超拐点的样本数")
        try expectEqual(signFlips, 0, "软削波后符号翻转的样本数")
        try expectTrue(maxAbs > 0.95, "峰值 |out|=\(maxAbs) 已进入压缩区")
        try expectTrue(maxAbs < ceiling, "峰值 \(maxAbs) 严格小于 ceiling \(ceiling)")
        try expectTrue(mixer.stats.clippedSamples > 0, "clippedSamples > 0")

        // 逐点复算软削波公式（拐点 + tanh 过渡，保号）
        let peakSum = system.left(peakIndex) + microphone.left(peakIndex)
        let span = ceiling - knee
        let shapedPeak = knee + span * tanh((abs(peakSum) - knee) / span)
        let expectedPeak = peakSum < 0 ? -shapedPeak : shapedPeak
        try expectClose(collector.left[peakIndex], expectedPeak, tolerance: 1e-6, "峰值软削波公式")
        print("[TestAudioMixer] 场景2 PASS（峰值=\(maxAbs), clippedSamples=\(mixer.stats.clippedSamples)）")
    }

    // MARK: - 场景 3：单路活跃 + 另一路完全停发（抖动窗静音兜底）

    static func test3SingleTrackSilenceFallback(ctx: MixerTestContext) throws {
        print("[TestAudioMixer] 场景3: 仅系统声、麦克风完全停发 → 60ms 抖动窗后静音兜底")
        let mixer = AudioTrackMixer()
        mixer.anchor(at: ctx.anchor)
        let system = Wave(leftAmp: 0.4, rightAmp: 0.4, frequency: 300)
        let total = 9_600

        var collector = OutputCollector(ctx: ctx)
        var start = 0
        while start < total {
            let count = min(mixer.config.chunkFrames, total - start)
            let outputs = try pushPacket(
                mixer, ctx: ctx, start: start, count: count, system: system, microphone: nil
            )
            try collector.append(outputs)
            start += count
        }
        try collector.append(mixer.flushFinal(upTo: ctx.pts(at: total)))

        try expectEqual(collector.totalFrames, Int64(total), "总输出帧数")
        try expectTrue(mixer.stats.silenceFallbackChunks > 0, "silenceFallbackChunks > 0")
        try expectEqual(mixer.stats.micPacketsPushed, 0, "micPacketsPushed")

        var maxError: Float = 0
        for i in 0..<total {
            maxError = max(
                maxError,
                abs(collector.left[i] - system.left(i)),
                abs(collector.right[i] - system.right(i))
            )
        }
        try expectTrue(maxError < 1e-5, "单轨音频完整无丢失（误差 \(maxError) < 1e-5）")
        print("[TestAudioMixer] 场景3 PASS（silenceFallbackChunks=\(mixer.stats.silenceFallbackChunks)）")
    }

    // MARK: - 场景 4：双路均停发 + advanceClock 推进

    static func test4BothSilentAdvanceClock(ctx: MixerTestContext) throws {
        print("[TestAudioMixer] 场景4: 双路均停发，仅靠 advanceClock 推进 → 连续全 0 静音块")
        let mixer = AudioTrackMixer()
        mixer.anchor(at: ctx.anchor)
        let chunk = mixer.config.chunkFrames

        var collector = OutputCollector(ctx: ctx)
        for step in 1...40 {
            let outputs = mixer.advanceClock(to: ctx.pts(at: step * chunk))
            try collector.append(outputs)
        }

        try expectTrue(collector.totalFrames > 0, "推进期间产出了静音块")
        try expectTrue(
            collector.frameSizes.allSatisfy { $0 == chunk },
            "全部输出块大小均为 \(chunk)（实际 \(Set(collector.frameSizes))）"
        )
        try expectTrue(collector.left.allSatisfy { $0 == 0 }, "左声道全为 0")
        try expectTrue(collector.right.allSatisfy { $0 == 0 }, "右声道全为 0")
        try expectTrue(mixer.stats.silenceFallbackChunks > 0, "silenceFallbackChunks > 0")
        try expectEqual(mixer.emittedSamples, collector.totalFrames, "emittedSamples")
        // 抖动窗滞后：输出应紧跟推进终点，最多落后 4 个块（本次 3 块）
        let target = Int64(40 * chunk)
        try expectTrue(collector.totalFrames <= target, "输出不超过推进终点")
        try expectTrue(collector.totalFrames >= target - Int64(4 * chunk), "输出紧跟推进终点（滞后 ≤ 4 块）")
        print("[TestAudioMixer] 场景4 PASS（静音块 \(collector.chunkCount) 个，共 \(collector.totalFrames) 帧）")
    }

    // MARK: - 场景 5：设备热插拔断连再重连

    static func test5HotPlugReconnect(ctx: MixerTestContext) throws {
        print("[TestAudioMixer] 场景5: 0~0.3s 双路 → 0.3~0.8s 麦克风拔出 → 0.8~1.1s 恢复")
        let mixer = AudioTrackMixer()
        mixer.anchor(at: ctx.anchor)
        let system = Wave(leftAmp: 0.25, rightAmp: 0.25, frequency: 440, rightPhase: 0.3)
        let microphone = Wave(leftAmp: 0.2, rightAmp: 0.2, frequency: 660, rightPhase: 0.9)
        let total = 52_800      // 1.1s
        let micOffStart = 14_400 // 0.3s
        let micOnStart = 38_400  // 0.8s
        let packet = 480         // 与三个边界（14400 / 38400）整除

        var collector = OutputCollector(ctx: ctx)
        var start = 0
        while start < total {
            let count = min(packet, total - start)
            let micActive = start < micOffStart || start >= micOnStart
            let outputs = try pushPacket(
                mixer, ctx: ctx, start: start, count: count,
                system: system, microphone: micActive ? microphone : nil
            )
            try collector.append(outputs)
            start += count
        }
        try collector.append(mixer.flushFinal(upTo: ctx.pts(at: total)))

        try expectEqual(collector.totalFrames, Int64(total), "总输出帧数（全程无空洞）")
        try expectTrue(mixer.stats.silenceFallbackChunks > 0, "拔麦期间触发静音兜底")

        var maxError: Float = 0
        for i in 0..<total {
            let micPresent = i < micOffStart || i >= micOnStart
            let expectedLeft = system.left(i) + (micPresent ? microphone.left(i) : 0)
            let expectedRight = system.right(i) + (micPresent ? microphone.right(i) : 0)
            maxError = max(maxError, abs(collector.left[i] - expectedLeft), abs(collector.right[i] - expectedRight))
        }
        try expectTrue(maxError < 1e-5, "三段波形能量均符合预期（误差 \(maxError) < 1e-5）")

        // 分段能量核对：断麦段只剩系统声，恢复段重新叠加
        let offRMS = rms(collector.left[micOffStart..<(micOffStart + 9_600)])
        let onRMS = rms(collector.left[micOnStart..<(micOnStart + 9_600)])
        try expectTrue(offRMS > 0.1, "断麦段仍有系统声（RMS=\(offRMS)）")
        try expectTrue(
            abs(offRMS - Float(0.25 / 2.0.squareRoot())) < 0.02,
            "断麦段 RMS≈系统单路 0.177（实际 \(offRMS)）"
        )
        try expectTrue(onRMS > offRMS, "恢复段能量回升（\(onRMS) > \(offRMS)）")
        print("[TestAudioMixer] 场景5 PASS（offRMS=\(offRMS), onRMS=\(onRMS)）")
    }

    // MARK: - 场景 6：过期 / 迟到 / 部分重叠包过滤

    static func test6LateAndOverlappingPackets(ctx: MixerTestContext) throws {
        print("[TestAudioMixer] 场景6: 过期包丢弃 + 部分重叠包截取（PTS 严格不倒退）")
        let mixer = AudioTrackMixer()
        mixer.anchor(at: ctx.anchor)
        let system = Wave(leftAmp: 0.3, rightAmp: 0.3, frequency: 440)
        let microphone = Wave(leftAmp: 0.3, rightAmp: 0.3, frequency: 660)
        let total = 9_600
        let packet = mixer.config.chunkFrames

        var collector = OutputCollector(ctx: ctx)
        var start = 0
        while start < 4_800 {
            let count = min(packet, 4_800 - start)
            let outputs = try pushPacket(
                mixer, ctx: ctx, start: start, count: count, system: system, microphone: microphone
            )
            try collector.append(outputs)
            start += count
        }
        let emittedBeforeStale = mixer.emittedSamples

        // 1) 完全过期包（两轨各一个）：内容落在已输出区间，应直接丢弃
        let staleBuffer = try makeBuffer(ctx: ctx, start: 0, count: packet, wave: system)
        _ = mixer.push(staleBuffer, source: .system, adjustedPTS: ctx.pts(at: 0))
        let staleMic = try makeBuffer(ctx: ctx, start: 0, count: packet, wave: microphone)
        _ = mixer.push(staleMic, source: .microphone, adjustedPTS: ctx.pts(at: 0))
        // 2) 部分重叠包：头部 512 帧已被消费，只截取有效尾部
        let overlapStart = Int(emittedBeforeStale) - 512
        let overlapBuffer = try makeBuffer(ctx: ctx, start: overlapStart, count: packet, wave: system)
        let overlapOutputs = mixer.push(overlapBuffer, source: .system, adjustedPTS: ctx.pts(at: overlapStart))
        try collector.append(overlapOutputs)
        // 3) 负索引包（PTS 早于锚点）：同样按部分重叠处理，不得崩溃
        let negativeStart = -1_024
        let negativeBuffer = try makeBuffer(ctx: ctx, start: negativeStart, count: packet, wave: microphone)
        _ = mixer.push(negativeBuffer, source: .microphone, adjustedPTS: ctx.pts(at: negativeStart))

        try expectTrue(mixer.emittedSamples >= emittedBeforeStale, "迟到包不会回退输出游标")
        try expectTrue(mixer.stats.latePacketsDropped >= 3, "latePacketsDropped=\(mixer.stats.latePacketsDropped) ≥ 3")

        start = 4_800
        while start < total {
            let count = min(packet, total - start)
            let outputs = try pushPacket(
                mixer, ctx: ctx, start: start, count: count, system: system, microphone: microphone
            )
            try collector.append(outputs)
            start += count
        }
        try collector.append(mixer.flushFinal(upTo: ctx.pts(at: total)))

        try expectEqual(collector.totalFrames, Int64(total), "总输出帧数")
        var maxError: Float = 0
        for i in 0..<total {
            let expectedLeft = system.left(i) + microphone.left(i)
            maxError = max(maxError, abs(collector.left[i] - expectedLeft))
        }
        try expectTrue(maxError < 1e-5, "过滤迟到包后波形仍然正确（误差 \(maxError) < 1e-5）")
        print("[TestAudioMixer] 场景6 PASS（latePacketsDropped=\(mixer.stats.latePacketsDropped)）")
    }

    // MARK: - 场景 7：包边界 ±0.5ms 随机微抖动吸附

    static func test7PacketJitterSnapping(ctx: MixerTestContext) throws {
        print("[TestAudioMixer] 场景7: 麦克风包 PTS ±0.5ms（±24 样本）随机抖动 → 吸附后无断层尖刺")
        let mixer = AudioTrackMixer()
        mixer.anchor(at: ctx.anchor)
        let system = Wave(leftAmp: 0.3, rightAmp: 0.3, frequency: 440)
        let microphone = Wave(leftAmp: 0.3, rightAmp: 0.3, frequency: 660)
        let total = 9_600
        let packet = mixer.config.chunkFrames
        var rng = LCG(seed: 20_261_127)

        var collector = OutputCollector(ctx: ctx)
        var start = 0
        var jitteredPackets = 0
        var maxJitter = 0
        while start < total {
            let count = min(packet, total - start)
            // 首包不抖：没有前一包末端可供吸附（开工瞬间的 ±24 偏移本身无参照，也不该被吞掉）
            let jitter = start == 0 ? 0 : rng.jitter(maxSamples: 24)   // ±0.5ms @48kHz
            if jitter != 0 {
                jitteredPackets += 1
                maxJitter = max(maxJitter, abs(jitter))
            }
            let outputs = try pushPacket(
                mixer, ctx: ctx, start: start, count: count,
                system: system, microphone: microphone,
                microphoneOffset: jitter
            )
            try collector.append(outputs)
            start += count
        }
        try collector.append(mixer.flushFinal(upTo: ctx.pts(at: total)))

        try expectEqual(collector.totalFrames, Int64(total), "总输出帧数")
        try expectTrue(jitteredPackets > 0, "确实投喂了 \(jitteredPackets) 个带抖动包（最大 ±\(maxJitter) 样本）")

        // 系统轨从不丢包，所以「输出 - 系统声」就是麦克风轨的真实贡献（残留信号）。
        // 未吸附时包缝会留下 ±24 个精确 0（正向抖动）或 24 个重复样本（负向抖动），
        // 因此残留信号一旦出现长串 0 就是断层——这是吸附是否生效的硬指纹。
        // 分析区间排除末尾最后一个包：吸附允许「向前贴齐」，累计偏移为负时录音末尾
        // 会自然短 ≤24 个样本（0.5ms），由 flushFinal 补静音属于预期行为，不属于断层。
        let analyzed = total - packet
        var residual = [Float](repeating: 0, count: total)
        for i in 0..<total { residual[i] = collector.left[i] - system.left(i) }
        var zeroRun = 0
        var longestZeroRun = 0
        for i in 0..<analyzed {
            if abs(residual[i]) < 1e-5 {
                zeroRun += 1
                longestZeroRun = max(longestZeroRun, zeroRun)
            } else {
                zeroRun = 0
            }
        }
        try expectTrue(longestZeroRun <= 1, "麦克风残留最长连续 0 值 = \(longestZeroRun) ≤ 1（无断层尖刺）")

        // 幅度受控：0.3 + 0.3 线性区，任何样本都不该越界
        let maxAbs = collector.left.map { abs($0) }.max() ?? 0
        try expectTrue(maxAbs <= 0.61, "峰值 \(maxAbs) ≤ 0.61（未迸出线性格）")

        // 块级能量连续：残留信号是幅度 0.3 的 660Hz 正弦（RMS≈0.212），
        // 一旦成段断层对应块的 RMS 会明显塌下去。
        var blockRMS: [Float] = []
        var offset = 0
        while offset + packet <= analyzed {
            blockRMS.append(rms(residual[offset..<(offset + packet)]))
            offset += packet
        }
        let worstRMS = blockRMS.max() ?? 1
        let quietestRMS = blockRMS.min() ?? 0
        try expectTrue(quietestRMS > 0.18, "最弱块残留 RMS=\(quietestRMS) > 0.18（无成段丢数据）")
        try expectTrue(worstRMS < 0.25, "最强块残留 RMS=\(worstRMS) < 0.25（无重复叠加）")
        print(
            "[TestAudioMixer] 场景7 PASS（抖动包 \(jitteredPackets)/\(collector.chunkCount), 最长 0 值连续=\(longestZeroRun), "
                + "残留 RMS 区间 [\(quietestRMS), \(worstRMS)]）"
        )
    }

    // MARK: - 场景 8：多次 Pause/Resume + flushFinal

    static func test8PauseResumeAndFinal(ctx: MixerTestContext) throws {
        print("[TestAudioMixer] 场景8: 3 段录制 + 2 次 flushForPause + flushFinal → PTS 严格单调、总时长精准")
        let mixer = AudioTrackMixer()
        mixer.anchor(at: ctx.anchor)
        let systemA = Wave(leftAmp: 0.25, rightAmp: 0.25, frequency: 440)
        let microphoneA = Wave(leftAmp: 0.2, rightAmp: 0.2, frequency: 660)
        let systemB = Wave(leftAmp: 0.3, rightAmp: 0.3, frequency: 550)
        let microphoneB = Wave(leftAmp: 0.15, rightAmp: 0.15, frequency: 770)
        let systemC = Wave(leftAmp: 0.2, rightAmp: 0.2, frequency: 330)
        let microphoneC = Wave(leftAmp: 0.18, rightAmp: 0.18, frequency: 880)

        // (起, 止) 绝对样本序号
        let segmentA = 0..<19_200       // 0.0 ~ 0.4s
        let segmentB = 48_000..<67_200  // 1.0 ~ 1.4s（中间 0.6s 暂停）
        let segmentC = 96_000..<110_400 // 2.0 ~ 2.3s（中间 0.6s 暂停）
        let targetEnd = 110_400

        var collector = OutputCollector(ctx: ctx)
        var maxError: Float = 0

        // 第一段
        try pushRange(
            mixer, ctx: ctx, range: segmentA,
            system: systemA, microphone: microphoneA, collector: &collector
        )
        try collector.append(mixer.flushForPause(upTo: ctx.pts(at: segmentA.upperBound)))
        try expectEqual(mixer.emittedSamples, Int64(segmentA.upperBound), "第一段收口后 emittedSamples")

        // 第二段（跨过暂停空洞）
        try pushRange(
            mixer, ctx: ctx, range: segmentB,
            system: systemB, microphone: microphoneB, collector: &collector
        )
        try collector.append(mixer.flushForPause(upTo: ctx.pts(at: segmentB.upperBound)))
        try expectEqual(mixer.emittedSamples, Int64(segmentB.upperBound), "第二段收口后 emittedSamples")

        // 第三段 + 最终收尾
        try pushRange(
            mixer, ctx: ctx, range: segmentC,
            system: systemC, microphone: microphoneC, collector: &collector
        )
        try collector.append(mixer.flushFinal(upTo: ctx.pts(at: targetEnd)))

        // 时间轴：Collector 已逐块校验 PTS == anchor + 累计帧数（严格单调、零重叠、零空洞）
        try expectEqual(collector.totalFrames, Int64(targetEnd), "总采样数 == 目标时长")
        try expectEqual(mixer.emittedSamples, Int64(targetEnd), "emittedSamples == 目标时长")
        try expectTrue(collector.chunkCount >= 3, "输出块数 \(collector.chunkCount) ≥ 3")

        // 内容：活跃段 == 对应双路合成；暂停空洞严格为 0（前后样本绝不串台）
        for i in 0..<targetEnd {
            let expectedLeft: Float
            let expectedRight: Float
            if segmentA.contains(i) {
                expectedLeft = systemA.left(i) + microphoneA.left(i)
                expectedRight = systemA.right(i) + microphoneA.right(i)
            } else if segmentB.contains(i) {
                expectedLeft = systemB.left(i) + microphoneB.left(i)
                expectedRight = systemB.right(i) + microphoneB.right(i)
            } else if segmentC.contains(i) {
                expectedLeft = systemC.left(i) + microphoneC.left(i)
                expectedRight = systemC.right(i) + microphoneC.right(i)
            } else {
                expectedLeft = 0
                expectedRight = 0
            }
            maxError = max(maxError, abs(collector.left[i] - expectedLeft), abs(collector.right[i] - expectedRight))
        }
        try expectTrue(maxError < 1e-5, "三段波形 + 暂停静音全部符合预期（误差 \(maxError) < 1e-5）")
        print("[TestAudioMixer] 场景8 PASS（总块数=\(collector.chunkCount), 总帧数=\(collector.totalFrames)）")
    }
}

// MARK: - 测试上下文与工具

/// 规范格式（48kHz / 2ch / Float32 / 非交错）+ 声道布局 + 固定锚点。
/// 锚点故意取 3s 而非 0：验证 PTS 反算不依赖「从 0 起算」。
struct MixerTestContext {
    let format: AVAudioFormat
    let formatDescription: CMAudioFormatDescription
    let anchor: CMTime

    init() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw TestError("无法创建 48kHz/2ch 规范格式")
        }
        var asbd = format.streamDescription.pointee
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        layout.mNumberChannelDescriptions = 0
        // tag 型布局无附加通道描述，尺寸只算 3 个 UInt32 头部（与 AudioFormatNormalizer 一致）
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
        guard status == noErr, let description else {
            throw TestError("无法创建 CMAudioFormatDescription（status=\(status)）")
        }
        self.format = format
        self.formatDescription = description
        self.anchor = CMTime(value: 144_000, timescale: 48_000)
    }

    /// 绝对样本序号 → 绝对 PTS（时基 48000，整数 tick 无浮点误差）
    func pts(at sampleIndex: Int) -> CMTime {
        CMTimeAdd(anchor, CMTime(value: Int64(sampleIndex), timescale: 48_000))
    }
}

/// 正弦波发生器：按绝对样本序号取值，左右声道可独立相位（验证立体声不被压成单声道）。
struct Wave {
    var leftAmp: Float
    var rightAmp: Float
    var frequency: Double
    var rightPhase: Double = 0
    var leftPhase: Double = 0

    func left(_ index: Int) -> Float {
        leftAmp * Float(sin(2 * Double.pi * frequency * Double(index) / 48_000 + leftPhase))
    }

    func right(_ index: Int) -> Float {
        rightAmp * Float(sin(2 * Double.pi * frequency * Double(index) / 48_000 + leftPhase + rightPhase))
    }
}

/// 确定性伪随机（LCG），保证 ±0.5ms 抖动序列可复现
struct LCG {
    var state: UInt64

    init(seed: UInt64) {
        state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }

    mutating func jitter(maxSamples: Int) -> Int {
        let span = UInt64(maxSamples * 2 + 1)
        return Int(next() % span) - maxSamples
    }
}

/// 输出收集器：逐块校验 PTS 连续（严格单调 / 零重叠 / 零空洞）并展平成连续波形。
struct OutputCollector {
    let ctx: MixerTestContext
    var left: [Float] = []
    var right: [Float] = []
    var frameSizes: [Int] = []
    var totalFrames: Int64 = 0
    var chunkCount: Int { frameSizes.count }

    init(ctx: MixerTestContext) {
        self.ctx = ctx
    }

    mutating func append(_ buffers: [CMSampleBuffer]) throws {
        for buffer in buffers {
            let frames = CMSampleBufferGetNumSamples(buffer)
            guard frames > 0 else { throw TestError("收到 0 帧输出块") }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            let expected = CMTimeAdd(ctx.anchor, CMTime(value: totalFrames, timescale: 48_000))
            guard CMTimeCompare(pts, expected) == 0 else {
                throw TestError(
                    "PTS 不连续：实际 \(TestAudioMixerMain.formatTime(pts))，期望 \(TestAudioMixerMain.formatTime(expected))"
                        + "（已累计 \(totalFrames) 帧）"
                )
            }
            let planes = try TestAudioMixerMain.readPlanes(buffer, ctx: ctx)
            left.append(contentsOf: planes.0)
            right.append(contentsOf: planes.1)
            frameSizes.append(frames)
            totalFrames += Int64(frames)
        }
    }
}

extension TestAudioMixerMain {
    // MARK: - 造包 / 读包

    /// 造一个规范格式音频包（内容按绝对样本序号取值，便于逐点比对）
    static func makeBuffer(
        ctx: MixerTestContext,
        start: Int,
        count: Int,
        wave: Wave
    ) throws -> CMSampleBuffer {
        guard count > 0,
              let pcm = AVAudioPCMBuffer(
                  pcmFormat: ctx.format,
                  frameCapacity: AVAudioFrameCount(count)
              ),
              let channelData = pcm.floatChannelData
        else { throw TestError("无法分配输入 PCM 缓冲（count=\(count)）") }

        pcm.frameLength = AVAudioFrameCount(count)
        let left = channelData[0]
        let right = channelData[1]
        for i in 0..<count {
            let index = start + i
            left[i] = wave.left(index)
            right[i] = wave.right(index)
        }
        return try makeSampleBuffer(
            pcm: pcm, frames: count, pts: ctx.pts(at: start), formatDescription: ctx.formatDescription
        )
    }

    static func makeSampleBuffer(
        pcm: AVAudioPCMBuffer,
        frames: Int,
        pts: CMTime,
        formatDescription: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let bufferList = pcm.mutableAudioBufferList
        let audioBuffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard audioBuffers.count > 0 else { throw TestError("输入 bufferList 为空") }
        let bytesPerFrame = UInt32(max(1, pcm.format.streamDescription.pointee.mBytesPerFrame))
        let planeBytes = UInt32(frames) * bytesPerFrame
        for index in 0..<audioBuffers.count {
            audioBuffers[index].mDataByteSize = planeBytes
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
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
            throw TestError("CMSampleBufferCreate 失败（status=\(status)）")
        }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: bufferList
        )
        guard status == noErr else {
            throw TestError("CMSampleBufferSetDataBufferFromAudioBufferList 失败（status=\(status)）")
        }
        return sampleBuffer
    }

    /// 连续推一段区间（每包 chunkFrames，末尾不足一块按余数推）
    static func pushRange(
        _ mixer: AudioTrackMixer,
        ctx: MixerTestContext,
        range: Range<Int>,
        system: Wave,
        microphone: Wave,
        collector: inout OutputCollector
    ) throws {
        var start = range.lowerBound
        while start < range.upperBound {
            let count = min(mixer.config.chunkFrames, range.upperBound - start)
            let outputs = try pushPacket(
                mixer, ctx: ctx, start: start, count: count, system: system, microphone: microphone
            )
            try collector.append(outputs)
            start += count
        }
    }

    /// 推一个包（可分别给 system / microphone 附加 PTS 抖动），返回混音器吐出的块
    static func pushPacket(
        _ mixer: AudioTrackMixer,
        ctx: MixerTestContext,
        start: Int,
        count: Int,
        system: Wave?,
        microphone: Wave?,
        systemOffset: Int = 0,
        microphoneOffset: Int = 0
    ) throws -> [CMSampleBuffer] {
        var output: [CMSampleBuffer] = []
        let nominalPTS = ctx.pts(at: start)
        if let system {
            let buffer = try makeBuffer(ctx: ctx, start: start, count: count, wave: system)
            let pts = CMTimeAdd(nominalPTS, CMTime(value: Int64(systemOffset), timescale: 48_000))
            output += mixer.push(buffer, source: .system, adjustedPTS: pts)
        }
        if let microphone {
            let buffer = try makeBuffer(ctx: ctx, start: start, count: count, wave: microphone)
            let pts = CMTimeAdd(nominalPTS, CMTime(value: Int64(microphoneOffset), timescale: 48_000))
            output += mixer.push(buffer, source: .microphone, adjustedPTS: pts)
        }
        return output
    }

    static func readPlanes(_ sampleBuffer: CMSampleBuffer, ctx: MixerTestContext) throws -> ([Float], [Float]) {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: ctx.format, frameCapacity: AVAudioFrameCount(frames))
        else { throw TestError("无法分配输出读取缓冲（frames=\(frames)）") }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr, let channelData = pcm.floatChannelData else {
            throw TestError("输出块拷贝失败（status=\(status)）")
        }
        let left = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        let right = Array(UnsafeBufferPointer(start: channelData[1], count: frames))
        return (left, right)
    }

    // MARK: - 断言

    static func expectTrue(_ condition: Bool, _ label: String) throws {
        guard condition else { throw TestError("断言失败：\(label)") }
        print("[TestAudioMixer]   ✓ \(label)")
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        guard actual == expected else {
            throw TestError("\(label)：实际 \(actual) ≠ 期望 \(expected)")
        }
        print("[TestAudioMixer]   ✓ \(label) = \(actual)")
    }

    static func expectClose(_ actual: Float, _ expected: Float, tolerance: Float, _ label: String) throws {
        guard abs(actual - expected) <= tolerance else {
            throw TestError("\(label)：实际 \(actual) ≠ 期望 \(expected) ± \(tolerance)")
        }
        print("[TestAudioMixer]   ✓ \(label) = \(actual)（期望 \(expected) ± \(tolerance)）")
    }

    // MARK: - 数值工具

    static func rms(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        var sum: Double = 0
        for value in slice { sum += Double(value) * Double(value) }
        return Float((sum / Double(slice.count)).squareRoot())
    }

    static func formatTime(_ time: CMTime) -> String {
        String(format: "%.6fs(=%lld/%d)", time.seconds, time.value, time.timescale)
    }
}

struct TestError: LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}
