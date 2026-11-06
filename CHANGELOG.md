# Changelog

遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.1.0] — 2026-11-06

### 新增

- 注册模型工具 `screen_sight`：一次调用读回前台应用、窗口标题、焦点控件（角色/名字/文本）与其他窗口标题。
- 常驻守护进程 `runtime/daemon.ps1`：UI Automation + Win32，行式 JSON 协议，默认 `127.0.0.1:8791`，端口被占用时自动后移。
- 按 token 预算裁剪摘要（`budget` 25 / 60 / 220），默认 220。
- 隐私保护：密码框值替换为 `[password]`，密码管理器类应用整条摘要塌缩为 `[blocked]`。
- 插件只在没有现成守护进程时拉起新实例，可与 `dsh-screen-sense` 共用同一个进程。
