#!/bin/bash
# 智能框选候选栈真实验证：编译 SmartSelectionModel.swift + scripts/TestSmartSelectionMain.swift
# 覆盖 6 个场景（空输入 / 近似满屏大窗剪枝与滚轮切出 / 面积排序 + 四边差<4 与 IoU>0.94 去重 /
# 默认层级文本行 vs 紧贴控件 / screenFrame 与窗口域裁剪 + <12pt 噪点过滤 / 无 AX 时视觉矩形兜底）。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=/tmp/smart_selection_test
MOD_CACHE=/tmp/swift_modcache
mkdir -p "$OUT_DIR" "$MOD_CACHE"

echo "[test-smart-selection] 编译 Release (-O, swift-version 6, -warnings-as-errors)..."
swiftc -swift-version 6 -warnings-as-errors -O \
    -module-cache-path "$MOD_CACHE" \
    Sources/Core/Domain/SmartSelectionModel.swift \
    scripts/TestSmartSelectionMain.swift \
    -o "$OUT_DIR/test-smart-selection"

echo "[test-smart-selection] 运行 Release..."
"$OUT_DIR/test-smart-selection"

echo "[test-smart-selection] 编译 Debug (-Onone，与 make dev 构建口径一致)..."
swiftc -swift-version 6 -warnings-as-errors -Onone \
    -module-cache-path "$MOD_CACHE" \
    Sources/Core/Domain/SmartSelectionModel.swift \
    scripts/TestSmartSelectionMain.swift \
    -o "$OUT_DIR/test-smart-selection-debug"

echo "[test-smart-selection] 运行 Debug..."
"$OUT_DIR/test-smart-selection-debug"

echo "[test-smart-selection] DONE ✅"
