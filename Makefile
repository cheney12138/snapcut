SHELL := /bin/bash
BUNDLE := build/Snapcut.app
# 稳定开发签名身份（TCC 授权随签名走：身份固定 ⇒ 屏幕录制授权不会每次构建后重置弹窗）
SIGN_ID := "Apple Development: 18600607249@163.com (7KDMYNHX76)"

.PHONY: gen dev run tail clean

## 生成 Xcode 工程（project.yml -> Snapcut.xcodeproj，工程不入 git）
gen:
	xcodegen generate

## Debug 构建（固定开发证书签名，产物拷贝到 build/Snapcut.app）
dev: gen
	rm -rf $(BUNDLE)
	xcodebuild -project Snapcut.xcodeproj -scheme Snapcut -configuration Debug \
		-derivedDataPath build/DerivedData \
		CODE_SIGN_IDENTITY=$(SIGN_ID) \
		DEVELOPMENT_TEAM= PKGINFO_PATH= build 2>&1 | tee /tmp/snapcut_build.log | tail -20
	@grep -q "BUILD SUCCEEDED" /tmp/snapcut_build.log || { echo "BUILD FAILED, bundle not updated"; exit 1; }
	rsync -a --delete "build/DerivedData/Build/Products/Debug/Snapcut.app/" "$(BUNDLE)/"
	@echo "== $(BUNDLE) ready =="

## 终端直跑（实时 stderr 日志）
run: dev
	$(BUNDLE)/Contents/MacOS/Snapcut

## 实时日志流（unified logging）
tail:
	log stream --level debug --predicate 'subsystem == "app.snapcut"'

clean:
	rm -rf build
