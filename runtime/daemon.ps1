<#
  dsh-whale-eyes / runtime daemon — 0.2.0

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
    [switch]$Once
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

    // 窗口列表只是标题：走 EnumWindows 就够，不必碰 UIA（不跨进程、不拖别人）
    public static string[] ListWindowTitles(int max, string exclude) {
      var list = new System.Collections.Generic.List<string>();
      EnumWindows(delegate(IntPtr h, IntPtr l) {
        if (!IsWindowVisible(h)) return true;
        if ((GetWindowLong(h, -20) & 0x80) != 0) return true;   // WS_EX_TOOLWINDOW: 辅助窗
        var sb = new StringBuilder(512);
        if (GetWindowText(h, sb, 512) <= 0) return true;
        var t = sb.ToString().Trim();
        if (t.Length == 0) return true;
        if (exclude != null && t == exclude) return true;
        list.Add(t);
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
$script:Started = Get-Date
$script:ScriptHash = try { (Get-FileHash (Join-Path $PSScriptRoot "daemon.ps1") -Algorithm SHA256).Hash } catch { "" }
$script:lastPid = [uint32]0
$script:lastProc = ""
$script:firstDigest = $true
$script:sbTitle = New-Object System.Text.StringBuilder 512

function Get-ClassOf([IntPtr]$hwnd) {
    $cb = New-Object System.Text.StringBuilder 256
    [void][WY.Win32]::GetClassName($hwnd, $cb, 256)
    return $cb.ToString()
}

function Get-ProcNameOf([uint32]$procId) {
    if ($procId -eq $script:lastPid -and $script:lastProc) { return $script:lastProc }
    $name = ""
    try { $name = [System.Diagnostics.Process]::GetProcessById([int]$procId).ProcessName } catch { }
    $script:lastPid = $procId
    $script:lastProc = $name
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

        # 第一道闸：读任何值之前先看 IsPassword（抛异常的 provider 一律按密文处理）
        $isPassword = $true
        try { $isPassword = [bool]$fe.Current.IsPassword } catch { $isPassword = $true }

        $role = try { $fe.Current.ControlType.ProgrammaticName -replace '^ControlType\.', '' } catch { "" }
        $fname = try { $fe.Current.Name } catch { "" }
        if ($fname -and $fname.Length -gt 40) { $fname = $fname.Substring(0, 40) }

        $fval = ""
        if ($values -and -not $isPassword) {
            try {
                $vp = $fe.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                if ($vp) { $fval = [string]$vp.Current.Value }
            } catch { $fval = "" }
            if ($fval.Length -gt 60) { $fval = $fval.Substring(0, 60) }
        } elseif ($isPassword) {
            $fval = "[password]"
        }

        [ordered]@{
            role = $role
            name = $fname
            value = $fval
            hwnd = try { [int64]$fe.Current.NativeWindowHandle } catch { 0 }
        }
    } catch {
        return $null
    }
}

# ---- 窗口列表：EnumWindows，Win32 就够 -----------------------------------
function Read-Windows([string]$foregroundTitle, [int]$max = 8) {
    $out = New-Object System.Collections.ArrayList
    $seen = New-Object System.Collections.Generic.HashSet[string]
    try {
        $raw = [WY.Win32]::ListWindowTitles(($max + 6), $foregroundTitle)
        foreach ($t in $raw) {
            $short = Limit-Text $t 30
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
    # focus 就是「窗口/文档」这一层时折叠掉：它和 win 行是同一句话
    if ($focus -and $focus.hwnd -ne 0 -and $focus.hwnd -eq $fg.hwnd) { $focus = $null }
    if ($focus -and $focus.name -and $focus.name -eq $fg.title -and
        (@("Window", "Document", "Pane", "Client", "Group") -contains $focus.role)) { $focus = $null }
    # 没名字也没值的容器（Pane/Group）说明不了任何事，别占 token
    if ($focus -and -not $focus.name -and -not $focus.value) { $focus = $null }

    $full = [ordered]@{
        app   = $app
        title = Limit-Text $fg.title 64
        focus = $focus
        wins  = Read-Windows $fg.title 8
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
        $packed = Get-Digest $Budget $false
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
$lastWinPoll = [datetime]::MinValue
$boundPort = 0
$listener = $null
$script:iter = 0
$script:ready = 0
$lastEventsAsk = [datetime]::MinValue

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
while ($run) {
    $iter++
    # 用静态 UtcNow：Get-Date 是 cmdlet，一次 1~2ms，热循环里三圈就白烧 1%
    $now = [DateTime]::UtcNow
    # Win32 层变更流：热路径只取一个 key 字符串，变了才建对象（建对象约 10ms，不能每秒都做）
    # 没人订阅 events 时退到 5s：这个 daemon 的常态是「没人看」
    $pollEvery = if (($now - $lastEventsAsk).TotalSeconds -lt 120) { 1000 } else { 5000 }
    if (($now - $lastWinPoll).TotalMilliseconds -ge $pollEvery) {
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
    try { $readable = $listener.Server.Poll(100000, [System.Net.Sockets.SelectMode]::SelectRead) } catch { Start-Sleep -Milliseconds 100 }
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
            $resp = $null
            switch ($req.op) {
                "ping" {
                    $resp = [ordered]@{
                        ok      = $true
                        version = $script:Version
                        sha256  = $script:ScriptHash
                        pid     = $PID
                        port    = $boundPort
                        started = [int]([datetimeoffset]$script:Started).ToUnixTimeSeconds()
                        up_s    = [int]((Get-Date) - $script:Started).TotalSeconds
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
                    $t0 = Get-Date
                    $packed = Get-Digest $budget $values
                    $resp = [ordered]@{
                        ok     = $true
                        cold   = $script:firstDigest
                        ms     = [int]((Get-Date) - $t0).TotalMilliseconds
                        tokens = $packed.tokens
                        budget = $budget
                        digest = $packed.data
                    }
                    $script:firstDigest = $false
                }
                "events" {
                    $lastEventsAsk = [DateTime]::UtcNow
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
                    $t0 = Get-Date
                    $pgs = @(Get-CdpPages -Port $cdpPort)
                    $resp = [ordered]@{
                        ok    = $true
                        ms    = [int]((Get-Date) - $t0).TotalMilliseconds
                        count = $pgs.Count
                        pages = $pgs
                        error = $script:CdpLastError
                    }
                }
                "region" {
                    $x = [int]($req.x); $y = [int]($req.y)
                    $w = [int]($req.w); $h = [int]($req.h)
                    $scale = if ($req.scale) { [double]$req.scale } else { 0.5 }
                    if ($w -le 0 -or $h -le 0) {
                        $resp = [ordered]@{ ok = $false; error = "w/h must be > 0" }
                        break
                    }
                    $t0 = Get-Date
                    $shot = Get-ScreenRegion -X $x -Y $y -W $w -H $h -Scale $scale
                    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
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
                    $scale = if ($req.scale) { [double]$req.scale } else { 0.5 }
                    $vx = [WY.Win32]::GetSystemMetrics(76)
                    $vy = [WY.Win32]::GetSystemMetrics(77)
                    $vw = [WY.Win32]::GetSystemMetrics(78)
                    $vh = [WY.Win32]::GetSystemMetrics(79)
                    if ($vw -le 0 -or $vh -le 0) {
                        $resp = [ordered]@{ ok = $false; error = "no virtual screen metrics" }
                        break
                    }
                    $t0 = Get-Date
                    $shot = Get-ScreenRegion -X $vx -Y $vy -W $vw -H $vh -Scale $scale
                    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
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
Write-Output "daemon stopped"
