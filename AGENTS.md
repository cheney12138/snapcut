# 与编码 agent 协作的约定（Snapcut）

本文件给在本仓库里干活的 agent 看。改动它请单独一个提交，并说明为什么。

## 实机纪律：用户在工作时，只写代码不装不跑

（照 Glance AGENTS.md 的纪律，那是同一位用户踩出来的规矩）

- 用户没说"随便打扰 / 你自己测" ⇒ **不要 pkill + open 反复重启 App**、不要注入输入事件、
  不要 `screencapture` 抓屏（亮录屏标识、抢焦点、弹 TCC）。
- 开发 → 构建（`make dev`）→ **交给用户自己验证**。
- 例外：用户明确说"没人用 / 你自己测"才跑自测；跑完恢复现场。

## TCC / 权限纪律

- `CGPreflightScreenCaptureAccess()` 不弹窗，随便查；`CGRequestScreenCaptureAccess()`
  会弹系统授权框 —— **只在用户主动走引导流程时调**（托盘菜单 / 截图被拒引导）。
  （Glance 2026-09-19 病例：「怎么老是弹录屏授权」）
- 构建签名必须用**固定开发证书**（Makefile 里的 SIGN_ID），不能用 ad-hoc：
  ad-hoc 每次构建 cdhash 变 ⇒ TCC 记录失效 ⇒ 用户被反复弹授权窗。
- 换 bundle 路径 / 换签名身份都会让屏幕录制授权重置，验证清单要注明当前签名方式。

## 图标管线纪律

- 状态栏图标用 `IconFactory` 代码绘制（CGPath），**不要**走 qlmanage SVG→PNG 转换
  （2026-11-14 病例：qlmanage 渲染出 100% 不透明纯白 PNG，0 个黑色笔画像素，
  template 渲染下菜单栏完全不可见，排查了一小时）。
- SVG（design/status-icon.svg）只是设计参考，不是构建输入。
- 改图标后验证方式：截图 + 像素簇对比（Tools 里的 cluster 分析思路），或让用户看。

## 分支与提交

- 开发在 feat 分支上；`main` 只进发版。
- 一次提交 = 一个可验证的成果；多轮返工压进同一个提交，提交信息用病例体
  （现象 / 证据 / 为什么 / 否掉了什么）。

## 诊断方法

- 日志：`log stream --predicate 'subsystem == "app.snapcut"'`（或 `make tail`）。
- "没有输出"不是证据：先确认渠道通电（同一份日志里有别的已知输出）。
- 用户说"还是有问题"时，先捞日志/看截图，不要接着猜。
