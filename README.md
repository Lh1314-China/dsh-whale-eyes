# dsh-whale-eyes · 鲸鱼的眼睛

给 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的模型一双**不截屏**的眼睛：注册一个 `screen_sight` 工具，一次调用读回当前屏幕的短摘要。

> A screen-sense tool for DeepSeek Harness: foreground app, window title, focused control and open windows as a short summary — **no screenshots, no uploads**. Windows only.

```
app: DeepSeek Harness
win: DSH插件：低token实现屏幕视觉 — DeepSeek Harness
focus: Document "DSH插件：低token实现屏幕视觉 — DeepSeek Harness" = dsh-app://app/
wins: 中转站 | GitHub | 本地磁盘 (D:) - 文件资源管理器 | SakuraCat
```

一次调用约 **55～75 token**，纯文本；不调用就没有额外开销。

## 为什么不用截图

| | 截图方案 | 本插件 |
|---|---|---|
| 隐私 | 画面整张离开本机 | 只读结构化文本，密码框 `[password]`、密码管理器 `[blocked]` |
| 成本 | 320×240 约 100 token，整屏约 660 token | 55～75 token，还能再往下压 |
| 速度 | 渲染 + 缩放 + 编码 | 一次本地 TCP 往返，10～30 ms |
| 信息 | 像素，需要模型自己看 | 已经是「在哪个应用、哪个控件」 |

## 安装

三种方式，任选其一。装完重启后自动生效，`screen_sight` 会出现在模型可用的工具里。

**1. GitHub（推荐）**

插件管理页 → 添加插件 → 填仓库地址：

```
https://github.com/Lh1314-China/dsh-whale-eyes
```

或者命令行：

```powershell
dsh plugin --profile desktop add github:Lh1314-China/dsh-whale-eyes
```

**2. npm（发布之后）**

```
dsh-whale-eyes
```

**3. 本地目录**

```
C:\path\to\dsh-whale-eyes
```

## 用法

模型侧只有一个工具：

| 参数 | 类型 | 说明 |
|---|---|---|
| `budget` | integer | 摘要大小。`25` = 应用+标题，`60` = 加焦点控件，`220`（默认）= 再加窗口列表 |

```jsonc
{ "budget": 60 }
```

守护进程按 JSON 估算预算再裁剪，实际渲染出来的纯文本比估算更短。

## 隐私与边界

- **不截屏、不上传、不读剪贴板、不落盘。**
- 密码框（`IsPassword`）的值一律变成 `[password]`。
- 密码管理器一类应用整条摘要塌缩成 `[blocked]`。
- 只在本机 `127.0.0.1` 上通信用，没有出站请求。

## 工作原理

```
DSH 主机进程
  └─ index.js          注册 screen_sight，必要时拉起守护进程
        │  127.0.0.1:8791（行式 JSON）
        ▼
  runtime/daemon.ps1   常驻，250 ms 轮询
        ├─ UI Automation  焦点控件、窗口树
        ├─ Win32          前台窗口、窗口类、进程名
        └─ runtime/lib.ps1 隐私过滤 + 预算裁剪
```

插件**只在没有现成实例时**才拉起守护进程；端口从 `8791` 起找，被占用就往后挪（最多 +9），实际端口写进 `runtime/port.txt`。

如果机器上已经有 `dsh-screen-sense` 在跑同样的守护进程，本插件会直接接上去，不会起第二个轮询器。

## 目录结构

| 路径 | 作用 |
|---|---|
| `index.js` | 主机插件壳：工具注册 + 守护进程生命周期 |
| `runtime/daemon.ps1` | 守护进程，行式 JSON 协议 |
| `runtime/lib.ps1` | 摘要压缩、隐私过滤、应用名归一 |
| `runtime/cdp.ps1` | 可选的浏览器标签页读取（DevTools HTTP，同样不截屏） |
| `cordis.patch.yml` | 插入一行 `whale-eyes` 插件，配置端口与默认预算 |
| `locale/*.json` | 插件列表里的标题与描述 |
| `icon.svg` | 插件图标 |

## 调试

手动起一个守护进程，自己发请求看看：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\runtime\daemon.ps1 -Port 8801

# 另一个窗口
$c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', 8801)
$s = $c.GetStream(); $w = New-Object IO.StreamWriter($s); $w.AutoFlush = $true
$w.WriteLine('{"op":"digest","budget":220}')
(New-Object IO.StreamReader($s)).ReadLine()
```

可用 op：`ping`、`digest`、`events`、`pages`、`region`、`captures`、`stop`。默认路径永远不碰 `region`（那是唯一会截图的 op）。

## 已知限制

- **仅 Windows**：依赖 UI Automation 与 Win32。
- Electron / Chromium 应用在 UI Automation 里常常只暴露窗口层，需要 CDP 补齐（浏览器要开 `--remote-debugging-port`）。
- 中文标题会被按字符截断，`…` 是截断标记，不是原文。

## 许可

[MIT](LICENSE) © 2026 小鲸 & 凌寒
