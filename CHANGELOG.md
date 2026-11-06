# Changelog

遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.1.2] — 2026-11-06

### 修复

- **守护进程起不来的真正原因**：`spawn` 用了 `detached: true`，在本环境里分离出来的子进程会立刻以 `exit=0` 退出、完全不执行脚本。对照实验：detached 的三种流配置全部失败，去掉 detached 后立刻绑上端口。
- 现在子进程跟随主机进程生命周期，不再分离。

### 说明

`0.1.1` 的兜底路径实测有效：守护进程起不来时，工具仍能在约 1.1 秒内返回摘要。`0.1.2` 让快路径（常驻守护进程，10～30 ms）也恢复正常。

## [0.1.1] — 2026-11-06

### 修复

- 守护进程拉不起来时工具直接报 12 秒超时：`spawn` 失败（解释器找不到、被安全软件拦下）不会抛异常，只发 `error` 事件，之前没监听。现在会捕获并在报错里说明原因。
- 新增一次性兜底模式 `daemon.ps1 -Once`：守护进程起不来或半路死掉时，改为单次采集（约 1.1 秒），不会再整条链路失明。
- PowerShell 解释器改为按 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` 绝对路径查找，避免主机进程 PATH 不包含它。
- 守护进程的 stdout/stderr 写入 `runtime/daemon.log`，启动失败时把日志尾巴带进报错。

## [0.1.0] — 2026-11-06

### 新增

- 注册模型工具 `screen_sight`：一次调用读回前台应用、窗口标题、焦点控件（角色/名字/文本）与其他窗口标题。
- 常驻守护进程 `runtime/daemon.ps1`：UI Automation + Win32，行式 JSON 协议，默认 `127.0.0.1:8791`，端口被占用时自动后移。
- 按 token 预算裁剪摘要（`budget` 25 / 60 / 220），默认 220。
- 隐私保护：密码框值替换为 `[password]`，密码管理器类应用整条摘要塌缩为 `[blocked]`。
- 插件只在没有现成守护进程时拉起新实例，可与 `dsh-screen-sense` 共用同一个进程。
