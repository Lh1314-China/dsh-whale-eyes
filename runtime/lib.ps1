# whale-eyes shared helpers (dot-source this)
# 0.2.0: 裁剪不再改调用方的对象；截图清理默认「保留」，删除必须显式要求。

function Get-AppFromClass([string]$cls, [string]$procName) {
    if ($procName) { return $procName }
    if ($cls -like "*Chrome_WidgetWin*") { return "chromium" }
    if ($cls -eq "CabinetWClass") { return "explorer" }
    if ($cls -eq "MozillaWindowClass") { return "firefox" }
    if ($cls -eq "Notepad") { return "notepad" }
    if ($cls -like "HwndWrapper*") { return "wpf" }
    if ($cls -eq "ApplicationFrameWindow") { return "uwp" }
    if ($cls -eq "ConsoleWindowClass") { return "console" }
    if ($cls -like "SunAwt*") { return "java" }
    if (-not $cls) { return "unknown" }
    return $cls
}

# --- privacy guards -------------------------------------------------------
# Apps whose content must never leave the process.
$script:BlockedApps = @(
    "keepass", "keepassxc", "1password", "bitwarden", "lastpass",
    "authenticator", "securitykey", "dashlane", "nordpass", "enpass"
)

function Test-AppBlocked([string]$app) {
    if (-not $app) { return $false }
    $a = $app.ToLowerInvariant()
    foreach ($b in $script:BlockedApps) {
        if ($a -eq $b -or $a -like "*$b*") { return $true }
    }
    return $false
}

# Everything that touches a blocked app collapses to a single opaque label.
function Get-RedactedState([string]$app) {
    return [ordered]@{
        app   = "[blocked]"
        cls   = ""
        title = "($app)"
        focus = $null
        wins  = @()
    }
}

# --- capture retention ----------------------------------------------------
# 只留最近 $script:CaptureKeep 张。$keep = 0 表示全删（调用方必须显式 prune）。
$script:CaptureKeep = 20

function Clear-OldCaptures([string]$dir, [int]$keep = -1) {
    if (-not (Test-Path $dir)) { return 0 }
    $limit = if ($keep -lt 0) { $script:CaptureKeep } else { $keep }
    $files = @(Get-ChildItem $dir -Filter *.png -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    $removed = 0
    $files | Select-Object -Skip $limit | ForEach-Object {
        try {
            Remove-Item $_.FullName -Force -ErrorAction Stop
            $removed++
        } catch { }
    }
    return $removed
}

function Get-TokenEst([string]$json) {
    # mixed CJK/latin JSON: ~2.2 chars per token (slightly conservative)
    return [Math]::Round($json.Length / 2.2)
}

function Copy-Focus($focus) {
    if (-not $focus) { return $null }
    $o = [ordered]@{}
    foreach ($k in $focus.Keys) { $o[$k] = $focus[$k] }
    return $o
}

function Pack-Result($digest, [int]$budget) {
    $json = $digest | ConvertTo-Json -Depth 5 -Compress
    return @{ data = $digest; json = $json; tokens = (Get-TokenEst $json) }
}

# Trim optional fields until the digest fits the budget. Never mutates input.
function Compress-Digest($digest, [int]$budget) {
    if (-not $digest) { return (Pack-Result ([ordered]@{}) $budget) }

    $base = [ordered]@{}
    foreach ($k in $digest.Keys) { $base[$k] = $digest[$k] }

    $r = Pack-Result $base $budget
    if ($r.tokens -le $budget) { return $r }

    $t = [ordered]@{}
    foreach ($k in $base.Keys) { $t[$k] = $base[$k] }
    if ($t.Contains("focus") -and $t["focus"]) { $t["focus"] = Copy-Focus $t["focus"] }

    # 1) 窗口列表先砍到 4 个
    if ($t.Contains("wins") -and $t["wins"] -and @($t["wins"]).Count -gt 4) {
        $t["wins"] = @(@($t["wins"]) | Select-Object -First 4)
        $r = Pack-Result $t $budget
        if ($r.tokens -le $budget) { return $r }
    }
    # 2) 整块丢掉窗口列表
    if ($t.Contains("wins")) { $t.Remove("wins") }
    $r = Pack-Result $t $budget
    if ($r.tokens -le $budget) { return $r }

    # 3) 焦点去掉 value / pos
    if ($t.Contains("focus") -and $t["focus"] -and $t["focus"].Contains("value")) { $t["focus"].Remove("value") }
    $r = Pack-Result $t $budget
    if ($r.tokens -le $budget) { return $r }
    if ($t.Contains("focus") -and $t["focus"] -and $t["focus"].Contains("pos")) { $t["focus"].Remove("pos") }
    $r = Pack-Result $t $budget
    if ($r.tokens -le $budget) { return $r }

    # 4) 收缩自由文本
    if ($t.Contains("focus") -and $t["focus"] -and $t["focus"].Contains("name")) {
        $n = [string]$t["focus"]["name"]
        if ($n.Length -gt 16) { $t["focus"]["name"] = $n.Substring(0, 16) }
    }
    foreach ($cap in 40, 24, 12, 6) {
        $title = [string]$t["title"]
        if ($title.Length -gt $cap) { $t["title"] = $title.Substring(0, $cap) }
        $r = Pack-Result $t $budget
        if ($r.tokens -le $budget) { return $r }
    }

    # 5) 最后整块丢掉 focus
    if ($t.Contains("focus")) { $t.Remove("focus") }
    return (Pack-Result $t $budget)
}
