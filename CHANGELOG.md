# Changelog

遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.2.0] — 2026-11-16

这一版是「按需采集」重写：守护进程平时几乎不做事，被调用才看一眼。

### 变更（行为语义）

- **常驻循环不再每 250ms 做一次全量 UIA 扫窗**。现在只有两件事：`Socket.Poll(100ms)` 等请求，加一条 Win32 级的窗口变更流。UIA 只在 `digest` 这类真的要看的时候读一次。
- **`events` 降级为窗口级**（`granularity: "window"`）：记的是「哪个程序、哪个标题、什么时候换的」，不再保证控件级细节。有人调用 `events` 后 120 秒内以 1s 轮询，其余时间退到 5s。
- 焦点元素是窗口/文档这一层、或没有名字也没有值的容器时，**折叠不再输出**（以前会和 `win` 行重复）。
- 窗口列表改用 `EnumWindows`（过滤不可见窗和工具窗），不再走 UIA。
- `digest` **默认不读控件文本**；要读得显式 `values: true`，工具侧对应参数 `include_text`。
- `captures` 默认**只报数不删**；删除必须显式 `prune: true`（`keep` 默认 20）。

### 修复

- `screen` 报「找不到类型 System.Windows.Forms.SystemInformation」：改用 `GetSystemMetrics`，彻底不依赖 WinForms。
- **隐私顺序**：先判断是不是密码管理器再碰 UIA；`IsPassword` 作为读值前的第一道闸，抛异常一律按密文处理。黑名单补到 10 个。
- `pages` 连不上 CDP 时原来空等 2.1 秒：先 150ms 探端口，不通直接返回提示。
- `ping`/`info` 的版本号不再写死，由插件从 `package.json` 传入；新增 `sha256`、`pid`、`started`。
- 端口文件不再影响启动：插件侧改为扫描端口并用 **脚本 sha256** 认亲和，认不出的旧 daemon 会先请它退场（治「装的是新的、跑的是旧的」）。
- 插件侧启动失败改为**指数退避**（1→2→4→…→60s，成功即清零），不再每次调用都等满超时；就绪判定改成 ping 握手，冷装 10s / 热启 4s。
- 连接设 `ReceiveTimeout`，半开连接不会让 daemon 卡死在 `Read` 上。
- 启动时设 PerMonitorV2 DPI 感知，125%/150% 缩放下坐标不再偏。

### 实测（本机 Win11 / PowerShell 5.1）

| 项目 | 0.1.3 | 0.2.0 |
|---|---|---|
| 空转 CPU（30s 待机，单核百分比） | 13.4% | **0.47%** |
| 内存 | 125 MB | 107 MB |
| `digest` 热调用 | 32–284 ms | **11–16 ms** |
| `digest` 冷启动（首次加载 UIA） | — | 383 ms |
| 一段摘要的 token | 164 | 119 |

优化过程（留档，免得下次又绕一遍）：把 250ms 全量 UIA 轮询拆成 Win32 + 按需之后仍有 5%；热循环里三处 `Get-Date`（cmdlet，每次 1~2ms）换成 `[DateTime]::UtcNow` 后降到 0.47%。

### 已知限制

- `events` 只有窗口级。控件级变更流要做 `SetWinEventHook` + `MsgWaitForMultipleObjects`，PowerShell 里写消息泵不划算，留给下一步。
- 首次 `digest` 有约 0.4s 的 UIA 程序集冷加载；`digest` 返回里带 `cold: true`，模型不会误判成坏了。
- 脚本文件必须是 **UTF-8 with BOM**：PowerShell 5.1 按 ANSI 读无 BOM 的中文注释会串字节、把引号吃掉（0.2.0 开发时踩过）。

## [0.1.3] — 2026-11-06

### 新增

- **`info` 诊断操作**：一次请求就能看到版本号、当前端口、脚本根目录（长度）、截图目录是否存在。排查「装了却用不了」时不用再猜。

### 修复

- **`captures` 清空截图时报 `无法将参数绑定到参数"Path"，因为该参数为空字符串`**：代码里 `$dir` 本身是对的，问题是常驻守护进程跑的还是旧进程、没加载到新代码。重启守护进程后恢复（实测返回 `{"ok":true,"removed":1}`）。
- **`ping` 返回的版本号与包版本对齐**：之前一直报 `0.2.0`，容易让人以为装错。

### 实测

- `info`：`root_len` 90，`captures_ok` true
- `captures` 清空：正常返回 `removed`
- `region` 200×100：66 ms，约 27 token

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
