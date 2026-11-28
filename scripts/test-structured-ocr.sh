#!/bin/bash
# 结构化 OCR 文档解析真实验证：编译 StructuredOCR.swift + scripts/TestStructuredOCRMain.swift
# 用带归一化包围盒的 OCRPositionedBlock 跑 9 个场景（单段零误判 / 软换行与空行拆段 /
# 句末短行与首行缩进断段 / H1-H2 标题 / 无序与有序列表含悬挂折行 / 整图纯表格向后兼容 /
# 混排标题+段落+局部表格+列表 / 三种渲染输出与二维码安全校验）。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=/tmp/structured_ocr_test
MOD_CACHE=/tmp/swift_modcache
mkdir -p "$OUT_DIR" "$MOD_CACHE"

echo "[test-structured-ocr] 编译 Release (-O, swift-version 6, -warnings-as-errors)..."
swiftc -swift-version 6 -warnings-as-errors -O \
    -module-cache-path "$MOD_CACHE" \
    Sources/Core/Domain/StructuredOCR.swift \
    scripts/TestStructuredOCRMain.swift \
    -o "$OUT_DIR/test-structured-ocr"

echo "[test-structured-ocr] 运行 Release..."
"$OUT_DIR/test-structured-ocr"

echo "[test-structured-ocr] 编译 Debug (-Onone 性能回归门禁：make dev 使用 Debug)..."
swiftc -swift-version 6 -warnings-as-errors -Onone \
    -module-cache-path "$MOD_CACHE" \
    Sources/Core/Domain/StructuredOCR.swift \
    scripts/TestStructuredOCRMain.swift \
    -o "$OUT_DIR/test-structured-ocr-debug"

echo "[test-structured-ocr] 运行 Debug..."
"$OUT_DIR/test-structured-ocr-debug"

echo "[test-structured-ocr] DONE ✅"
