# 发版与自动更新（Sparkle 2）

> 谁要发版，只看这一页就够。命令两条：`bash scripts/release.sh <版本号>` → 上传两个文件。

## 一、一句话架构

```
scripts/release.sh 0.2.0
   ├─ 架构守卫（scripts/check-architecture.sh）
   ├─ 写版本号进 project.yml（唯一真源）→ xcodegen generate
   ├─ scripts/make-dmg.sh  → Release(arm64) 构建 + 本地证书重签名 + DMG
   ├─ sign_update（EdDSA 私钥在钥匙串 account=snapcut）→ 签名
   └─ 自己写 appcast.xml（版本/构建号/最低系统/URL 全部命令量出来）
        ↓
   传 DMG + appcast.xml 到 GitHub Releases（最新那一版）
        ↓
   App 内 SPUUpdater 读
   https://github.com/cheney12138/snapcut/releases/latest/download/appcast.xml
```

- **更新源**：仓库里 `SUFeedURL` 写死 `releases/latest/download/appcast.xml`。
  「latest」是 GitHub 的指针 ⇒ **每次发版只需把两个资产挂到最新 release 上，URL 永不改**。
- **可信性**：EdDSA（Ed25519）签名，公钥在 `Info.plist` 的 `SUPublicEDKey`，
  私钥在本机钥匙串。**不需要 $99 开发者账号**，安全性不依赖 Apple。
- **端口**：UI 只认 `AppUpdating`（`Sources/Core/Ports/Ports.swift`），
  Sparkle 只出现在 `Sources/Adapters/Update/SparkleUpdater.swift`。
  入口三处：菜单栏「检查更新…」、⌥⌘H 兜底菜单、设置 ▸ 关于 ▸ 检查更新…。

## 二、发版四步（实跑过）

```bash
cd ~/work/screenshot/snapcut
git status                                   # 1. 工作区干净再发（别把半成品打进包）
bash scripts/release.sh 0.2.0                # 2. 出包 + 签名 + 生成 appcast（产物在 ~/Desktop）
gh release create v0.2.0 ~/Desktop/Snapcut-0.2.0.dmg ~/Desktop/appcast.xml \
  --title "Snapcut 0.2.0" --notes "…"        # 3. 发布（两个文件都要，appcast 必须挂在最新版）
git commit -am "发版 0.2.0" && git push      # 4. 版本号那两处改动要提交，否则下次从旧号涨
```

**发版说明只写 3 条以内、用户能感知的变化**；完整改动交给 compare 链接：
`https://github.com/cheney12138/snapcut/compare/v上一版...v0.2.0`

发完自查三行（别信"应该没问题"）：

```bash
curl -sL https://github.com/cheney12138/snapcut/releases/latest/download/appcast.xml | grep -c edSignature  # 必须是 1
curl -sIL https://github.com/cheney12138/snapcut/releases/latest/download/appcast.xml | head -1             # 200
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" build/Snapcut.app/Contents/Info.plist | tr -d '\n' | wc -c # 44
```

## 三、版本号口径

| 位置 | 谁写 | 说明 |
|---|---|---|
| `project.yml` → `MARKETING_VERSION` | 手工（release.sh 改） | 人类看的版本，如 `0.2.0` |
| `project.yml` → `CFBundleShortVersionString` | 同上 | 进 Info.plist 的那个 |
| `project.yml` → `CURRENT_PROJECT_VERSION` | **release.sh 自动**（`date +%Y%m%d%H%M`） | Sparkle 比大小的**构建号**，必须单调递增；用时间戳杜绝"忘了涨" |

⚠️ **不要**用 PlistBuddy 去写某个局部 Info.plist —— `Resources/Info.plist` 是
`xcodegen` 从 `project.yml` 生成的，手改会被下次 `xcodegen generate` 抹掉。
（glance 的病例：PlistBuddy 报错被 `|| true` 吞掉，结果包永远叫旧版本名。）

## 四、为什么要签名（Sparkle 的两道校验）

1. **EdDSA 签名**（`sparkle:edSignature`）：证明这个 DMG 是我们发的。缺它 Sparkle
   **静默忽略**该 item —— 用户点检查更新永远说"已是最新"，且沿 appcast 一路查都看不出问题。
   所以脚本**不用** `generate_appcast`（它会在缺公钥时静默生成无签名的 XML），
   而是显式 `sign_update` + 自己拼 XML。
2. **代码签名一致性**：Sparkle 会比对**新旧 App 的代码签名身份**，不一致直接拒绝安装。
   因此 DMG 里的 app 必须用与开发构建**同一把**本地证书
   （`Snapcut Local Dev`，`38E79C98…`）重签名 —— `make-dmg.sh` 里做了，且签完 `--verify` 断言。

## 五、首次安装的摩擦（不买公证的代价）

未公证 ⇒ 从浏览器下载的 DMG 带 quarantine，首次打开会被系统拦两次
（「未打开」弹窗 → 系统设置 ▸ 隐私与安全性 ▸ 「仍要打开」）。
**痛只有一次**：Sparkle 自己下载的更新不会被隔离。
与 glance 同一决策（见 glance `docs/adr/0010-distribution-accepts-one-manual-first-launch.md`），
不追求"陌生用户零摩擦安装"。

## 六、密钥管理

```bash
# 查看公钥（私钥不动，已发布的 appcast 不用重签）
~/Library/Caches/snapcut-sparkle/bin/generate_keys -p --account snapcut
```

- 首次生成（已完成，2026-11-22）：`generate_keys --account snapcut`
  → 公钥 `HPUWkxnBC8OSpRsBmjfnRLPgRrcswiAJvHEzOguw9oQ=` 写进 `project.yml` 的 `SUPublicEDKey`。
- 换机器/CI：`generate_keys -x <file>` 导出私钥 → 目标机 `-f <file>` 导入；
  或发版时用 `SNAPCUT_ED_KEY=<私钥文件> bash scripts/release.sh …` 走 `--ed-key-file`。
- **私钥丢了不是灾难**：重新生成一对 → 换 `SUPublicEDKey` → 发一版需要**手动安装**的包，
  之后新包就能继续自动更新（老版本客户端会因公钥不匹配而拒绝，必须手动装一次）。

## 七、排查（症状 → 查什么）

| 症状 | 先查 |
|---|---|
| 点「检查更新」永远"已是最新" | `grep edSignature ~/Desktop/appcast.xml`（缺签名 = 该 item 被忽略） |
| 手动检查报错 404 | `curl -sIL …/releases/latest/download/appcast.xml`；appcast 是否挂在**最新**那一版 |
| 更新下载完装不上 | 新旧包签名身份是否一致：`codesign -dv --verbose=2 <app>` 两边比 |
| App 启动就弹窗说更新器不可用 | `SUPublicEDKey` 必须 44 字符 base64（43 字符解不出 32 字节） |
| 后台发现新版本但不弹 | 后台 App 必须实现 gentle reminders（`GentleReminderDelegate`），否则 Sparkle 判定"用户不会注意到" |

日志在 Console：`process == "Snapcut"` 里搜 `(Sparkle)`。我们自己埋的事件：
`update.check` / `update.autoChecks` / `update.scheduled` / `update.willShow` / `update.sessionFinished`。

## 八、本地端到端验证（想确认整条链路没断时）

真实链路 = **装旧版 → 点检查更新 → 它把自己换成新版**。步骤：

1. 临时把 `project.yml` 版本改成旧号（如 `0.1.9`）→ `make dev` → `./scripts/restart.sh`
2. 收藏 → 点「检查更新…」→ 应出现 Sparkle 的更新窗口，显示新版本与 Release notes
3. 安装后 App 自动重启，版本号变新 ⇒ 签名校验、下载、替换、重启全通

（2026-11-22 首次接通时就是这样验的；只看到"网络错误/404"= 还没发第一版，不是接线问题。）
