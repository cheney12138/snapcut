#!/bin/bash
# Snapcut 启动脚本 —— 优雅重启（坑 30/31 的标准动作，见 AGENTS.md「进程生命周期纪律」）
#
# 用法：
#   ./scripts/restart.sh          # 优雅重启（默认）
#   ./scripts/restart.sh --build  # 先 make dev 再重启
#   ./scripts/restart.sh --status # 只查状态不动作
#
# 纪律（两次实锤的 bundle id 记死病例）：
#   ❌ 永远不要 pkill -9 -x Snapcut —— kill -9 风暴会把 LS/TCC/CC 的
#      per-app 状态写坏（dev.snapcut.app 和 dev.snapcut.app2 相继中招）
#   ✅ 优雅退出：osascript quit（走 applicationWillTerminate 正常清理）
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="app.snapcut.macos"
BUNDLE="build/Snapcut.app"

status() {
    if pid=$(pgrep -x Snapcut 2>/dev/null); then
        echo "● Snapcut 运行中 (pid $pid)"
    else
        echo "○ Snapcut 未运行"
    fi
}

quit_gracefully() {
    if pgrep -x Snapcut >/dev/null 2>&1; then
        echo "→ 退出旧实例（SIGTERM；坑 33 拦截 osascript quit 后的退出路径）..."
        # 坑 33 的 terminate 拦截会拦掉 Apple event quit；SIGTERM 直达（干净走
        # applicationWillTerminate），且绝非 -9
        kill $(pgrep -x Snapcut) 2>/dev/null || true
        # 等它退干净（最多 5s，不带 -9）
        for _ in $(seq 1 20); do
            pgrep -x Snapcut >/dev/null 2>&1 || break
            sleep 0.25
        done
        if pgrep -x Snapcut >/dev/null 2>&1; then
            echo "⚠ 实例未在 5s 内退出（可能弹了确认框），跳过重启" >&2
            exit 1
        fi
    fi
}

case "${1:-}" in
    --status)
        status
        exit 0
        ;;
    --build)
        make dev
        ;;
esac

quit_gracefully
echo "→ 启动 $BUNDLE..."
# ⚠️ 不用 open（坑 33）：LaunchServices 对同一 bundle id 记录了多个路径副本
# （xcodebuild 注册 DerivedData 产物 + rsync 拷贝的 build/Snapcut.app），
# open 可能解析到 DerivedData 原始路径——tccd 按 binary_path 判定身份，
# 两个路径=授权记录对不上=「授权了还说未授权」。直接执行二进制，
# 启动的永远是本路径副本。
# 直接执行二进制会退出（SwiftUI+LSUIElement 需要 LS 启动，坑 31 结论）；
# open 传绝对路径而非让 LS 按 bundle id 解析（避免跳 DerivedData 副本）
open -n "$(pwd)/$BUNDLE"
sleep 2
status
