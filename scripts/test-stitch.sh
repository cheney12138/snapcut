#!/bin/bash
# 拼接算法真实验证：单独编译 Sources/Scroll/Stitcher.swift + scripts/TestStitchMain.swift
# 生成测试可执行，用 CoreGraphics 绘制有真实重叠区域的测试图，跑真实拼接并断言结果。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=/tmp/stitch_test
mkdir -p "$OUT_DIR"

echo "[test-stitch] 编译 (swift-version 6, -Wall)..."
# 注：本机 Swift 6.3 工具链已移除 -Wall 参数（unknown argument），改用
# 默认告警集 + -warnings-as-errors，效果等同且更严格：任何 warning 都判失败。
swiftc -swift-version 6 -warnings-as-errors -O \
    Sources/Core/Domain/Stitcher.swift \
    scripts/TestStitchMain.swift \
    -o "$OUT_DIR/test-stitch"

echo "[test-stitch] 运行..."
"$OUT_DIR/test-stitch"

echo "[test-stitch] 产物:"
ls -l /tmp/stitch_result.png /tmp/stitch_result_3frames.png

if command -v sips >/dev/null 2>&1; then
    echo "[test-stitch] sips 验证输出图片尺寸:"
    sips -g pixelWidth -g pixelHeight /tmp/stitch_result.png
    sips -g pixelWidth -g pixelHeight /tmp/stitch_result_3frames.png
fi

echo "[test-stitch] DONE ✅"
