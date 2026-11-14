SHELL := /bin/bash
BUNDLE := build/Snapcut.app

.PHONY: gen dev run tail clean

## 生成 Xcode 工程（project.yml -> Snapcut.xcodeproj，工程不入 git）
gen:
	xcodegen generate

## Debug 构建（ad-hoc 签名，产物拷贝到 build/Snapcut.app）
dev: gen
	rm -rf $(BUNDLE)
	xcodebuild -project Snapcut.xcodeproj -scheme Snapcut -configuration Debug \
		-derivedDataPath build/DerivedData \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build 2>&1 | tail -30
	rsync -a --delete "build/DerivedData/Build/Products/Debug/Snapcut.app/" "$(BUNDLE)/"
	@echo "== $(BUNDLE) ready =="

## 终端直跑二进制（stdout/stderr 直观日志）
run: dev
	$(BUNDLE)/Contents/MacOS/Snapcut

## 实时日志流（unified logging）
tail:
	log stream --level debug --predicate 'subsystem == "app.snapcut"'

clean:
	rm -rf build
