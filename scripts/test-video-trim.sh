#!/bin/bash
# 录屏头尾裁剪的纯 Core 真实验证：编译 RecordingModel.swift + scripts/TestVideoTrimMain.swift
#
# 覆盖 12 个场景（full(duration:) 整段语义 / 起止越界钳制 / 起止重合的 minSpan 保底 /
# 总长小于 minSpan 的退化 / isTrimmed 的 0.05s 噪声阈值 / 归一化分数与总长 0 退化 /
# updatingStartFraction 与 updatingEndFraction 互不越界 / clampingTime / trimmedDuration /
# NaN 与无穷入参兜底 / RecordingGeometry.formatPreciseTime）。
#
# 为什么只编 Core 两个文件：VideoTrimRange 是纯值类型，验证它不需要 AVFoundation；
# 单测一旦拖进 AppKit/AVFoundation 就再也没法在 Linux/CI 或普通 swiftc 下跑。
#
# 双口径：Release (-O 发版同口径) + Debug (-Onone，与 make dev 构建一致)，Swift 6 -warnings-as-errors。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=/tmp/video_trim_test
MOD_CACHE=/tmp/swift_modcache
mkdir -p "$OUT_DIR" "$MOD_CACHE"

SRC_FILES=(
    Sources/Core/Domain/RecordingModel.swift
    scripts/TestVideoTrimMain.swift
)

echo "[test-video-trim] 编译 Release (-O, swift-version 6, -warnings-as-errors)..."
swiftc -swift-version 6 -warnings-as-errors -O \
    -module-cache-path "$MOD_CACHE" \
    "${SRC_FILES[@]}" \
    -o "$OUT_DIR/test-video-trim"

echo "[test-video-trim] 运行 Release..."
"$OUT_DIR/test-video-trim"

echo "[test-video-trim] 编译 Debug (-Onone，与 make dev 构建口径一致)..."
swiftc -swift-version 6 -warnings-as-errors -Onone \
    -module-cache-path "$MOD_CACHE" \
    "${SRC_FILES[@]}" \
    -o "$OUT_DIR/test-video-trim-debug"

echo "[test-video-trim] 运行 Debug..."
"$OUT_DIR/test-video-trim-debug"

echo "[test-video-trim] DONE ✅"
