#!/bin/bash
# 发版：构建 arm64 DMG → EdDSA 签名 → 生成 appcast.xml → 打印上传步骤。
#
#   bash scripts/release.sh 0.2.0
#
# 为什么是一条脚本而不是手敲五步：发版最容易错的三种事——忘了签名 / 版本号没涨 /
# appcast 指向旧包——**都不会当场报错**，而是等到用户点「检查更新…」才炸，
# 那时已经没人记得细节了。所以这里把口径写死：
#   · 版本号必须显式传（不猜）
#   · 构建号自动用时间戳（单调递增，Sparkle 就靠它比大小）
#   · 签名与 appcast 字段全部由命令量出来（不手写 XML、不用 generate_appcast）
#
# ⚠️ 两个已实锤的坑（来自 glance 的病例，这里是同一套）：
#   ① `generate_appcast` 会在缺公钥/判断"不该签"时**静默**生成没有 edSignature 的
#      appcast（退出码 0）⇒ 更新永远"已是最新"。所以改成 sign_update + 自己写 XML。
#   ② `sign_update` 的输出**已经含 length**，自己再加就是重复属性 = 非法 XML。
set -euo pipefail

cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "用法：bash scripts/release.sh <版本号，如 0.2.0>"; exit 1; }
VERSION="$1"
TAG="v$VERSION"
PROJECT="Snapcut.xcodeproj"
REPO="cheney12138/snapcut"

# Sparkle 官方工具（sign_update）。默认放缓存目录，不进仓库。
TOOLS="${SPARKLE_TOOLS:-$HOME/Library/Caches/snapcut-sparkle}"
SPARKLE_VERSION="2.10.0"
KEY_ACCOUNT="snapcut"     # 钥匙串里 EdDSA 私钥的 account（generate_keys --account snapcut）

echo "== 0/4 架构守卫（键没人读 / 模块越界一律不许发出）"
./scripts/check-architecture.sh

echo "== 0/4 准备 Sparkle 工具"
if [ ! -x "$TOOLS/bin/sign_update" ]; then
  mkdir -p "$TOOLS"
  echo "   下载 Sparkle $SPARKLE_VERSION 工具到 $TOOLS"
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar xJ -C "$TOOLS"
fi

echo "== 1/4 写版本号 + 构建号"
# 版本号真源 = project.yml（xcodegen 由它生成 Resources/Info.plist 与 pbxproj 设置）。
# 只改一处、改完断言 —— 别信"应该写进去了"。
BUILD=$(date +%Y%m%d%H%M)
sed -i '' "s/MARKETING_VERSION: \"[0-9.]*\"/MARKETING_VERSION: \"$VERSION\"/g" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \"[0-9]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/g" project.yml
sed -i '' "s/CFBundleShortVersionString: \"[0-9.]*\"/CFBundleShortVersionString: \"$VERSION\"/g" project.yml
grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml || { echo "✗ 版本号没写进 project.yml，中止"; exit 1; }
grep -q "CFBundleShortVersionString: \"$VERSION\"" project.yml || { echo "✗ Info 版本号没写进 project.yml，中止"; exit 1; }
xcodegen generate >/dev/null
grep -q "<string>$VERSION</string>" Resources/Info.plist || { echo "✗ 生成的 Info.plist 版本号不对，中止"; exit 1; }
echo "   版本 $VERSION / 构建 $BUILD"

echo "== 2/4 构建 DMG"
bash scripts/make-dmg.sh "$HOME/Desktop" "$VERSION" | tail -4

DMG="$HOME/Desktop/Snapcut-$VERSION.dmg"
[ -f "$DMG" ] || { echo "✗ 没有产物 $DMG"; exit 1; }

echo "== 3/4 EdDSA 签名 + 生成 appcast"
if [ -n "${SNAPCUT_ED_KEY:-}" ]; then
  SIG_ARGS=(--ed-key-file "$SNAPCUT_ED_KEY")     # CI/多机：私钥文件
else
  SIG_ARGS=(--account "$KEY_ACCOUNT")            # 本机：登录钥匙串（首次会弹一次"始终允许"）
fi
SIG=$("$TOOLS/bin/sign_update" "$DMG" "${SIG_ARGS[@]}")
echo "   签名：$SIG"

# 最低系统版本直接从 project.yml 读 —— 不要现去 xcodebuild 问一遍：那条命令一旦失败，
# $() 退化成空串，拼出来的路径就成了 "/Snapcut.app/..."，PlistBuddy 会**真的在根目录
# 创建**这个空壳再报"文件不存在"（glance 踩过两次）。
MIN_SYS=$(grep -m1 'macOS:' project.yml | sed 's/.*macOS: *"\{0,1\}\([0-9.]*\)"\{0,1\}/\1/')
[ -n "$MIN_SYS" ] || MIN_SYS="15.0"
python3 - "$VERSION" "$BUILD" "$MIN_SYS" "$TAG" "$DMG" "$SIG" "$REPO" <<'PYX'
import sys, os, datetime
version, build, min_sys, tag, dmg, sig, repo = sys.argv[1:8]
size = os.path.getsize(dmg)
url = f"https://github.com/{repo}/releases/download/{tag}/{os.path.basename(dmg)}"
pub = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
xml = f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Snapcut</title>
    <item>
      <title>{version}</title>
      <pubDate>{pub}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_sys}</sparkle:minimumSystemVersion>
      <enclosure url="{url}" {sig.strip()} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
"""
open(os.path.expanduser("~/Desktop/appcast.xml"), "w").write(xml)
print(f"   appcast：{url}")
print(f"   包体积 {size} 字节 / 签名 {len(sig.strip())} 字符（已含 edSignature 与 length）")
PYX

echo "== 4/4 上传（gh 没装就照下面手点）"
cat <<EOF

  产物：
    $HOME/Desktop/Snapcut-$VERSION.dmg
    $HOME/Desktop/appcast.xml

  装了 gh 的话两条命令就够：
    gh release create $TAG "$HOME/Desktop/Snapcut-$VERSION.dmg" "$HOME/Desktop/appcast.xml" \\
      --repo $REPO --title "Snapcut $VERSION" --notes "…"

  没装 gh：到 https://github.com/$REPO/releases/new 新建 ${TAG}，
  把**两个文件都**传上去当资产 —— appcast.xml 必须挂在**最新**那一版上，
  因为 app 里的 SUFeedURL 指向 releases/latest/download/appcast.xml，少传它更新就断。

  自查三行（发完再验，别信"应该没问题"）：
    curl -sL https://github.com/$REPO/releases/latest/download/appcast.xml | grep -c edSignature   # 必须是 1
    curl -sIL https://github.com/$REPO/releases/latest/download/appcast.xml | head -1              # 200
    /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" build/Snapcut.app/Contents/Info.plist | tr -d '\n' | wc -c  # 44

  ⚠️ 发版说明**只写 3 条以内、用户能感知的变化**；完整改动交给 compare 链接：
     https://github.com/$REPO/compare/v上版本...$TAG
  发完之后把 project.yml / Resources/Info.plist 的版本改动提交（否则下次发版从旧号继续涨）。
EOF
