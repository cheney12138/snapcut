#!/bin/bash
# 拼接算法真实验证：编译 TileMotionEstimator.swift + Stitcher.swift + scripts/TestStitchMain.swift
# 生成测试可执行，用 CoreGraphics 绘制真实像素与多种场景测试图，跑真实拼接并断言结果。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=/tmp/stitch_test
MOD_CACHE=/tmp/swift_modcache
mkdir -p "$OUT_DIR" "$MOD_CACHE"

echo "[test-stitch] 编译 Release (-O, swift-version 6, -warnings-as-errors)..."
swiftc -swift-version 6 -warnings-as-errors -O \
    -module-cache-path "$MOD_CACHE" \
    Sources/Core/Domain/TileMotionEstimator.swift \
    Sources/Core/Domain/Stitcher.swift \
    scripts/TestStitchMain.swift \
    -o "$OUT_DIR/test-stitch"

echo "[test-stitch] 运行 Release..."
"$OUT_DIR/test-stitch"

echo "[test-stitch] 编译 Debug (-Onone 性能回归门禁：make dev 使用 Debug)..."
swiftc -swift-version 6 -warnings-as-errors -Onone \
    -module-cache-path "$MOD_CACHE" \
    Sources/Core/Domain/TileMotionEstimator.swift \
    Sources/Core/Domain/Stitcher.swift \
    scripts/TestStitchMain.swift \
    -o "$OUT_DIR/test-stitch-debug"

echo "[test-stitch] 运行 Debug..."
"$OUT_DIR/test-stitch-debug"

echo "[test-stitch] 产物:"
ls -l /tmp/stitch_result.png /tmp/stitch_result_3frames.png

if command -v sips >/dev/null 2>&1; then
    echo "[test-stitch] sips 验证输出图片尺寸:"
    sips -g pixelWidth -g pixelHeight /tmp/stitch_result.png
    sips -g pixelWidth -g pixelHeight /tmp/stitch_result_3frames.png
fi

echo "[test-stitch] DONE ✅"
