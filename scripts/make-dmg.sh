#!/bin/bash
# 出正式 DMG（Release 构建 + 标准布局：Snapcut.app + /Applications 软链）。
#
#   bash scripts/make-dmg.sh              # 产物到 ~/Desktop/Snapcut-<版本>.dmg
#   bash scripts/make-dmg.sh /tmp/out     # 指定输出目录
#   bash scripts/make-dmg.sh /tmp/out 0.2.0   # 指定输出目录 + 断言版本号
#
# 为什么用脚本而不是手敲：DMG 里那份 app 必须与我们**已授权/已签名的身份同源** ——
# 每 build 都要重新 Release 构建、从 xcodebuild 的输出目录取产物（路径带 DerivedData，
# 不能写死），手敲一次就会漏一步，得到"看起来一样但签名/版本不同"的包。
# 而 Sparkle 升级时会比对**新旧包的代码签名身份**：身份不一致直接拒绝安装
# （用户看到的是「更新失败」，没有任何可读原因）。
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-$HOME/Desktop}"
PROJECT="Snapcut.xcodeproj"
SCHEME="Snapcut"
CONFIG="Release"
# 与开发构建同一把本地证书：TCC 授权与 Sparkle 的签名比对都锚定它
LOCAL_SIGN_ID="38E79C988C72B625EFCC85754C65E1F0ED62D0D7"

echo "== 1/4 Release 构建（arm64）"
# ARCHS=arm64：不出 universal（用户机器都是 Apple Silicon）；二进制与 DMG 各小一半
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' ARCHS=arm64 \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="Apple Development: 18600607249@163.com (7KDMYNHX76)" \
  DEVELOPMENT_TEAM= PKGINFO_PATH= build | tail -3

SETTINGS=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' ARCHS=arm64 -derivedDataPath build/DerivedData \
  -showBuildSettings 2>/dev/null)
BUILT_DIR=$(echo "$SETTINGS" | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
PRODUCT=$(echo "$SETTINGS" | awk -F' = ' '/ FULL_PRODUCT_NAME = /{print $2; exit}')
APP="$BUILT_DIR/$PRODUCT"
[ -d "$APP" ] || { echo "找不到产物：$APP"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
# 期望版本（第 2 个参数）：对不上当场报错，不要产出一个名字骗人的包
EXPECT="${2:-}"
if [ -n "$EXPECT" ] && [ "$VERSION" != "$EXPECT" ]; then
  echo "✗ 产物版本（${VERSION}）与期望（${EXPECT}）不一致 —— 打包中止" >&2
  echo "  （最常见原因：版本号没写进 project.yml；release.sh 会先改写它再 xcodegen）" >&2
  exit 1
fi
DMG="$OUT_DIR/Snapcut-$VERSION.dmg"
echo "== 2/4 产物 ${APP}（版本 ${VERSION}）"

echo "== 3/4 重签名（本地证书 + 内嵌 Sparkle.framework）"
# --deep：Sparkle.framework 是内嵌代码，不一起重签会出现「外层签了、内层还是旧/临时签名」，
# Sparkle 更新器校验 fail。签完必须 verify，签坏了当场炸比发出去好。
codesign --force --deep --sign "$LOCAL_SIGN_ID" --identifier app.snapcut.snapcut "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
# 公钥必须是 44 字符 base64（43 字符解不出 32 字节，Sparkle 会在启动阶段直接拒绝启动更新器）。
# wc -c 在 macOS 会补空格，所以要 xargs 收拾干净再比。
KEY_LEN=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" | tr -d '\n' | wc -c | xargs)
[ "$KEY_LEN" = "44" ] || { echo "✗ SUPublicEDKey 长度 ${KEY_LEN}（应为 44，Sparkle 启动阶段会直接失败）"; exit 1; }

echo "== 4/4 组装布局 + 打包"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$PRODUCT"          # ditto 保签名：cp -R 会打散扩展属性
ln -s /Applications "$STAGE/Applications"

mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil create -volname "Snapcut" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo
echo "✅ ${DMG}（$(du -h "$DMG" | cut -f1)）"
echo
echo "装法：打开 DMG，把 Snapcut.app 拖进 Applications。"
echo "注意：① 先退掉正在跑的那份（单实例守卫会让第二份直接退出）；"
echo "      ② 首次安装从浏览器下载会被 quarantine，需要在「系统设置 ▸ 隐私与安全性」放行一次；"
echo "      ③ 之后 Sparkle 自己下载的更新不会被隔离。"
