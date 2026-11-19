<#
  dsh-whale-eyes / runtime daemon — 0.3.0

  设计（0.2.0 重写，2026-11-16）：
  - 常驻循环只做两件便宜事：等 socket（Socket.Poll 100ms）+ Win32 层的窗口变更（500ms 一次，
    全是进程内调用，微秒级）。不再每 250ms 做一次全量 UIA 扫窗。
  - UIA 只在 digest/pages 这类「真的要看」的请求里现场读一次；读的时候只用 FocusedElement
    和前台窗口子树，不再枚举全部顶层窗口。
  - events 降级为「窗口级变更流」（Win32），不保证控件级细节 —— 这是语义变化，见 CHANGELOG。
  - 默认不读 ValuePattern（控件文本）；要读得显式 values=true。
  - 隐私：先判断应用是否在黑名单里，再决定要不要碰 UIA。

  protocol (one JSON per line in, one JSON per line out):
    {"op":"ping"}
    {"op":"info"}
    {"op":"digest","budget":220,"values":false}
    {"op":"events","since":0}
    {"op":"pages","port":9222}
    {"op":"region","x":0,"y":0,"w":800,"h":600,"scale":0.5}
    {"op":"screen","scale":0.5}
    {"op":"captures"}                     # 只报数，不删
    {"op":"captures","prune":true,"keep":20}
    {"op":"stop"}
#>
param(
    [int]$Port = 8791,
    [int]$Budget = 220,
    [string]$Version = "",
    [switch]$Once,
    # 一次性模式也要能要控件文本：以前兜底路径静默忽略 include_text
    [switch]$Values,
    # 本机调用方凭据（插件每次拉起时生成）；空 = 不鉴权（兼容旧调用方）
    [string]$Token = "",
    # 截图默认关：不开这个开关，region/screen 一律拒绝
    [switch]$AllowCapture
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. "$PSScriptRoot\lib.ps1"
. "$PSScriptRoot\cdp.ps1"

if (-not ("WY.Win32" -as [type])) {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace WY {
  public class Win32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    // 窗口列表：连 pid 一起回（pid|title），让上层能按进程名过滤黑名单
    public static string[] ListWindowInfos(int max, string exclude) {
      var list = new System.Collections.Generic.List<string>();
      EnumWindows(delegate(IntPtr h, IntPtr l) {
        if (!IsWindowVisible(h)) return true;
        if ((GetWindowLong(h, -20) & 0x80) != 0) return true;   // WS_EX_TOOLWINDOW: 辅助窗
        var sb = new StringBuilder(512);
        if (GetWindowText(h, sb, 512) <= 0) return true;
        var t = sb.ToString().Trim();
        if (t.Length == 0) return true;
        if (exclude != null && t == exclude) return true;
        uint pid = 0;
        GetWindowThreadProcessId(h, out pid);
        list.Add(pid.ToString() + "|" + t);
        return list.Count < max;
      }, IntPtr.Zero);
      return list.ToArray();
    }
  }
}
"@
}

# 缩放 125%/150% 的机器上坐标会偏；失败就安静地用默认（老系统没有这个 API）。
try { [void][WY.Win32]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

$script:Version = if ($Version) { $Version } else { "0.0.0" }
$script:StartedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$script:ScriptHash = try { (Get-FileHash (Join-Path $PSScriptRoot "daemon.ps1") -Algorithm SHA256).Hash } catch { "" }
$script:Token = $Token
$script:TokenFile = Join-Path $PSScriptRoot "daemon.token"
# 令牌落盘：插件重连/采纳已有的 daemon 时要用；同用户进程可读，属「防误触/防顺手调用」，
# 不是防同用户恶意进程的安全边界（文档里写清楚，别自欺）。
if ($script:Token -and -not $Once) {
    try { Set-Content -Path $script:TokenFile -Value $script:Token -Encoding ASCII -NoNewline } catch { }
}
$script:lastPid = [uint32]0
$script:lastProc = ""
$script:procCache = @{}
$script:firstDigest = $true
$script:sbTitle = New-Object System.Text.StringBuilder 512
$script:sbClass = New-Object System.Text.StringBuilder 256

function Get-ClassOf([IntPtr]$hwnd) {
    [void]$script:sbClass.Clear()
    [void][WY.Win32]::GetClassName($hwnd, $script:sbClass, 256)
    return $script:sbClass.ToString()
}

function Get-ProcNameOf([uint32]$procId) {
    $key = [string]$procId
    if ($script:procCache.ContainsKey($key)) { return $script:procCache[$key] }
    $name = ""
    try { $name = [System.Diagnostics.Process]::GetProcessById([int]$procId).ProcessName } catch { }
    if ($script:procCache.Count -gt 200) { $script:procCache.Clear() }
    $script:procCache[$key] = $name
    return $name
}

function Limit-Text([string]$s, [int]$n) {
    if ($null -eq $s) { return "" }
    $t = ($s -replace '\s+', ' ').Trim()
    if ($t.Length -le $n) { return $t }
    # 别把代理对切成半个字
    $cut = $n - 1
    if ($cut -gt 0 -and [char]::IsHighSurrogate($t[$cut - 1])) { $cut-- }
    return $t.Substring(0, $cut) + "…"
}

# ---- 前台窗口：纯 Win32，进程内，微秒级 ----------------------------------
function Get-WinState {
    $hwnd = [WY.Win32]::GetForegroundWindow()
    $r = New-Object WY.Win32+RECT
    [void][WY.Win32]::GetWindowRect($hwnd, [ref]$r)

    $sb = New-Object System.Text.StringBuilder 512
    [void][WY.Win32]::GetWindowText($hwnd, $sb, 512)
    $title = $sb.ToString()

    $cb = New-Object System.Text.StringBuilder 256
    [void][WY.Win32]::GetClassName($hwnd, $cb, 256)
    $cls = $cb.ToString()

    $procId = [uint32]0
    [void][WY.Win32]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    # 查进程名一次约 17ms（有的机器更贵），缓存住：同一个 pid 不重复查
    if ($procId -eq $script:lastPid -and $script:lastProc) {
        $procName = $script:lastProc
    } else {
        $procName = ""
        try { $procName = [System.Diagnostics.Process]::GetProcessById([int]$procId).ProcessName } catch { }
        $script:lastPid = $procId
        $script:lastProc = $procName
    }

    [ordered]@{
        hwnd  = [int64]$hwnd
        pid   = $procId
        app   = Get-AppFromClass $cls $procName
        cls   = $cls
        title = $title
        rect  = [ordered]@{ l = $r.Left; t = $r.Top; r = $r.Right; b = $r.Bottom }
    }
}

# ---- 焦点控件：UIA，只在请求时调用 ---------------------------------------
function Get-FocusState([bool]$values) {
    try {
        $fe = $AE::FocusedElement
        if (-not $fe) { return $null }

        $hwnd = 0
        try { $hwnd = [int64]$fe.Current.NativeWindowHandle } catch { $hwnd = 0 }

        # 第一道闸：IsPassword（抛异常的 provider 一律按密文处理）
        $isPassword = $true
        try { $isPassword = [bool]$fe.Current.IsPassword } catch { $isPassword = $true }

        # 第二道闸：Win32 编辑框的 ES_PASSWORD 样式。
        # 实测（2026-11-16）：WinForms 密码框的 IsPassword 不生效，而且 UIA 的 Name
        # 里就是明文——只挡 ValuePattern 会从 name 漏出去。
        if (-not $isPassword -and $hwnd -ne 0) {
            try {
                if (([WY.Win32]::GetWindowLong([IntPtr]$hwnd, -16) -band 0x0020) -ne 0) { $isPassword = $true }
            } catch { }
        }

        $role = try { $fe.Current.ControlType.ProgrammaticName -replace '^ControlType\.', '' } catch { "" }

        if ($isPassword) {
            # 名字和值一起遮：密码框的 name 也可能是明文
            return [ordered]@{ role = $role; name = "[password]"; value = "[password]"; hwnd = $hwnd }
        }

        $cls = if ($hwnd -ne 0) { Get-ClassOf ([IntPtr]$hwnd) } else { "" }
        $editLike = ($role -eq "Edit") -or ($cls -match '(?i)(^|\.)edit(\b|\.)')

        # 有些 provider（WinForms TextBox 实测）没有 ValuePattern，UIA 的 Name 就是输入内容本身。
        # 这种控件的 name 属于「文本」，默认不读；要读得显式 values=true。
        $hasValuePattern = $false
        $vtext = ""
        try {
            $vp = $fe.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            if ($vp) {
                $hasValuePattern = $true
                $vtext = [string]$vp.Current.Value
            }
        } catch { $hasValuePattern = $false }

        $fname = try { $fe.Current.Name } catch { "" }
        if ($editLike -and -not $hasValuePattern -and -not $values) { $fname = "" }
        if ($fname -and $fname.Length -gt 40) { $fname = $fname.Substring(0, 40) }

        $fval = ""
        if ($values -and $hasValuePattern -and $vtext) {
            $fval = if ($vtext.Length -gt 60) { $vtext.Substring(0, 60) } else { $vtext }
        }

        [ordered]@{
            role  = $role
            name  = $fname
            value = $fval
            hwnd  = $hwnd
        }
    } catch {
        return $null
    }
}

# ---- 窗口列表：EnumWindows，Win32 就够 -----------------------------------
function Read-Windows([string]$foregroundTitle, [int]$max = 5) {
    $out = New-Object System.Collections.ArrayList
    $seen = New-Object System.Collections.Generic.HashSet[string]
    try {
        $raw = [WY.Win32]::ListWindowInfos(($max + 6), $foregroundTitle)
        foreach ($item in $raw) {
            $sep = $item.IndexOf("|")
            if ($sep -lt 0) { continue }
            $wpid = 0
            if (-not [int]::TryParse($item.Substring(0, $sep), [ref]$wpid)) { continue }
            # 黑名单参与「其它窗口」：后台挂着的密码管理器，标题往往就是账号/库名
            if (Test-AppBlocked (Get-ProcNameOf ([uint32]$wpid))) { continue }
            $short = Limit-Text $item.Substring($sep + 1) 30
            if (-not $short) { continue }
            if ($short -eq (Limit-Text $foregroundTitle 30)) { continue }
            if (-not $seen.Add($short)) { continue }
            [void]$out.Add($short)
            if ($out.Count -ge $max) { break }
        }
    } catch { }
    return @($out)
}

# ---- 摘要 ----------------------------------------------------------------
function Get-Digest([int]$budget, [bool]$values) {
    $fg = Get-WinState
    $app = $fg.app

    # 先判断封禁应用，再决定碰不碰 UIA
    if (Test-AppBlocked $app) {
        $red = Get-RedactedState $app
        $packed = Compress-Digest ([ordered]@{ app = $red.app; title = $red.title; focus = $null; wins = @() }) $budget
        return $packed
    }

    $focus = Get-FocusState $values
    # focus 折叠：只有「它本身就是窗口/文档层」才折；UWP/Electron 给内层控件报顶层 hwnd，
    # 那时候 hwnd 相等不代表没信息（0.2.2 复核 :27）。
    $topRoles = @("Window", "Document", "Pane", "Client", "Group")
    if ($focus -and $focus.hwnd -ne 0 -and $focus.hwnd -eq $fg.hwnd -and $topRoles -contains $focus.role) { $focus = $null }
    if ($focus -and $focus.name -and $focus.name -eq $fg.title -and $topRoles -contains $focus.role) { $focus = $null }
    # 没名字也没值的容器（Pane/Group）说明不了任何事，别占 token
    if ($focus -and -not $focus.name -and -not $focus.value) { $focus = $null }

    $full = [ordered]@{
        app   = $app
        title = Limit-Text $fg.title 64
        focus = $focus
        wins  = Read-Windows $fg.title 5
    }
    return (Compress-Digest $full $budget)
}

# ---- 截图（按需升级，默认永不触发） --------------------------------------
function Get-ScreenRegion {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [double]$Scale = 0.5)
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $bmp = New-Object System.Drawing.Bitmap($W, $H)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($X, $Y, 0, 0, $bmp.Size)
        $g.Dispose()

        $tw = [Math]::Max(1, [int]($W * $Scale))
        $th = [Math]::Max(1, [int]($H * $Scale))
        $small = New-Object System.Drawing.Bitmap($tw, $th)
        $g2 = [System.Drawing.Graphics]::FromImage($small)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.DrawImage($bmp, 0, 0, $tw, $th)
        $g2.Dispose()
        $bmp.Dispose()

        $dir = Join-Path $PSScriptRoot "captures"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $file = Join-Path $dir ("cap_" + [DateTime]::UtcNow.ToString("yyyyMMdd_HHmmss_fff") + ".png")
        $small.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
        $small.Dispose()
        return [pscustomobject]@{ file = $file; w = $tw; h = $th; bytes = (Get-Item $file).Length }
    } catch {
        return $null
    }
}

function Get-CaptureInfo([int]$keep = 0) {
    $dir = Join-Path $PSScriptRoot "captures"
    if (-not (Test-Path $dir)) { return [ordered]@{ dir = $dir; count = 0 } }
    $files = @(Get-ChildItem $dir -Filter *.png -ErrorAction SilentlyContinue)
    [ordered]@{ dir = $dir; count = $files.Count; keep = $(if ($keep -le 0) { $script:CaptureKeep } else { $keep }); newest = if ($files.Count) { ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).Name } else { "" } }
}

# ---- pages：先探端口，探不到就别等 --------------------------------------
function Test-TcpPort([int]$p, [int]$timeoutMs = 150) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ok = $c.ConnectAsync('127.0.0.1', $p).Wait($timeoutMs)
        $c.Close()
        return $ok
    } catch { return $false }
}

# ---- 一次性模式：采一次、打一行 JSON、退出 ------------------------------
if ($Once) {
    try {
        $packed = Get-Digest $Budget $Values.IsPresent
        $resp = [ordered]@{
            ok      = $true
            once    = $true
            version = $script:Version
            sha256  = $script:ScriptHash
            tokens  = $packed.tokens
            budget  = $Budget
            digest  = $packed.data
        }
    } catch {
        $resp = [ordered]@{ ok = $false; error = "$($_.Exception.Message)" }
    }
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    Write-Output ($resp | ConvertTo-Json -Depth 6 -Compress)
    exit 0
}

# ========================= 常驻模式 =========================
$events = New-Object System.Collections.ArrayList
$seq = 0
$lastKey = ""
$lastWinPoll = 0
$boundPort = 0
$listener = $null
$iter = 0
$ready = 0
$lastEventsAsk = 0

for ($p = $Port; $p -lt ($Port + 10); $p++) {
    try {
        $cand = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
        $cand.Server.ExclusiveAddressUse = $true
        $cand.Start()
        $listener = $cand
        $boundPort = $p
        break
    } catch { }
}
if (-not $listener) { Write-Error "端口 $Port ~ $($Port + 9) 都被占用"; exit 1 }

try { Set-Content -Path (Join-Path $PSScriptRoot "port.txt") -Value $boundPort -Encoding ASCII } catch { }

$run = $true
$sock = $listener.Server
while ($run) {
    $iter++
    # epoch 毫秒：DateTime 相减要走引擎的运算符绑定 + 建 TimeSpan 对象，是「Get-Date 之后的第二个地板」
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    # Win32 层变更流：热路径只取一个 key 字符串，变了才建对象（建对象约 10ms，不能每秒都做）
    # 没人订阅 events 时退到 5s：这个 daemon 的常态是「没人看」
    $pollEvery = if (($now - $lastEventsAsk) -lt 120000) { 1000 } else { 5000 }
    if (($now - $lastWinPoll) -ge $pollEvery) {
        $lastWinPoll = $now
        try {
            $hwnd = [WY.Win32]::GetForegroundWindow()
            [void]$script:sbTitle.Clear()
            [void][WY.Win32]::GetWindowText($hwnd, $script:sbTitle, 512)
            $t = $script:sbTitle.ToString()
            $procId = [uint32]0
            [void][WY.Win32]::GetWindowThreadProcessId($hwnd, [ref]$procId)
            $key = "$procId|$t|$hwnd"
            if ($key -ne $lastKey) {
                $seq++
                [void]$events.Add([ordered]@{
                    seq   = $seq
                    ts    = [int]([datetimeoffset]::UtcNow.ToUnixTimeSeconds())
                    app   = Get-AppFromClass (Get-ClassOf $hwnd) (Get-ProcNameOf $procId)
                    title = Limit-Text $t 40
                })
                if ($events.Count -gt 60) { $events.RemoveAt(0) }
                $lastKey = $key
            }
        } catch { }
    }

    $readable = $false
    try { $readable = $sock.Poll(100000, [System.Net.Sockets.SelectMode]::SelectRead) } catch { Start-Sleep -Milliseconds 100 }
    if (-not $readable) { continue }
    $ready++

    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 2000
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000
        $enc = New-Object System.Text.UTF8Encoding($false)
        $reader = New-Object System.IO.StreamReader($stream, $enc)
        $writer = New-Object System.IO.StreamWriter($stream, $enc)
        $writer.AutoFlush = $true
        try {
            $line = $reader.ReadLine()
            if (-not $line) { continue }
            $req = $line | ConvertFrom-Json
            # 鉴权：ping/info 开（只回版本与路径），其余 op 在设了令牌时必须带对
            $needAuth = (@("digest", "events", "pages", "region", "screen", "captures", "stop") -contains [string]$req.op)
            if ($needAuth -and $script:Token -and ([string]$req.token -ne [string]$script:Token)) {
                $req = [pscustomobject]@{ op = "__unauth" }
            }
            $resp = $null
            switch ($req.op) {
                "__unauth" { $resp = [ordered]@{ ok = $false; error = "unauthorized" } }
                "ping" {
                    $resp = [ordered]@{
                        ok      = $true
                        version = $script:Version
                        sha256  = $script:ScriptHash
                        pid     = $PID
                        port    = $boundPort
                        started = [int][math]::Floor($script:StartedMs / 1000)
                        up_s    = [int](([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $script:StartedMs) / 1000)
                        seq     = $seq
                    }
                }
                "info" {
                    $cap = Get-CaptureInfo
                    $resp = [ordered]@{
                        ok      = $true
                        version = $script:Version
                        sha256  = $script:ScriptHash
                        pid     = $PID
                        port    = $boundPort
                        root    = $PSScriptRoot
                        captures = $cap.dir
                        captures_n = $cap.count
                        events_n = $events.Count
                        iter = $iter
                        ready = $ready
                    }
                }
                "digest" {
                    $budget = if ($req.budget) { [int]$req.budget } else { 220 }
                    $values = [bool]$req.values
                    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $packed = Get-Digest $budget $values
                    $resp = [ordered]@{
                        ok     = $true
                        cold   = $script:firstDigest
                        ms     = [int]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $t0)
                        tokens = $packed.tokens
                        budget = $budget
                        digest = $packed.data
                    }
                    $script:firstDigest = $false
                }
                "events" {
                    $lastEventsAsk = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $since = if ($null -ne $req.since) { [int]$req.since } else { 0 }
                    $resp = [ordered]@{ ok = $true; granularity = "window"; poll_ms = 1000; events = @($events | Where-Object { $_.seq -gt $since }) }
                }
                "pages" {
                    $cdpPort = if ($req.port) { [int]$req.port } else { 9222 }
                    if (-not (Test-TcpPort $cdpPort 150)) {
                        $resp = [ordered]@{
                            ok     = $false
                            error  = "no CDP on 127.0.0.1:$cdpPort"
                            hint   = "start the browser with --remote-debugging-port=$cdpPort"
                            ms     = 0
                            pages  = @()
                        }
                        break
                    }
                    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $pgs = @(Get-CdpPages -Port $cdpPort)
                    $resp = [ordered]@{
                        ok    = $true
                        ms    = [int]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $t0)
                        count = $pgs.Count
                        pages = $pgs
                        error = $script:CdpLastError
                    }
                }
                "region" {
                    if (-not $AllowCapture) {
                        $resp = [ordered]@{ ok = $false; error = "capture disabled; start daemon with -AllowCapture" }
                        break
                    }
                    $fgc = Get-WinState
                    if (Test-AppBlocked $fgc.app) {
                        $resp = [ordered]@{ ok = $false; error = "foreground is a blocked app" }
                        break
                    }
                    $x = [int]($req.x); $y = [int]($req.y)
                    $w = [int]($req.w); $h = [int]($req.h)
                    $scale = if ($req.scale) { [double]$req.scale } else { 0.5 }
                    if ($w -le 0 -or $h -le 0) {
                        $resp = [ordered]@{ ok = $false; error = "w/h must be > 0" }
                        break
                    }
                    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $shot = Get-ScreenRegion -X $x -Y $y -W $w -H $h -Scale $scale
                    $ms = [int]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $t0)
                    if ($shot) {
                        $resp = [ordered]@{
                            ok = $true; ms = $ms; file = $shot.file
                            w = $shot.w; h = $shot.h; bytes = $shot.bytes
                            token_est = [int][Math]::Round(($shot.w * $shot.h) / 750)
                        }
                    } else {
                        $resp = [ordered]@{ ok = $false; error = "capture failed" }
                    }
                }
                "screen" {
                    if (-not $AllowCapture) {
                        $resp = [ordered]@{ ok = $false; error = "capture disabled; start daemon with -AllowCapture" }
                        break
                    }
                    $fgc = Get-WinState
                    if (Test-AppBlocked $fgc.app) {
                        $resp = [ordered]@{ ok = $false; error = "foreground is a blocked app" }
                        break
                    }
                    $scale = if ($req.scale) { [double]$req.scale } else { 0.5 }
                    $vx = [WY.Win32]::GetSystemMetrics(76)
                    $vy = [WY.Win32]::GetSystemMetrics(77)
                    $vw = [WY.Win32]::GetSystemMetrics(78)
                    $vh = [WY.Win32]::GetSystemMetrics(79)
                    if ($vw -le 0 -or $vh -le 0) {
                        $resp = [ordered]@{ ok = $false; error = "no virtual screen metrics" }
                        break
                    }
                    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $shot = Get-ScreenRegion -X $vx -Y $vy -W $vw -H $vh -Scale $scale
                    $ms = [int]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $t0)
                    if ($shot) {
                        $resp = [ordered]@{
                            ok = $true; ms = $ms; file = $shot.file
                            w = $shot.w; h = $shot.h; bytes = $shot.bytes
                            token_est = [int][Math]::Round(($shot.w * $shot.h) / 750)
                        }
                    } else {
                        $resp = [ordered]@{ ok = $false; error = "capture failed" }
                    }
                }
                "captures" {
                    # 默认只报数；删除必须显式 prune。绝不自动清理用户文件。
                    if ($req.prune) {
                        $keep = if ($null -ne $req.keep) { [int]$req.keep } else { 20 }
                        $removed = Clear-OldCaptures (Join-Path $PSScriptRoot "captures") $keep
                        $resp = [ordered]@{ ok = $true; pruned = $true; removed = $removed; keep = $keep }
                    } else {
                        $resp = [ordered]@{ ok = $true; pruned = $false } + (Get-CaptureInfo)
                    }
                }
                "stop" {
                    $resp = [ordered]@{ ok = $true; stopping = $true; pid = $PID }
                    $run = $false
                }
                default { $resp = [ordered]@{ ok = $false; error = "unknown op" } }
            }
            if ($resp) { $writer.WriteLine(($resp | ConvertTo-Json -Depth 6 -Compress)) }
        } catch {
            try { $writer.WriteLine(([ordered]@{ ok = $false; error = "$($_.Exception.Message)" } | ConvertTo-Json -Compress)) } catch { }
        } finally {
            try { $writer.Dispose() } catch { }
            try { $reader.Dispose() } catch { }
            try { $stream.Dispose() } catch { }
            try { $client.Close() } catch { }
        }
    } catch {
        # 半开连接、客户端被 kill —— 一律丢弃，回到 Poll，绝不在 Read 上卡死
        try { if ($client) { $client.Close() } } catch { }
    }
}

try { $listener.Stop() } catch { }
# 退出时清掉自己的痕迹：端口文件与令牌不该留在盘上（0.2.2 复核 ①7）
try { Remove-Item (Join-Path $PSScriptRoot "port.txt") -Force -ErrorAction SilentlyContinue } catch { }
try { if ($script:Token) { Remove-Item $script:TokenFile -Force -ErrorAction SilentlyContinue } } catch { }
Write-Output "daemon stopped"
