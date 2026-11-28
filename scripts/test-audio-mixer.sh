#!/bin/bash
# 双轨 PCM 混音器真实验证：编译 AudioTrackMixer.swift + scripts/TestAudioMixerMain.swift
# 用 AVFoundation/CoreMedia 造真实 CMSampleBuffer 音频包，跑 8 个场景（叠加/软削波/单轨兜底/
# 全静音推进/热插拔/迟到包/抖动吸附/暂停恢复），断言波形、时间轴与诊断计数。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=/tmp/audio_mixer_test
MOD_CACHE=/tmp/swift_modcache
mkdir -p "$OUT_DIR" "$MOD_CACHE"

echo "[test-audio-mixer] 编译 Release (-O, swift-version 6, -warnings-as-errors)..."
swiftc -swift-version 6 -warnings-as-errors -O \
    -module-cache-path "$MOD_CACHE" \
    Sources/Adapters/Recording/AudioTrackMixer.swift \
    scripts/TestAudioMixerMain.swift \
    -o "$OUT_DIR/test-audio-mixer"

echo "[test-audio-mixer] 运行 Release..."
"$OUT_DIR/test-audio-mixer"

echo "[test-audio-mixer] 编译 Debug (-Onone 性能回归门禁：make dev 使用 Debug)..."
swiftc -swift-version 6 -warnings-as-errors -Onone \
    -module-cache-path "$MOD_CACHE" \
    Sources/Adapters/Recording/AudioTrackMixer.swift \
    scripts/TestAudioMixerMain.swift \
    -o "$OUT_DIR/test-audio-mixer-debug"

echo "[test-audio-mixer] 运行 Debug..."
"$OUT_DIR/test-audio-mixer-debug"

echo "[test-audio-mixer] DONE ✅"
