#!/bin/bash
# 已画标注二次编辑的真实验证：编译 AnnotationModel.swift + AnnotationEditing.swift
# + RGBAColor.swift + Shared/Log.swift + scripts/TestAnnotationEditingMain.swift
#
# 覆盖 16 个场景（7 种 Shape 包围盒 / 箭头与高亮线段命中 / 矩形描边环与内部穿透 /
# 椭圆环与极小椭圆退化 / 马赛克·序号·文字命中 / 顶层优先 / 操控柄布局与命中优先级 /
# .body 平移 / 箭头端点拖拽 / 矩形与马赛克四角缩放（跨对角翻转 + minSize 保底）/
# 椭圆四角缩放回算 / 手柄与形状不匹配 / previewReplace+commitMutation 单步撤销 /
# 无变化不污染撤销栈 / remove(at:) 与 updateStyle(at:)）。
#
# 双口径：Release (-O 发版同口径) + Debug (-Onone，与 make dev 构建一致)，Swift 6 -warnings-as-errors。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=/tmp/annotation_editing_test
MOD_CACHE=/tmp/swift_modcache
mkdir -p "$OUT_DIR" "$MOD_CACHE"

SRC_FILES=(
    Sources/Core/Domain/RGBAColor.swift
    Sources/Core/Domain/AnnotationModel.swift
    Sources/Core/Domain/AnnotationEditing.swift
    Sources/Core/Shared/Log.swift
    scripts/TestAnnotationEditingMain.swift
)

echo "[test-annotation-editing] 编译 Release (-O, swift-version 6, -warnings-as-errors)..."
swiftc -swift-version 6 -warnings-as-errors -O \
    -module-cache-path "$MOD_CACHE" \
    "${SRC_FILES[@]}" \
    -o "$OUT_DIR/test-annotation-editing"

echo "[test-annotation-editing] 运行 Release..."
"$OUT_DIR/test-annotation-editing"

echo "[test-annotation-editing] 编译 Debug (-Onone，与 make dev 构建口径一致)..."
swiftc -swift-version 6 -warnings-as-errors -Onone \
    -module-cache-path "$MOD_CACHE" \
    "${SRC_FILES[@]}" \
    -o "$OUT_DIR/test-annotation-editing-debug"

echo "[test-annotation-editing] 运行 Debug..."
"$OUT_DIR/test-annotation-editing-debug"

echo "[test-annotation-editing] DONE ✅"
