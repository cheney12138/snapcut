#!/bin/bash
# 六边形架构守卫：依赖方向只能向内
#
#   UI / Adapters  →  Core/Ports  →  Core/Domain
#
# 规则：
#   1. Sources/Core/** 只允许 import Foundation / CoreGraphics / os / Combine?
#      （禁止 AppKit、ScreenCaptureKit、Vision、Carbon、UniformTypeIdentifiers）
#   2. Sources/UI/** 禁止 import ScreenCaptureKit / Vision（必须走端口）
#   3. Sources/Adapters/**、Sources/UI/** 可以有 AppKit（它们就是外圈）
set -uo pipefail
fail=0
viol() { echo "  ✗ $1"; fail=1; }

echo "arch · Core 纯净性"
for f in $(find Sources/Core -name "*.swift" 2>/dev/null); do
  bad=$(grep -E "^import (AppKit|UIKit|ScreenCaptureKit|Vision|Carbon|UniformTypeIdentifiers)" "$f" | tr '\n' ' ')
  if [ -n "$bad" ]; then viol "$f 违规导入: $bad"; fi
done

echo "arch · UI 不得直连外部能力"
for f in $(find Sources/UI -name "*.swift" 2>/dev/null); do
  bad=$(grep -E "^import (ScreenCaptureKit|Vision)" "$f" | tr '\n' ' ')
  if [ -n "$bad" ]; then viol "$f 违规导入: $bad（应走 Core/Ports）"; fi
done

if [ "$fail" -ne 0 ]; then
  echo "arch · 失败：依赖方向被破坏（详见上）"
  exit 1
fi
echo "arch · ✓ Core $(find Sources/Core -name '*.swift' | wc -l | tr -d ' ') 个文件纯净，UI 未直连外部能力"
