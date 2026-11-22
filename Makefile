SHELL := /bin/bash
BUNDLE := build/Snapcut.app
# 稳定开发签名身份（TCC 授权随签名走：身份固定 ⇒ 屏幕录制授权不会每次构建后重置弹窗）
SIGN_ID := "Apple Development: 18600607249@163.com (7KDMYNHX76)"
# 钥匙串里的 Snapcut Local Dev 证书（TCC 授权锚定它，跨构建稳定）
LOCAL_SIGN_ID := 38E79C988C72B625EFCC85754C65E1F0ED62D0D7

.PHONY: gen dev run tail clean release dmg

## 生成 Xcode 工程（project.yml -> Snapcut.xcodeproj，工程不入 git）
# 六边形架构守卫（依赖方向只能向内；破坏即失败，防止 Core 被 AppKit 污染）
check-arch:
	@./scripts/check-architecture.sh

gen:
	xcodegen generate

## Debug 构建（固定开发证书签名，产物拷贝到 build/Snapcut.app）
dev: gen check-arch
	# ⚠️ 不删重 bundle（rm -rf 换 inode + 重签名反复注册会把 LS 的 bundle ID
	# 记录搞脏 → 状态栏图标消失，换过两次 ID 的病例）；原地 rsync 更新
	xcodebuild -project Snapcut.xcodeproj -scheme Snapcut -configuration Debug \
		-derivedDataPath build/DerivedData \
		CODE_SIGN_IDENTITY=$(SIGN_ID) \
		DEVELOPMENT_TEAM= PKGINFO_PATH= build 2>&1 | tee /tmp/snapcut_build.log | tail -20
	@grep -q "BUILD SUCCEEDED" /tmp/snapcut_build.log || { echo "BUILD FAILED, bundle not updated"; exit 1; }
	rsync -a --delete "build/DerivedData/Build/Products/Debug/Snapcut.app/" "$(BUNDLE)/"
	# 收尾签名：固定本地证书（TCC 授权锚定 requirement 而非 cdhash——
	# Snow Shot 安装器同款机制，授权一次跨构建长期有效）
	codesign --force --identifier app.snapcut.snapcut --sign "$(LOCAL_SIGN_ID)" "$(BUNDLE)"
	@echo "== $(BUNDLE) ready =="

## 终端直跑（实时 stderr 日志）
run: dev
	$(BUNDLE)/Contents/MacOS/Snapcut

## 实时日志流（unified logging）
tail:
	log stream --level debug --predicate 'subsystem == "app.snapcut"'

## 发版：make release VERSION=0.2.0（出包 + EdDSA 签名 + appcast，见 docs/08-release-and-autoupdate.md）
release:
	@[ -n "$(VERSION)" ] || { echo "用法：make release VERSION=0.2.0"; exit 1; }
	@bash scripts/release.sh "$(VERSION)"

## 只出 DMG（不签名、不写 appcast；调试打包布局用）
dmg:
	@bash scripts/make-dmg.sh

clean:
	rm -rf build
