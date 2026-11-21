#Requires -Version 5.1
<#
.SYNOPSIS
    One-click OpenCode reset: ordered process stop, config repair, egress
    change detection (VPN/router by default, WARP optional), project identity
    rotation, and ordered restart + verification.

.DESCRIPTION
    This is the working Windows equivalent of the "oplire" reset path. The
    upstream oplire repo has no Windows release and its `reset` command calls
    Linux-only `sudo systemctl` / `/var/lib/cloudflare-warp`, so it cannot
    rotate the tunnel on Windows.

    By default the script expects you to change the egress yourself (switch
    VPN, reconnect the router, or use a hotspot) and verifies the new IP. Use
    -Wait to have it watch for the change. Use -Warp to let it rotate
    Cloudflare WARP instead: `registration delete` -> `registration new` ->
    `mode warp` -> `connect`. The WARP path also fixes the common trap where
    WARP says "Connected" but the mode is DnsOverHttps/DnsOverTls and the
    traffic never enters the tunnel.

    Token/context zeroing is on by default. It backs up opencode.db first, then
    zeroes the session totals and the per-message usage metadata that the UI
    reads for "used context". Message text and chat history are not deleted.
    Use -NoZeroTokens to keep the counters.

.PARAMETER Project
    Optional project folder. When supplied, that project's database rows are
    moved to the new identity and that project's token counters are zeroed.
    When omitted, the global identity file is rotated and the token counters
    for this script's folder (the current project) are zeroed.

.PARAMETER ZeroTokens
    Explicitly enable token/context zeroing. It is already on by default; this
    switch exists so the intent can be stated in scripts and shortcuts.

.PARAMETER NoZeroTokens
    Keep the stored token/context counters. By default the reset zeroes both
    the session totals and the per-message usage metadata (message text and
    history stay intact), then verifies the result.

.PARAMETER ZeroAllSessions
    Zero the token/context counters for every session in opencode.db, not just
    the selected project.

.PARAMETER LiveTest
    After the reset, run `opencode-unlimited test -live`. This spends one
    message but is the only real check of the app quota.

.PARAMETER SkipWarp
    Kept for compatibility. External egress (VPN/router) is the default;
    Cloudflare WARP is opt-in with -Warp.

.PARAMETER Wait
    After rotating identity, wait for the egress IP to change. Switch your VPN
    or reconnect your router while it waits. Default window: 120 seconds.

.PARAMETER NoWait
    Override the launcher's default -Wait.

.PARAMETER Proxy
    Set an upstream proxy (socks5://host:port or http://host:port) and skip the
    WARP rotation. Use -Warp as well if you really want both.

.PARAMETER Direct
    Clear any configured proxy and use a direct/system connection.

.PARAMETER Warp
    Rotate Cloudflare WARP instead of waiting for an external VPN/router change.
    Cannot be combined with -Proxy.

.PARAMETER NoServiceRestart
    Do not stop/start the OpenCode background service. The identity file is
    still rotated, but a running app may keep the old id until restarted.

.PARAMETER NoElevate
    Never prompt for UAC. Used when the WARP service needs a restart but the
    script is not elevated.

.PARAMETER DryRun
    Print the plan and current state, change nothing.

.PARAMETER Yes
    Skip the 3-second countdown.

.PARAMETER NoSplash
    Skip the animated credits screen. It is shown automatically only in a real
    console; redirected output gets a single credit line instead.

.PARAMETER Freeze
    Keep the stored token/context counters at zero while you keep using the old
    chat. A hidden helper re-zeroes new usage every few seconds, so the ring
    reads 0 after a reload and stays there. This is cosmetic: the provider still
    receives the full history, so it does not reset any server-side quota.

.PARAMETER FreezeOnly
    Start the freeze helper without running the rest of the reset. Use it when
    you only want the counters pinned at 0.

.PARAMETER Unfreeze
    Stop the freeze helper and let the counters record normally again.

.PARAMETER FreezeMinutes
    Optional freeze lifetime. 0 (default) keeps freezing until -Unfreeze.

.PARAMETER AutoCycle
    One-shot chain: stop any active freeze -> wait for an external IP change
    -> reset identity + zero tokens -> freeze counters at 0 -> run the live
    model check. This is the full "reset then pin at 0" flow in a single run.
    You still switch the VPN/router while it waits; everything after the IP
    change happens automatically.

.PARAMETER Loop
    Start a hidden background watcher that re-zeroes the token/context counters
    every N seconds (default 30) without stopping the service or rotating
    identity. This is the "real-time hook" - it keeps the old chat's counters
    at 0 continuously while you use it.

.PARAMETER LoopSeconds
    Interval between counter-zeroing passes in Loop mode. Default 30.

.PARAMETER StopLoop
    Stop the running loop watcher and let counters record normally again.

.PARAMETER Interactive
    Run an interactive prompt that asks y/n for each option (loop, wait for IP,
    zero tokens, freeze, live test) instead of remembering command-line flags.

.EXAMPLE
    .\Reset-OpenCode.ps1 -Interactive
    Prompts for each choice before running the reset.

.EXAMPLE
    .\Reset-OpenCode.ps1 -AutoCycle
    Stop previous freeze, wait for IP change, reset, pin counters at 0, then
    run the live model check.

.EXAMPLE
    .\Reset-OpenCode.ps1
    Full reset: stop, repair config, verify external egress, rotate identity,
    zero token/context counters, restart, and verify.

.EXAMPLE
    .\Reset-OpenCode.ps1 -Project "C:\dev\my-app" -LiveTest
    Rotate one project and verify with a real message.

.EXAMPLE
    .\Reset-OpenCode.ps1 -DryRun -Yes
    Show what would happen without changing anything.
#>
[CmdletBinding()]
param(
    [string]$Project = "",
    [switch]$LiveTest,
    [switch]$SkipWarp,
    [string]$Proxy = "",
    [switch]$Direct,
    [switch]$Warp,
    [switch]$Wait,
    [int]$WaitSeconds = 120,
    [switch]$NoWait,
    [switch]$NoServiceRestart,
    [switch]$ForceInside,
    [switch]$NoElevate,
    [switch]$ZeroTokens,
    [switch]$NoZeroTokens,
    [switch]$ZeroAllSessions,
    [switch]$Freeze,
    [switch]$FreezeOnly,
    [switch]$Unfreeze,
    [int]$FreezeMinutes = 0,
    [switch]$AutoCycle,
    [switch]$Loop,
    [int]$LoopSeconds = 30,
    [switch]$StopLoop,
    [switch]$Interactive,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$NoSplash,
    [int]$WarpAttempts = 3
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Interactive mode: y/n prompts for each option
# ---------------------------------------------------------------------------
if ($Interactive) {
    Write-Host ""
    Write-WarpBox @(
        "RESET INTERACTIVE SETUP",
        "  answer y/n for each option",
        "  defaults shown in brackets"
    ) -Color Cyan
    Write-Host ""

    function Ask-Yn($Question, $Default = "n") {
        $suffix = if ($Default -eq "y") { " (Y/n)" } else { " (y/N)" }
        $ans = Read-Host -Prompt ("  " + $Question + $suffix)
        if ($ans -eq "") { $ans = $Default }
        return ($ans -eq "y" -or $ans -eq "Y" -or $ans -eq "yes")
    }

    $doZero = Ask-Yn "Zero token/context counters?" "y"
    if ($doZero) { $ZeroTokens = $true } else { $NoZeroTokens = $true }

    $doWait = Ask-Yn "Wait for egress IP change (switch VPN/router now)?" "y"
    if ($doWait) { $Wait = $true } else { $NoWait = $true }
    if ($doWait) {
        $ws = Read-Host -Prompt "  Wait seconds (default 120)"
        if ($ws -match '^\d+$') { $WaitSeconds = [int]$ws }
    }

    $doWarp = Ask-Yn "Use Cloudflare WARP instead of external IP change?" "n"
    if ($doWarp) { $Warp = $true } else { $SkipWarp = $true }

    $doFreeze = Ask-Yn "Freeze counters at 0 after reset (old chat keeps working)?" "y"
    if ($doFreeze) { $Freeze = $true } else { $NoZeroTokens = $true }

    $doLoop = Ask-Yn "Run real-time loop counter-zeroing while chatting?" "n"
    if ($doLoop) {
        $Loop = $true
        $ls = Read-Host -Prompt "  Seconds between passes (default 30)"
        if ($ls -match '^\d+$') { $LoopSeconds = [int]$ls }
    }

    $doLive = Ask-Yn "Run live model check after reset (uses one message)?" "n"
    if ($doLive) { $LiveTest = $true }

    Write-Host ""
    Write-Ok "interactive setup complete - starting reset..."
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Paths and state
# ---------------------------------------------------------------------------
$script:Root        = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Cwd         = (Get-Location).Path
$script:ConfigDir   = Join-Path $env:USERPROFILE ".config\opencode"
$script:DataDir     = Join-Path $env:USERPROFILE ".local\share\opencode"
$script:DbPath      = Join-Path $script:DataDir "opencode.db"
$script:LogFile     = Join-Path $script:ConfigDir "resetter.log"
$script:StateFile   = Join-Path $script:ConfigDir "unlimited.json"
$script:PluginFile  = Join-Path $script:ConfigDir "plugins\unlimited-shield.js"
$script:TokenHelper = Join-Path $script:Root "Zero-OpenCodeTokens.py"
$script:OpenCode    = $null
$script:UnlimitedPs1= $null
$script:WarpCli        = $null
$script:Python        = $null
$script:InsideOpenCode = $false
$script:ServiceStopped = $false
$script:ServiceSkipped = $false
$script:Before      = $null
$script:After       = $null
$script:BaselineIp  = ""
$script:ProjectId   = ""
$script:IdentityDir = ""
$script:WarpResult  = "skipped"
$script:ProxyResult = "unchanged"
$script:ConfigResult= "ok"
$script:TokenResult = $null
$script:FreezePidFile = Join-Path $script:ConfigDir "freeze.pid"
$script:FreezeStatusFile = Join-Path $script:ConfigDir "freeze-status.json"
$script:LoopPidFile = Join-Path $script:ConfigDir "loop.pid"
$script:LoopStatusFile = Join-Path $script:ConfigDir "loop-status.json"
$script:FreezeResult = $null
$script:LoopResult = $null
$script:Errors      = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Text)
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}
function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host ("==> " + $Text) -ForegroundColor Cyan
    Write-Log ("==> " + $Text)
}
function Write-Ok {
    param([string]$Text)
    Write-Host ("  [+] " + $Text) -ForegroundColor Green
    Write-Log ("[+] " + $Text)
}
function Write-Warn2 {
    param([string]$Text)
    Write-Host ("  [!] " + $Text) -ForegroundColor Yellow
    Write-Log ("[!] " + $Text)
}
function Write-Err2 {
    param([string]$Text)
    Write-Host ("  [x] " + $Text) -ForegroundColor Red
    Write-Log ("[x] " + $Text)
    [void]$script:Errors.Add($Text)
}
function Write-Info {
    param([string]$Text)
    Write-Host ("      " + $Text) -ForegroundColor DarkGray
    Write-Log ("      " + $Text)
}

# ---------------------------------------------------------------------------
# Credits splash: made by Abdullah Fadil
# ---------------------------------------------------------------------------
$script:Glyphs = @{
    'A' = @(' ### ', '#   #', '#####', '#   #', '#   #')
    'B' = @('#### ', '#   #', '#### ', '#   #', '#### ')
    'D' = @('#### ', '#   #', '#   #', '#   #', '#### ')
    'U' = @('#   #', '#   #', '#   #', '#   #', ' ### ')
    'L' = @('#    ', '#    ', '#    ', '#    ', '#####')
    'H' = @('#   #', '#   #', '#####', '#   #', '#   #')
    'F' = @('#####', '#    ', '#### ', '#    ', '#    ')
    'I' = @('#####', '  #  ', '  #  ', '  #  ', '#####')
    ' ' = @('   ', '   ', '   ', '   ', '   ')
}

function Get-BlockWord {
    param([string]$Word)
    $rows = @('', '', '', '', '')
    foreach ($ch in $Word.ToUpperInvariant().ToCharArray()) {
        $glyph = $script:Glyphs[[string]$ch]
        if (-not $glyph) { $glyph = $script:Glyphs[' '] }
        for ($r = 0; $r -lt 5; $r++) { $rows[$r] = $rows[$r] + $glyph[$r] + ' ' }
    }
    return $rows
}

function Write-TypeLine {
    param([string]$Text, [string]$Color = 'DarkGray', [int]$Delay = 18)
    Write-Host '  ' -NoNewline
    foreach ($ch in $Text.ToCharArray()) {
        Write-Host $ch -NoNewline -ForegroundColor $Color
        Start-Sleep -Milliseconds $Delay
    }
    Write-Host ''
}

function Write-GlitchLine {
    param([string]$Text, [int]$Frames = 9, [int]$Delay = 55)
    $noise = '!@#$%^&*()_+-=[]{};:<>?/\|0123456789ABCDEF'
    $prefix = '    '
    $width = $Text.Length
    for ($f = 0; $f -lt $Frames; $f++) {
        $line = ''
        foreach ($ch in $Text.ToCharArray()) {
            if ($ch -eq ' ') { $line += ' '; continue }
            $settle = $f -ge ($Frames - 3)
            $chance = 12 + ($f * 11)
            if ($settle -or (Get-Random -Maximum 100) -lt $chance) {
                $line += $ch
            } else {
                $line += $noise[(Get-Random -Maximum $noise.Length)]
            }
        }
        $color = if ($f -ge ($Frames - 3)) { 'White' } elseif ($f -ge 5) { 'Cyan' } else { 'DarkCyan' }
        Write-Host ("`r" + $prefix + $line.PadRight($width)) -NoNewline -ForegroundColor $color
        Start-Sleep -Milliseconds $Delay
    }
    Write-Host ("`r" + $prefix + $Text.PadRight($width)) -ForegroundColor White
}

function Show-Credits {
    param([switch]$Force)
    $interactive = $false
    try { $interactive = -not [Console]::IsOutputRedirected } catch { }
    if ($NoSplash -or (-not $interactive -and -not $Force)) {
        Write-Host ''
        Write-Host '  RESETER  |  made by Abdullah Fadil' -ForegroundColor DarkCyan
        Write-Host ''
        return
    }
    try {
        Write-Host ''
        $boot = @(
            'reseter kernel ........ online',
            'credits screen ........ loading',
            'sqlite bridge ......... armed',
            'token incinerator ..... armed',
            'egress calibrator ..... armed'
        )
        foreach ($line in $boot) {
            Write-Host ('  ' + $line) -ForegroundColor DarkGray
            Start-Sleep -Milliseconds 90
        }
        Write-Host ''
        Start-Sleep -Milliseconds 100

        Write-TypeLine 'a production by' 'DarkGray' 14
        Start-Sleep -Milliseconds 80
        Write-GlitchLine 'A B D U L L A H   F A D I L'
        Start-Sleep -Milliseconds 80

        foreach ($row in (Get-BlockWord 'ABDULLAH')) {
            Write-Host ('   ' + $row) -ForegroundColor Cyan
            Start-Sleep -Milliseconds 55
        }
        foreach ($row in (Get-BlockWord 'FADIL')) {
            Write-Host ('   ' + $row) -ForegroundColor DarkCyan
            Start-Sleep -Milliseconds 55
        }
        Write-Host ''

        $width = 36
        $label = 'waking the reset engine'
        for ($i = 0; $i -le 100; $i += 2) {
            if ($i -ge 80) { $label = 'finalizing credits' }
            elseif ($i -ge 58) { $label = 'calibrating egress' }
            elseif ($i -ge 36) { $label = 'arming token incinerator' }
            elseif ($i -ge 18) { $label = 'mounting sqlite' }
            $filled = [int][Math]::Floor($width * $i / 100)
            $bar = ('#' * $filled) + ('.' * ($width - $filled))
            Write-Host ("`r  [" + $bar + "] " + $i.ToString().PadLeft(3) + "%  " + $label.PadRight(26)) -NoNewline -ForegroundColor DarkCyan
            Start-Sleep -Milliseconds 22
        }
        Write-Host ''
        Write-Host '  [####################################] 100%  ready' -ForegroundColor Green
        Start-Sleep -Milliseconds 140

        Write-Host ''
        $rule = '  ' + ('=' * 62)
        Write-Host $rule -ForegroundColor DarkCyan
        Write-Host '    R E S E T E R' -ForegroundColor Cyan
        Write-Host '    opencode one-click reset' -ForegroundColor DarkGray
        Write-Host $rule -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '    MADE BY        ABDULLAH FADIL' -ForegroundColor White
        Write-Host '    pipeline       7 stages, ordered' -ForegroundColor Gray
        Write-Host '    token surgery  sqlite + wal, verified' -ForegroundColor Gray
        Write-Host '    egress         identity + ip rotation' -ForegroundColor Gray
        Write-Host '    safety         backup before every write' -ForegroundColor Gray
        Write-Host ''
        Write-Host $rule -ForegroundColor DarkCyan
        Write-Host ''
        Start-Sleep -Milliseconds 200
        Write-Host '  >> starting reset' -ForegroundColor Green
        Write-Host ''
        Start-Sleep -Milliseconds 120
    } catch {
        Write-Host ''
    }
}

# ---------------------------------------------------------------------------
# Freeze mode: keep the stored counters at zero while the old chat runs
# ---------------------------------------------------------------------------
function Get-FreezeInfo {
    if (-not (Test-Path -LiteralPath $script:FreezePidFile)) { return $null }
    try {
        return (Get-Content -LiteralPath $script:FreezePidFile -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-FreezeRunning {
    $info = Get-FreezeInfo
    if (-not $info -or -not $info.pid) { return $false }
    $proc = Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue
    return [bool]$proc
}

function Stop-Freeze {
    $info = Get-FreezeInfo
    $status = $null
    if (Test-Path -LiteralPath $script:FreezeStatusFile) {
        try { $status = Get-Content -LiteralPath $script:FreezeStatusFile -Raw | ConvertFrom-Json } catch { }
    }

    $pids = New-Object System.Collections.ArrayList
    if ($info -and $info.pid) { [void]$pids.Add([int]$info.pid) }
    if ($status -and $status.pid) { [void]$pids.Add([int]$status.pid) }

    # The Windows Store python alias spawns a child; include helper descendants.
    foreach ($root in @($pids)) {
        try {
            $kids = Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $root) -ErrorAction SilentlyContinue
            foreach ($kid in $kids) {
                if ($kid.CommandLine -and $kid.CommandLine -like "*Zero-OpenCodeTokens*") {
                    [void]$pids.Add([int]$kid.ProcessId)
                }
            }
        } catch { }
    }

    $stopped = $false
    foreach ($procId in ($pids | Sort-Object -Unique -Descending)) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match '^(python|pythonw|py)$') {
            try {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                $stopped = $true
            } catch { }
        }
    }
    Remove-Item -LiteralPath $script:FreezePidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:FreezeStatusFile -Force -ErrorAction SilentlyContinue
    return $stopped
}

function Start-Freeze {
    if (-not $script:Python) {
        Write-Warn2 "python not found; freeze mode needs it"
        [void]$script:Errors.Add("freeze failed: python not found")
        return
    }
    if (-not (Test-Path -LiteralPath $script:TokenHelper)) {
        Write-Warn2 ("token helper missing: " + $script:TokenHelper)
        [void]$script:Errors.Add("freeze failed: helper missing")
        return
    }

    if (Stop-Freeze) { Write-Info "replaced the previous freeze process" }

    $target = if ($Project) { $Project } else { $script:Cwd }
    $pyArgs = @(
        $script:TokenHelper,
        "--watch",
        "--db", $script:DbPath,
        "--interval", "3",
        "--status", $script:FreezeStatusFile
    )
    if ($ZeroAllSessions) {
        $pyArgs += "--all"
        $scopeText = "every session"
    } else {
        $pyArgs += @("--project", $target)
        $scopeText = $target
    }
    if ($FreezeMinutes -gt 0) {
        $pyArgs += @("--minutes", [string]$FreezeMinutes)
    }

    $proc = Start-Process -FilePath $script:Python -ArgumentList $pyArgs -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 900

    if ($proc.HasExited) {
        Write-Warn2 ("freeze process exited immediately (code " + $proc.ExitCode + ")")
        [void]$script:Errors.Add("freeze failed: helper exited immediately")
        return
    }

    $info = [ordered]@{
        pid          = $proc.Id
        started      = (Get-Date).ToString("s")
        scope        = $scopeText
        all_sessions = [bool]$ZeroAllSessions
        minutes      = $FreezeMinutes
    }
    try {
        ($info | ConvertTo-Json -Compress) | Set-Content -LiteralPath $script:FreezePidFile -Encoding UTF8
    } catch { }

    $script:FreezeResult = [pscustomobject]$info
    Write-Ok ("freeze active (pid " + $proc.Id + "): counters stay at 0 for " + $scopeText)
    Write-Info "the old chat keeps working; new usage is zeroed every 3 seconds"
    if ($FreezeMinutes -gt 0) {
        Write-Info ("freeze stops automatically after " + $FreezeMinutes + " minute(s)")
    } else {
        Write-Info "stop it with: .\Reset-OpenCode.cmd -Unfreeze"
    }
}

# ---------------------------------------------------------------------------
# Loop mode: continuous lightweight counter-zeroing watcher
# ---------------------------------------------------------------------------
function Get-LoopInfo {
    if (-not (Test-Path -LiteralPath $script:LoopPidFile)) { return $null }
    try {
        return (Get-Content -LiteralPath $script:LoopPidFile -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-LoopRunning {
    $info = Get-LoopInfo
    if (-not $info -or -not $info.pid) { return $false }
    $proc = Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue
    return [bool]$proc
}

function Stop-Loop {
    $info = Get-LoopInfo
    $status = $null
    if (Test-Path -LiteralPath $script:LoopStatusFile) {
        try { $status = Get-Content -LiteralPath $script:LoopStatusFile -Raw | ConvertFrom-Json } catch { }
    }

    $pids = New-Object System.Collections.ArrayList
    if ($info -and $info.pid) { [void]$pids.Add([int]$info.pid) }
    if ($status -and $status.pid) { [void]$pids.Add([int]$status.pid) }

    foreach ($root in @($pids)) {
        try {
            $kids = Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $root) -ErrorAction SilentlyContinue
            foreach ($kid in $kids) {
                if ($kid.CommandLine -and $kid.CommandLine -like "*Zero-OpenCodeTokens*") {
                    [void]$pids.Add([int]$kid.ProcessId)
                }
            }
        } catch { }
    }

    $stopped = $false
    foreach ($procId in ($pids | Sort-Object -Unique -Descending)) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match '^(python|pythonw|py)$') {
            try {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                $stopped = $true
            } catch { }
        }
    }
    Remove-Item -LiteralPath $script:LoopPidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:LoopStatusFile -Force -ErrorAction SilentlyContinue
    return $stopped
}

function Start-Loop {
    if (-not $script:Python) {
        Write-Warn2 "python not found; loop mode needs it"
        [void]$script:Errors.Add("loop failed: python not found")
        return
    }
    if (-not (Test-Path -LiteralPath $script:TokenHelper)) {
        Write-Warn2 ("token helper missing: " + $script:TokenHelper)
        [void]$script:Errors.Add("loop failed: helper missing")
        return
    }
    if (-not (Test-Path -LiteralPath $script:DbPath)) {
        Write-Warn2 ("OpenCode database missing: " + $script:DbPath)
        [void]$script:Errors.Add("loop failed: database missing")
        return
    }

    if (Stop-Loop) { Write-Info "replaced the previous loop watcher" }

    $target = if ($Project) { $Project } else { $script:Cwd }
    $pyArgs = @(
        $script:TokenHelper,
        "--watch",
        "--db", $script:DbPath,
        "--interval", [string]$LoopSeconds,
        "--minutes", "0",
        "--status", $script:LoopStatusFile
    )
    if ($ZeroAllSessions) {
        $pyArgs += "--all"
        $scopeText = "every session"
    } else {
        $pyArgs += @("--project", $target)
        $scopeText = $target
    }

    $proc = Start-Process -FilePath $script:Python -ArgumentList $pyArgs -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 900

    if ($proc.HasExited) {
        Write-Warn2 ("loop watcher exited immediately (code " + $proc.ExitCode + ")")
        [void]$script:Errors.Add("loop failed: helper exited immediately")
        return
    }

    $info = [ordered]@{
        pid          = $proc.Id
        started      = (Get-Date).ToString("s")
        scope        = $scopeText
        all_sessions = [bool]$ZeroAllSessions
        interval     = $LoopSeconds
    }
    try {
        ($info | ConvertTo-Json -Compress) | Set-Content -LiteralPath $script:LoopPidFile -Encoding UTF8
    } catch { }

    $script:LoopResult = [pscustomobject]$info
    Write-Ok ("loop active (pid " + $proc.Id + "): counters re-zeroed every " + $LoopSeconds + "s for " + $scopeText)
    Write-Info "this is lightweight counter zeroing only - no service stop, no identity rotation"
    Write-Info "stop it with: .\Reset-OpenCode.cmd -StopLoop"
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------
function Test-Admin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        return (& $FilePath @Arguments 2>&1 | Out-String)
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Resolve-Tool {
    param(
        [string]$Name,
        [string[]]$Candidates
    )
    $cmd = @(Get-Command $Name -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0 -and $cmd[0].Source) { return $cmd[0].Source }
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Resolve-Python {
    $cmd = @(Get-Command "python.exe" -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0 -and $cmd[0].Source) {
        $found = $cmd[0].Source
        # The Windows Store alias is a shim that spawns a second python.exe.
        # Resolve the real interpreter so Start-Process tracks the right PID.
        if ($found -like "*WindowsApps*") {
            try {
                $real = (& $found -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1)
                if ($real) {
                    $real = $real.Trim()
                    if ($real -and (Test-Path -LiteralPath $real)) { return $real }
                }
            } catch { }
        }
        return $found
    }

    $cmd = @(Get-Command "python" -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0 -and $cmd[0].Source) { return $cmd[0].Source }

    $cmd = @(Get-Command "py" -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0 -and $cmd[0].Source) { return $cmd[0].Source }

    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA "Python\bin\python.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\python.exe")
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Test-InsideOpenCode {
    $procId = $PID
    for ($i = 0; $i -lt 12; $i++) {
        $proc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $procId) -ErrorAction SilentlyContinue
        if (-not $proc) { break }
        if ($proc.Name -match '^(opencode-cli|OpenCode)\.exe$') { return $true }
        $procId = $proc.ParentProcessId
        if (-not $procId) { break }
    }
    return $false
}

function Get-ConfiguredProxy {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return "" }
    try {
        $cfg = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
        if ($cfg.PSObject.Properties["proxy"] -and $cfg.proxy) { return [string]$cfg.proxy }
    } catch { }
    return ""
}

function Get-Identity {
    $path = Join-Path $script:ConfigDir "identity.json"
    if (Test-Path -LiteralPath $path) {
        try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { }
    }
    return $null
}

function Get-LastIp {
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $cfg = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
            if ($cfg.PSObject.Properties["lastIp"] -and $cfg.lastIp) { return [string]$cfg.lastIp }
        } catch { }
    }
    return ""
}

function Save-LastIp {
    param([string]$Ip)
    if (-not $Ip -or -not (Test-Path -LiteralPath $script:StateFile)) { return }
    try {
        $cfg = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
        $cfg | Add-Member -MemberType NoteProperty -Name lastIp -Value $Ip -Force
        $cfg | Add-Member -MemberType NoteProperty -Name updatedAt -Value ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) -Force
        [System.IO.File]::WriteAllText($script:StateFile, ($cfg | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Get-Egress {
    $proxy = Get-ConfiguredProxy
    $url = "https://www.cloudflare.com/cdn-cgi/trace?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $curlArgs = @("-s", "--max-time", "12")
    if ($proxy -and $proxy -match '^(socks5h?|http|https)://') {
        $curlArgs += @("--proxy", $proxy)
    } else {
        $curlArgs += @("--noproxy", "*")
    }
    $curlArgs += $url

    $text = ""
    try {
        $text = (& curl.exe @curlArgs 2>$null) -join "`n"
    } catch { }

    if ($text) {
        $ip = ""; $warp = "unknown"; $loc = ""
        foreach ($line in ($text -split "`n")) {
            $line = $line.Trim()
            if ($line -like "ip=*")   { $ip = $line.Substring(3).Trim() }
            if ($line -like "warp=*") { $warp = $line.Substring(5).Trim() }
            if ($line -like "loc=*")  { $loc = $line.Substring(4).Trim() }
        }
        if ($ip) {
            return [pscustomobject]@{ IP = $ip; Warp = $warp; Loc = $loc; Via = "cloudflare-trace" }
        }
    }

    try {
        $fallback = Invoke-RestMethod -Uri "https://api.ipify.org?format=json" -TimeoutSec 12
        if ($fallback.ip) {
            return [pscustomobject]@{ IP = [string]$fallback.ip; Warp = "unknown"; Loc = ""; Via = "ipify" }
        }
    } catch { }

    return [pscustomobject]@{ IP = ""; Warp = "unknown"; Loc = ""; Via = "none" }
}

function Get-WarpStatus {
    if (-not $script:WarpCli) { return "missing" }
    $out = Invoke-Native $script:WarpCli @("status")
    if ($out -match "Connected")    { return "connected" }
    if ($out -match "Disconnected") { return "disconnected" }
    if ($out -match "Unable")       { return "unable" }
    return $out.Trim()
}

function Get-WarpModeLine {
    if (-not $script:WarpCli) { return "not installed" }
    $settings = Invoke-Native $script:WarpCli @("settings", "list")
    $line = ($settings -split "`r?`n" | Where-Object { $_ -match 'Mode:' } | Select-Object -First 1)
    if ($line) { return $line.Trim() }
    return "unknown"
}

function Test-WarpRegistration {
    if (-not $script:WarpCli) { return $false }
    $out = Invoke-Native $script:WarpCli @("registration", "show")
    return ($out -match "Account type")
}

function Restart-WarpService {
    if ($DryRun) { Write-Info "dry-run: would restart the CloudflareWARP service"; return $false }

    if (Test-Admin) {
        try {
            Restart-Service -Name "CloudflareWARP" -Force -ErrorAction Stop
            Start-Sleep -Seconds 5
            return $true
        } catch {
            Write-Warn2 ("service restart failed: " + $_.Exception.Message)
            return $false
        }
    }

    if ($NoElevate) {
        Write-Warn2 "WARP service restart needs Administrator; rerun elevated or use -NoElevate to silence"
        return $false
    }

    $helper = Join-Path $env:TEMP ("resetter-warp-" + [guid]::NewGuid().ToString("N") + ".ps1")
    $warpPath = $script:WarpCli
    $content = @"
`$ErrorActionPreference = 'SilentlyContinue'
Restart-Service -Name 'CloudflareWARP' -Force
Start-Sleep -Seconds 5
& '$warpPath' mode warp
& '$warpPath' connect
Start-Sleep -Seconds 12
"@
    try {
        Set-Content -LiteralPath $helper -Value $content -Encoding UTF8
        Write-Info "asking Windows for permission to restart the WARP service (UAC)..."
        $proc = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList ("-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"" + $helper + "`"") -Wait -PassThru
        return ($proc.ExitCode -eq 0)
    } catch {
        Write-Warn2 "elevation declined or failed; continuing without a service restart"
        return $false
    } finally {
        Remove-Item -LiteralPath $helper -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Process ordering
# ---------------------------------------------------------------------------
function Stop-Bridge {
    $pids = @()

    $pidFile = Join-Path $script:ConfigDir "unlimited-bridge.pid"
    if (Test-Path -LiteralPath $pidFile) {
        $raw = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue)
        if ($raw -and $raw.Trim() -match '^\d+$') { $pids += [int]$raw.Trim() }
    }

    $nodes = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue
    foreach ($node in $nodes) {
        if ($node.CommandLine -and $node.CommandLine -match 'proxy-bridge\.js') {
            $pids += [int]$node.ProcessId
        }
    }

    $pids = @($pids | Sort-Object -Unique)
    if ($pids.Count -eq 0) {
        Write-Info "bridge not running"
        return
    }

    foreach ($procId in $pids) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        if ($DryRun) {
            Write-Info ("dry-run: would stop bridge pid " + $procId)
        } else {
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            Write-Ok ("bridge stopped (pid " + $procId + ")")
        }
    }
}

function Stop-Oplire {
    $procs = Get-CimInstance Win32_Process -Filter "Name='oplire.exe'" -ErrorAction SilentlyContinue
    if (-not $procs) {
        Write-Info "oplire proxy not running"
        return
    }
    foreach ($proc in $procs) {
        if ($DryRun) {
            Write-Info ("dry-run: would stop oplire pid " + $proc.ProcessId)
        } else {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Ok ("oplire stopped (pid " + $proc.ProcessId + ")")
        }
    }
}

function Stop-OpenCodeService {
    if ($NoServiceRestart) {
        Write-Warn2 "service restart disabled by -NoServiceRestart"
        $script:ServiceSkipped = $true
        return
    }
    if ($script:InsideOpenCode -and -not $ForceInside) {
        Write-Warn2 "running inside OpenCode; service stop skipped so this session survives"
        Write-Info "identity + egress are still reset; for stuck-error cleanup run the .cmd from Explorer"
        $script:ServiceSkipped = $true
        return
    }

    $status = Invoke-Native $script:OpenCode @("service", "status")
    if ($status -notmatch 'https?://|127\.0\.0\.1:\d+') {
        Write-Info "OpenCode service already stopped"
        $script:ServiceStopped = $true
        return
    }

    if ($DryRun) {
        Write-Info "dry-run: would stop the OpenCode background service"
        $script:ServiceStopped = $true
        return
    }

    Invoke-Native $script:OpenCode @("service", "stop") | Out-Null
    Start-Sleep -Seconds 2
    $status = Invoke-Native $script:OpenCode @("service", "status")
    if ($status -notmatch 'https?://|127\.0\.0\.1:\d+') {
        Write-Ok "OpenCode service stopped"
    } else {
        Write-Warn2 "service still reports a URL after stop"
    }
    $script:ServiceStopped = $true
}

function Start-OpenCodeService {
    if ($script:ServiceSkipped) {
        Write-Info "service restart was skipped; leaving the app as-is"
        return
    }
    if (-not $script:ServiceStopped) {
        Write-Info "service was not stopped by this run"
        return
    }
    if ($DryRun) {
        Write-Info "dry-run: would start the OpenCode background service"
        return
    }

    $status = Invoke-Native $script:OpenCode @("service", "status")
    if ($status -match 'https?://|127\.0\.0\.1:\d+') {
        Write-Ok ("OpenCode service running: " + $status.Trim())
        $script:ServiceStopped = $false
        return
    }

    Invoke-Native $script:OpenCode @("service", "start") | Out-Null
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        $status = Invoke-Native $script:OpenCode @("service", "status")
        if ($status -match 'https?://|127\.0\.0\.1:\d+') { break }
    }
    if ($status -match 'https?://|127\.0\.0\.1:\d+') {
        Write-Ok ("OpenCode service running: " + $status.Trim())
        $script:ServiceStopped = $false
    } else {
        Write-Warn2 "OpenCode service did not come up; run: opencode service start"
    }
}

# ---------------------------------------------------------------------------
# Config repair
# ---------------------------------------------------------------------------
function Test-UnlimitedConfig {
    $issues = @()

    if (-not (Test-Path -LiteralPath $script:PluginFile)) {
        $issues += "identity plugin missing"
    }

    $cfgPath = Join-Path $script:ConfigDir "opencode.json"
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($cfgPath) -replace "^\uFEFF", ""
            $cfg = $raw | ConvertFrom-Json
            $names = @()
            if ($cfg.PSObject.Properties["commands"] -and $cfg.commands) {
                $names = @($cfg.commands.PSObject.Properties.Name)
            }
            if (-not ($names -contains "opencode-unlimited")) {
                $issues += "slash commands missing"
            }
        } catch {
            $issues += "opencode.json unreadable"
        }
    } else {
        $issues += "opencode.json missing"
    }

    if (-not (Test-Path -LiteralPath $script:StateFile)) {
        $issues += "unlimited.json missing"
    }

    return $issues
}

function Invoke-Unlimited {
    param([string[]]$ToolArgs)
    $all = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script:UnlimitedPs1) + $ToolArgs
    $out = Invoke-Native "powershell.exe" $all
    return $out
}

function Repair-Config {
    $issues = @(Test-UnlimitedConfig)
    $unreadable = @($issues | Where-Object { $_ -eq "opencode.json unreadable" })
    $repairable = @($issues | Where-Object { $_ -ne "opencode.json unreadable" })

    if ($unreadable.Count -gt 0) {
        Write-Warn2 "opencode.json could not be parsed; leaving it untouched"
        Write-Info "fix the JSON by hand, then rerun this script"
    }

    if ($repairable.Count -gt 0) {
        Write-Warn2 ("config needs repair: " + ($repairable -join ", "))
        if ($DryRun) {
            Write-Info "dry-run: would run opencode-unlimited install"
        } else {
            $out = Invoke-Unlimited @("install")
            if ($out -match "installed|done") {
                Write-Ok "config repaired (plugin, slash commands, PATH, state)"
            } else {
                Write-Warn2 "config repair returned an unexpected result"
                Write-Info (($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 4) -join " ")
            }
        }
    } elseif ($issues.Count -eq 0) {
        Write-Ok "config present (plugin, slash commands, state)"
    }

    if ($DryRun) {
        Write-Info "dry-run: would ensure the identity plugin is enabled"
    } else {
        $out = Invoke-Unlimited @("on")
        if ($out -match "enabled") {
            Write-Ok "identity plugin enabled"
        } else {
            Write-Warn2 "could not confirm the identity plugin state"
        }
    }
}

# ---------------------------------------------------------------------------
# WARP egress rotation
# ---------------------------------------------------------------------------
function Remove-WarpRegistration {
    for ($i = 0; $i -lt 8; $i++) {
        Invoke-Native $script:WarpCli @("registration", "delete") | Out-Null
        Start-Sleep -Seconds 2
        $out = Invoke-Native $script:WarpCli @("registration", "show")
        if ($out -match "Missing registration") { return $true }
    }
    return $false
}

function New-WarpRegistration {
    Invoke-Native $script:WarpCli @("--accept-tos", "registration", "new") | Out-Null
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        if (Test-WarpRegistration) { return $true }
    }
    return $false
}

function Connect-Warp {
    Invoke-Native $script:WarpCli @("mode", "warp") | Out-Null
    Invoke-Native $script:WarpCli @("connect") | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if ((Get-WarpStatus) -eq "connected") { return $true }
    }
    return $false
}

function Write-WarpStep {
    param([string]$Text, [string]$Color = "Cyan", [int]$Delay = 0)
    Write-Host ("    -> " + $Text) -ForegroundColor $Color
    if ($Delay -gt 0) { Start-Sleep -Milliseconds $Delay }
}

function Write-WarpBox {
    param([string[]]$Lines, [string]$Color = "Cyan")
    $width = 0
    foreach ($l in $Lines) { if ($l.Length -gt $width) { $width = $l.Length } }
    $top = "+" + ("-" * ($width + 2)) + "+"
    $bot = "+" + ("-" * ($width + 2)) + "+"
    Write-Host $top -ForegroundColor $Color
    foreach ($l in $Lines) {
        $pad = " " * ($width - $l.Length)
        Write-Host ("| " + $l + $pad + " |") -ForegroundColor $Color
    }
    Write-Host $bot -ForegroundColor $Color
}

function Write-WarpBanner {
    param([string]$Title, [string]$Subtitle = "")
    Write-Host ""
    Write-Host "+" + ("-" * 62) + "+" -ForegroundColor Cyan
    Write-Host ("|  " + $Title + (" " * (60 - $Title.Length)) + "  |") -ForegroundColor Cyan
    if ($Subtitle) {
        Write-Host ("|  " + $Subtitle + (" " * (60 - $Subtitle.Length)) + "  |") -ForegroundColor DarkGray
    }
    Write-Host "+" + ("-" * 62) + "+" -ForegroundColor Cyan
    Write-Host ""
}

function Reset-WarpEgress {
    if (-not $script:WarpCli) {
        Write-Warn2 "warp-cli not found; skipping egress rotation"
        $script:WarpResult = "missing"
        return
    }
    if ($DryRun) {
        Write-WarpBanner "WARP DRY-RUN" "would rotate egress through Cloudflare WARP"
        Write-Info "steps: disconnect -> delete registration -> new registration -> mode warp -> connect -> verify ip"
        $script:WarpResult = "dry-run"
        return
    }

    $before = $script:Before
    $serviceRestarted = $false

    Write-WarpBanner "CLOUDFLARE WARP ROTATION" "old ip: " + $before.IP + "  (warp=" + $before.Warp + ")"

    for ($attempt = 1; $attempt -le $WarpAttempts; $attempt++) {
        Write-Host ""
        Write-Host ("  +--- ATTEMPT " + $attempt + "/" + $WarpAttempts + " ---------------------------------------------------+") -ForegroundColor DarkCyan
        Write-Host ("  +------------------------------------------------------------------------------+") -ForegroundColor DarkCyan

        Write-WarpStep "disconnecting current WARP session..." "Yellow" 150
        Invoke-Native $script:WarpCli @("disconnect") | Out-Null
        Start-Sleep -Seconds 2

        Write-WarpStep "forcing mode warp (fixes DoH-vs-Warp tunnel trap)..." "Yellow" 150
        Invoke-Native $script:WarpCli @("mode", "warp") | Out-Null

        Write-WarpStep "deleting old WARP registration..." "Red" 200
        if (-not (Remove-WarpRegistration)) {
            Write-Warn2 "could not clear the old WARP registration"
            Write-Host ("  +- attempt " + $attempt + " failed at registration delete") -ForegroundColor Red
            continue
        }
        Write-Ok "old registration removed"

        Write-WarpStep "creating new WARP registration (fresh device identity)..." "Green" 200
        if (-not (New-WarpRegistration)) {
            Write-Warn2 "could not create a new WARP registration"
            Write-Host ("  +- attempt " + $attempt + " failed at registration new") -ForegroundColor Red
            continue
        }
        Write-Ok "new registration created"

        Write-WarpStep "connecting to WARP tunnel..." "Cyan" 300
        if (-not (Connect-Warp)) {
            Write-Warn2 "WARP did not reach Connected state"
            Write-Host ("  +- attempt " + $attempt + " failed at connect") -ForegroundColor Red
            continue
        }
        Write-Ok "WARP connected; tunnel active"

        Write-WarpStep "waiting for traffic to route through WARP tunnel..." "DarkGray" 200
        $after = $null
        $ipChanged = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            $after = Get-Egress
            $pct = [int](($i + 1) / 20 * 100)
            $filled = [int](($i + 1) / 20 * 20)
            $bar = ("#" * $filled) + ("." * (20 - $filled))
            Write-Host ("    * verifying egress ip [" + $bar + "] " + $pct.ToString("D3") + "%  current: " + $after.IP + " (warp=" + $after.Warp + ")") -NoNewline -ForegroundColor DarkGray
            if ($after.Warp -eq "on" -and $after.IP -and $after.IP -ne $before.IP) { $ipChanged = $true; break }
            Write-Host "`r" -NoNewline
        }
        Write-Host ""

        if ($ipChanged -and $after.IP -and $after.IP -ne $before.IP) {
            $script:After = $after
            $script:WarpResult = "rotated"
            Write-Host ""
            Write-WarpBox @(
                "WARP Egress ROTATED SUCCESSFULLY",
                "  old ip: " + $before.IP,
                "  new ip: " + $after.IP,
                "  mode:   warp (tunnel active)",
                "  change: " + $before.IP + "  ->  " + $after.IP
            ) -Color Green
            Write-Host ""
            return
        }

        if ($after.Warp -ne "on" -and -not $serviceRestarted) {
            Write-Warn2 "WARP says Connected but traffic is not using the tunnel"
            Write-Info "this is the DoH-vs-Warp mode trap; restarting WARP service"
            if (Restart-WarpService) {
                $serviceRestarted = $true
                Write-Ok "WARP service restarted; re-applying mode warp + connect"
                Invoke-Native $script:WarpCli @("mode", "warp") | Out-Null
                Invoke-Native $script:WarpCli @("connect") | Out-Null
                Start-Sleep -Seconds 12
                $after = Get-Egress
                if ($after.Warp -eq "on" -and $after.IP -and $after.IP -ne $before.IP) {
                    $script:After = $after
                    $script:WarpResult = "rotated"
                    Write-Host ""
                    Write-WarpBox @(
                        "WARP Egress ROTATED (after service restart)",
                        "  old ip: " + $before.IP,
                        "  new ip: " + $after.IP,
                        "  mode:   warp (tunnel active)",
                        "  change: " + $before.IP + "  ->  " + $after.IP
                    ) -Color Green
                    Write-Host ""
                    return
                }
            }
        }

        if ($after.IP) {
            Write-Warn2 ("ip unchanged: " + $after.IP + " (warp=" + $after.Warp + ")")
        } else {
            Write-Warn2 "could not read the egress ip after connect"
        }
        Write-Host ("  +- attempt " + $attempt + " did not change egress ip") -ForegroundColor Yellow
    }

    $script:After = Get-Egress
    $script:WarpResult = "unchanged"
    Write-Host ""
    Write-WarpBox @(
        "WARP ROTATION FAILED",
        "  attempts: $WarpAttempts",
        "  ip stayed: " + ($script:After.IP -or "unknown"),
        "  suggestion: try -Proxy socks5://host:port or switch VPN/router manually"
    ) -Color Red
    Write-Host ""
    Write-Info "try a phone hotspot/VPN, or use: .\Reset-OpenCode.ps1 -Proxy socks5://host:port"
}

function Test-ExternalEgressChanged {
    param($Current)
    $last = Get-LastIp
    if ($last -and $Current.IP -and $Current.IP -ne $last) { return $last }
    return ""
}

function Read-ExternalEgress {
    $current = Get-Egress
    $script:After = $current
    $last = Test-ExternalEgressChanged $current
    if ($last) {
        $script:WarpResult = "external"
        Write-Ok ("egress changed since last run: " + $last + " -> " + $current.IP)
    } else {
        $script:WarpResult = "skipped"
        Write-Info ("egress ip: " + $current.IP + " (unchanged)")
    }
}

function Wait-ExternalEgress {
    if ($DryRun) {
        $script:WarpResult = "dry-run"
        $cur = Get-Egress
        Write-WarpBox @(
            "WAIT FOR EGRESS IP CHANGE (DRY-RUN)",
            "  would wait up to " + $WaitSeconds + "s for VPN/router egress change",
            "  current ip: " + $cur.IP
        ) -Color DarkCyan
        return
    }
    $current = Get-Egress
    $last = Test-ExternalEgressChanged $current
    if ($last) {
        $script:After = $current
        $script:WarpResult = "external"
        Write-WarpBox @(
            "EGRESS ALREADY CHANGED",
            "  old ip: " + $last,
            "  new ip: " + $current.IP,
            "  status: change detected since last run"
        ) -Color Green
        return
    }

    Write-Host ""
    Write-WarpBox @(
        "WAITING FOR EGRESS IP CHANGE",
        "  current ip: " + $current.IP,
        "  action:     switch your VPN or reconnect your router now",
        "  window:     up to " + $WaitSeconds + " seconds"
    ) -Color Yellow
    Write-Host ""

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $elapsed = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $elapsed += 3
        $now = Get-Egress
        if ($now.IP -and $now.IP -ne $current.IP) {
            $script:After = $now
            $script:WarpResult = "external"
            Write-Host ""
            Write-WarpBox @(
                "EGRESS IP CHANGED",
                "  old ip: " + $current.IP,
                "  new ip: " + $now.IP,
                "  waited: " + $elapsed + " seconds"
            ) -Color Green
            return
        }
        $pct = [int]($elapsed / $WaitSeconds * 100)
        if ($pct -gt 100) { $pct = 100 }
        $filled = [int]($elapsed / $WaitSeconds * 20)
        if ($filled -gt 20) { $filled = 20 }
        $bar = ("#" * $filled) + ("." * (20 - $filled))
        Write-Host ("    * waiting for ip change [" + $bar + "] " + $pct.ToString("D3") + "%  elapsed: " + $elapsed + "s  current: " + $now.IP) -NoNewline -ForegroundColor DarkGray
        Write-Host "`r" -NoNewline
    }
    Write-Host ""

    $script:After = Get-Egress
    $script:WarpResult = "unchanged"
    Write-WarpBox @(
        "EGRESS DID NOT CHANGE",
        "  waited:   " + $WaitSeconds + " seconds",
        "  ip stayed:" + $script:After.IP,
        "  action:   switch the VPN/router, then rerun: .\Reset-OpenCode.ps1 -Wait"
    ) -Color Red
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Identity rotation
# ---------------------------------------------------------------------------
function Reset-Identity {
    if ($DryRun) {
        $mode = if ($script:InsideOpenCode -and -not $ForceInside) { "id" } else { "reset" }
        Write-Info ("dry-run: would run opencode-unlimited " + $mode + " " + $Project)
        return
    }

    $identityOnly = $script:InsideOpenCode -and -not $ForceInside
    $toolArgs = @($(if ($identityOnly) { "id" } else { "reset" }))
    if ($Project) { $toolArgs += $Project }

    if ($identityOnly) {
        Write-Info "inside OpenCode: identity-only mode (avoids a service restart)"
        Write-Info "for stuck-error cleanup, run Reset-OpenCode.cmd from Explorer"
    }

    Write-Info ("running: opencode-unlimited " + ($toolArgs -join " "))
    $out = Invoke-Unlimited $toolArgs

    $lines = $out -split "`r?`n"
    $filtered = $lines | Where-Object {
        $_.Trim() -ne "" -and
        $_ -notmatch '\[3/4\]' -and
        $_ -notmatch '\[4/4\]' -and
        $_ -notmatch 'egress ip' -and
        $_ -notmatch 'ip unchanged' -and
        $_ -notmatch 'direct api probe' -and
        $_ -notmatch 'UNKNOWN' -and
        $_ -notmatch 'could not read the gate' -and
        $_ -notmatch 'a prompt that works'
    }
    foreach ($line in $filtered) { Write-Host $line }

    $match = [regex]::Match($out, 'project id:\s*([0-9a-fA-F]{40})')
    if ($match.Success) {
        $script:ProjectId = $match.Groups[1].Value
    }

    $identity = Get-Identity
    if ($identity) {
        if (-not $script:ProjectId -and $identity.projectId) {
            $script:ProjectId = [string]$identity.projectId
        }
        if ($identity.directory) { $script:IdentityDir = [string]$identity.directory }
    }

    if ($script:ProjectId) {
        Write-Ok ("project id: " + $script:ProjectId)
    } else {
        Write-Warn2 "could not read the new project id from the tool output or identity.json"
    }
}

function Apply-ProxyChoice {
    if ($Direct -and $Proxy) {
        Write-Err2 "-Direct and -Proxy cannot be used together"
        return
    }

    if (($Direct -or $Proxy) -and $script:InsideOpenCode -and -not $ForceInside) {
        Write-Warn2 "proxy change skipped inside OpenCode because it restarts the service"
        Write-Info "run Reset-OpenCode.cmd from Explorer, or add -ForceInside"
        return
    }

    if ($Direct) {
        if ($DryRun) {
            Write-Info "dry-run: would clear the configured proxy"
        } else {
            $out = Invoke-Unlimited @("proxy", "off")
            if ($out -match "direct") { Write-Ok "proxy cleared; direct egress" }
            else { Write-Warn2 "proxy-off returned an unexpected result" }
        }
        $script:ProxyResult = "direct"
    } elseif ($Proxy) {
        if ($Proxy -notmatch '^(socks5h?|http|https)://') {
            Write-Err2 "proxy must start with socks5://, socks5h://, http:// or https://"
            return
        }
        if ($DryRun) {
            Write-Info ("dry-run: would set proxy " + $Proxy)
        } else {
            $out = Invoke-Unlimited @("proxy", "set", $Proxy)
            if ($out -match "proxy set|reachable") { Write-Ok ("proxy set: " + $Proxy) }
            else { Write-Warn2 "proxy set returned an unexpected result" }
        }
        $script:ProxyResult = $Proxy
    }
}

# ---------------------------------------------------------------------------
# Token/context zeroing
# ---------------------------------------------------------------------------
function Invoke-TokenZero {
    if ($NoZeroTokens) {
        Write-Info "token/context zeroing disabled by -NoZeroTokens"
        $script:TokenResult = [pscustomobject]@{ ok = $true; skipped = $true }
        return
    }
    if (-not $script:Python) {
        Write-Warn2 "python not found; token/context zeroing skipped"
        Write-Info "install Python, or rerun with -NoZeroTokens"
        $script:TokenResult = [pscustomobject]@{ ok = $false; error = "python not found" }
        return
    }
    if (-not (Test-Path -LiteralPath $script:TokenHelper)) {
        Write-Warn2 ("token helper missing: " + $script:TokenHelper)
        $script:TokenResult = [pscustomobject]@{ ok = $false; error = "helper missing" }
        return
    }
    if (-not (Test-Path -LiteralPath $script:DbPath)) {
        Write-Warn2 ("OpenCode database missing: " + $script:DbPath)
        $script:TokenResult = [pscustomobject]@{ ok = $false; error = "database missing" }
        return
    }

    $target = if ($Project) { $Project } else { $script:Cwd }
    $pyArgs = @($script:TokenHelper, "--db", $script:DbPath, "--json")
    if ($ZeroAllSessions) {
        $pyArgs += "--all"
        Write-Info "scope: every session in opencode.db"
    } else {
        $pyArgs += @("--project", $target)
        Write-Info ("scope: " + $target)
    }
    if ($DryRun) { $pyArgs += "--dry-run" }

    if ($script:InsideOpenCode -and -not $ForceInside) {
        Write-Warn2 "OpenCode is still running; the database is updated live"
        Write-Info "reload the app after this run to see the zeroed context"
    }

    $out = Invoke-Native $script:Python $pyArgs
    $jsonLine = ($out -split "`r?`n" | Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1)
    if (-not $jsonLine) {
        Write-Warn2 "token helper did not return JSON"
        $preview = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 6) -join " "
        if ($preview) { Write-Info $preview }
        $script:TokenResult = [pscustomobject]@{ ok = $false; error = "helper returned no JSON" }
        return
    }

    try {
        $result = $jsonLine | ConvertFrom-Json
    } catch {
        Write-Warn2 ("could not parse token helper output: " + $_.Exception.Message)
        $script:TokenResult = [pscustomobject]@{ ok = $false; error = "invalid helper output" }
        return
    }

    $script:TokenResult = $result
    if (-not $result.ok) {
        Write-Warn2 ("token/context zeroing failed: " + $result.error)
        [void]$script:Errors.Add("token/context zeroing failed: " + $result.error)
        return
    }

    if ($DryRun) {
        Write-Info ("dry-run: would zero " + $result.sessions + " session(s) and " + $result.message_usage_rows + " message usage row(s)")
        if ($result.scope -eq "all") { Write-Info "scope: all sessions" }
        return
    }

    Write-Ok ("zeroed " + $result.sessions + " session(s), " + $result.zeroed_message_rows + " message usage row(s)")
    if ($result.backup) { Write-Info ("database backup: " + $result.backup) }
    if ($result.PSObject.Properties["remaining_message_usage_rows"] -and [int]$result.remaining_message_usage_rows -ne 0) {
        Write-Warn2 ("verification found " + $result.remaining_message_usage_rows + " message row(s) still carrying usage")
    } else {
        Write-Info "verified: session counters and message usage are all zero"
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
function Get-TokenSummaryLabel {
    if ($NoZeroTokens) { return "kept (-NoZeroTokens)" }
    if (-not $script:TokenResult) { return "not run" }
    if ($script:TokenResult.PSObject.Properties["skipped"] -and $script:TokenResult.skipped) {
        return "kept (helper unavailable)"
    }
    if ($script:TokenResult.PSObject.Properties["dry_run"] -and $script:TokenResult.dry_run) {
        return ("dry-run: would zero " + $script:TokenResult.sessions + " session(s), " + $script:TokenResult.message_usage_rows + " message row(s)")
    }
    if ($script:TokenResult.ok) {
        $label = "zeroed " + $script:TokenResult.sessions + " session(s), " + $script:TokenResult.zeroed_message_rows + " message row(s)"
        if ($script:TokenResult.PSObject.Properties["remaining_message_usage_rows"] -and [int]$script:TokenResult.remaining_message_usage_rows -eq 0) {
            $label += " (verified)"
        }
        return $label
    }
    return ("failed: " + $script:TokenResult.error)
}

function Get-EgressModeLabel {
    switch ($script:WarpResult) {
        "rotated"   { return "WARP rotated" }
        "external"  { return "external change detected" }
        "unchanged" { return "unchanged" }
        "skipped"   { return "not changed (external)" }
        "dry-run"   { return "dry-run" }
        default     { return $script:WarpResult }
    }
}

function Show-Summary {
    if (-not $DryRun -and $script:After -and $script:After.IP) {
        Save-LastIp $script:After.IP
    }
    $beforeIp = if ($script:Before) { $script:Before.IP } else { "?" }
    $beforeWarp = if ($script:Before) { $script:Before.Warp } else { "?" }
    $afterIp = if ($script:After -and $script:After.IP) { $script:After.IP } else { $beforeIp }
    $afterWarp = if ($script:After -and $script:After.Warp) { $script:After.Warp } else { $beforeWarp }

    $ipChanged = ($beforeIp -and $afterIp -and $beforeIp -ne $afterIp)
    if (-not $ipChanged -and $script:BaselineIp -and $afterIp -and $script:BaselineIp -ne $afterIp) {
        $ipChanged = $true
    }
    $identityOk = [bool]$script:ProjectId
    $tokensOk = $NoZeroTokens -or $DryRun -or ($script:TokenResult -and $script:TokenResult.ok)

    $result = "PARTIAL"
    if ($DryRun) {
        $result = "DRY RUN"
    } elseif ($ipChanged -and $identityOk -and $tokensOk) {
        $result = "SUCCESS"
    } elseif ($identityOk -and $tokensOk) {
        $result = "IDENTITY ONLY"
    } elseif (-not $identityOk) {
        $result = "FAILED"
    }

    $serviceStatus = "not checked"
    if ($script:ServiceSkipped) {
        $serviceStatus = "restart skipped"
    } elseif ($DryRun) {
        $serviceStatus = "dry-run"
    } else {
        try {
            $status = Invoke-Native $script:OpenCode @("service", "status")
            if ($status -match 'https?://|127\.0\.0\.1:\d+') { $serviceStatus = $status.Trim() } else { $serviceStatus = "not running" }
        } catch { $serviceStatus = "unknown" }
    }

    Write-Host ""
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
    Write-Host " RESET SUMMARY" -ForegroundColor Cyan
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
    if ($script:BaselineIp -and $script:BaselineIp -ne $beforeIp) {
        Write-Host ("  egress previous: " + $script:BaselineIp + "  (changed before this run)")
    }
    Write-Host ("  egress before : " + $beforeIp + "  (warp=" + $beforeWarp + ")")
    Write-Host ("  egress after  : " + $afterIp + "  (warp=" + $afterWarp + ")")
    Write-Host ("  egress mode   : " + (Get-EgressModeLabel))
    Write-Host ("  proxy         : " + $script:ProxyResult)
    Write-Host ("  project id    : " + $(if ($script:ProjectId) { $script:ProjectId } else { "(unchanged)" }))
    if ($script:IdentityDir) { Write-Host ("  directory     : " + $script:IdentityDir) }
    Write-Host ("  tokens/context: " + (Get-TokenSummaryLabel))
    if (-not $DryRun -and $script:TokenResult -and $script:TokenResult.PSObject.Properties["backup"] -and $script:TokenResult.backup) {
        Write-Host ("  db backup     : " + $script:TokenResult.backup)
    }
    Write-Host ("  service       : " + $serviceStatus)
    if ($Freeze -and -not $DryRun) {
        if ($script:FreezeResult) {
            Write-Host ("  freeze        : active (pid " + $script:FreezeResult.pid + ", " + $script:FreezeResult.scope + ")") -ForegroundColor Green
        } else {
            Write-Host "  freeze        : not started (see issues)" -ForegroundColor Yellow
        }
    }
    if ($Loop -and -not $DryRun) {
        if ($script:LoopResult) {
            Write-Host ("  loop          : active (pid " + $script:LoopResult.pid + ", every " + $script:LoopResult.interval + "s, " + $script:LoopResult.scope + ")") -ForegroundColor Green
        } else {
            Write-Host "  loop          : not started (see issues)" -ForegroundColor Yellow
        }
    }
    if ($script:InsideOpenCode -and -not $ForceInside) {
        Write-Host "  note          : inside OpenCode -> identity-only; stuck errors not cleared" -ForegroundColor Yellow
        if (-not $NoZeroTokens -and $script:TokenResult -and $script:TokenResult.ok) {
            Write-Host "                  reload OpenCode to see the zeroed context." -ForegroundColor Yellow
        }
    }
    Write-Host ("  result        : " + $result) -ForegroundColor $(if ($result -eq "SUCCESS") { "Green" } elseif ($result -eq "FAILED") { "Red" } else { "Yellow" })
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
    Write-Host ("  log           : " + $script:LogFile) -ForegroundColor DarkGray
    Write-Host "  reseter by Abdullah Fadil" -ForegroundColor DarkCyan

    if ($script:Errors.Count -gt 0) {
        Write-Host ""
        Write-Host "  issues:" -ForegroundColor Yellow
        foreach ($err in $script:Errors) { Write-Host ("   - " + $err) -ForegroundColor Yellow }
    }

    Write-Host ""
    if ($result -eq "DRY RUN") {
        Write-Host "  next: rerun without -DryRun to apply the reset." -ForegroundColor Gray
    } elseif ($result -eq "SUCCESS") {
        Write-Host "  next: send a prompt. If it still says the free limit is reached," -ForegroundColor Gray
        Write-Host "        run: .\Reset-OpenCode.ps1 -LiveTest" -ForegroundColor Gray
    } elseif ($result -eq "IDENTITY ONLY") {
        Write-Host "  next: egress unchanged. Switch VPN/router and rerun with -Wait." -ForegroundColor Gray
        Write-Host "        The identity is fresh, so a prompt may already work." -ForegroundColor Gray
    } elseif ($result -eq "FAILED") {
        Write-Host "  next: check the log. Switch VPN/router or use -Warp / -Proxy." -ForegroundColor Gray
    } else {
        Write-Host "  next: check the log, then run: .\Reset-OpenCode.ps1 -LiveTest" -ForegroundColor Gray
    }
    if ($result -ne "DRY RUN" -and -not $NoZeroTokens -and $script:TokenResult -and $script:TokenResult.ok) {
        Write-Host "  tokens: stored context is 0; history and message text were kept." -ForegroundColor Gray
        Write-Host "          a new prompt in this chat will add its own usage again." -ForegroundColor Gray
    }
    Write-Host ""

    if ($result -eq "DRY RUN") { return 0 }
    if ($result -eq "SUCCESS") { return 0 }
    if ($result -eq "FAILED") { return 1 }
    return 2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if ($PSBoundParameters.ContainsKey("FreezeMinutes")) { $Freeze = $true }
if ($FreezeOnly) { $Freeze = $true }
if ($Freeze -and $Unfreeze) {
    Write-Err2 "-Freeze and -Unfreeze cannot be used together"
    exit 1
}
if ($Freeze -and $NoZeroTokens) {
    Write-Err2 "-Freeze keeps counters at zero, so it cannot be combined with -NoZeroTokens"
    exit 1
}
if ($Unfreeze) {
    $stopped = Stop-Freeze
    if ($stopped) {
        Write-Ok "freeze stopped; counters will record normally again"
    } else {
        Write-Info "no active freeze process"
    }
    exit 0
}

if ($StopLoop) {
    $stopped = Stop-Loop
    if ($stopped) {
        Write-Ok "loop watcher stopped; counters will record normally again"
    } else {
        Write-Info "no active loop watcher"
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Auto-cycle: unfreeze -> wait-for-ip -> reset -> freeze -> live-test
# ---------------------------------------------------------------------------
if ($AutoCycle) {
    $Wait = $true
    $Freeze = $true
    $LiveTest = $true
    $FreezeMinutes = 0
    if (Stop-Freeze) {
        Write-Ok "previous freeze stopped; auto-cycle will pin counters at 0 again"
    } else {
        Write-Info "no active freeze to stop"
    }
}

Show-Credits
Write-Host "  OpenCode one-click reset" -ForegroundColor Cyan
Write-Host "  process order -> config -> egress -> identity -> tokens -> restart" -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $script:ConfigDir)) {
    Write-Err2 ("OpenCode config folder not found: " + $script:ConfigDir)
    Write-Info "start OpenCode once, then rerun this script"
    exit 1
}

$pf86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
$script:OpenCode = Resolve-Tool -Name "opencode" -Candidates @(
    (Join-Path $env:LOCALAPPDATA "OpenCode\bin\opencode.cmd"),
    (Join-Path $env:APPDATA "npm\opencode.cmd")
)
$unlimitedCmd = Resolve-Tool -Name "opencode-unlimited" -Candidates @(
    (Join-Path $env:USERPROFILE "Desktop\Opencode Niggfy\bin\opencode-unlimited.cmd"),
    (Join-Path $env:USERPROFILE "Desktop\OpenCode-Unlimited\bin\opencode-unlimited.cmd")
)
$script:WarpCli = Resolve-Tool -Name "warp-cli" -Candidates @(
    (Join-Path $env:ProgramFiles "Cloudflare\Cloudflare WARP\warp-cli.exe"),
    $(if ($pf86) { Join-Path $pf86 "Cloudflare\Cloudflare WARP\warp-cli.exe" } else { "" })
)
$script:Python = Resolve-Python

if ($FreezeOnly) {
    if (-not $script:Python) {
        Write-Err2 "python not found; freeze mode needs it"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $script:TokenHelper)) {
        Write-Err2 ("token helper missing: " + $script:TokenHelper)
        exit 1
    }
    if (-not (Test-Path -LiteralPath $script:DbPath)) {
        Write-Err2 ("OpenCode database missing: " + $script:DbPath)
        exit 1
    }
    if ($DryRun) {
        Write-Info "dry-run: would start the freeze helper and keep counters at 0"
        exit 0
    }
    Start-Freeze
    if ($script:FreezeResult) { exit 0 }
    exit 1
}

if ($Loop) {
    if (-not $script:Python) {
        Write-Err2 "python not found; loop mode needs it"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $script:TokenHelper)) {
        Write-Err2 ("token helper missing: " + $script:TokenHelper)
        exit 1
    }
    if (-not (Test-Path -LiteralPath $script:DbPath)) {
        Write-Err2 ("OpenCode database missing: " + $script:DbPath)
        exit 1
    }
    if ($DryRun) {
        Write-Info "dry-run: would start the loop watcher and keep counters at 0 every " + $LoopSeconds + "s"
        exit 0
    }
    Start-Loop
    if ($script:LoopResult) { exit 0 }
    exit 1
}

if ($unlimitedCmd) {
    $candidate = $unlimitedCmd -replace '\.(cmd|bat)$', '.ps1'
    if (Test-Path -LiteralPath $candidate) { $script:UnlimitedPs1 = $candidate }
    if (-not $script:UnlimitedPs1) {
        $sibling = Join-Path (Split-Path -Parent $unlimitedCmd) "opencode-unlimited.ps1"
        if (Test-Path -LiteralPath $sibling) { $script:UnlimitedPs1 = $sibling }
    }
}

$missing = @()
if (-not $script:OpenCode)     { $missing += "opencode" }
if (-not $script:UnlimitedPs1) { $missing += "opencode-unlimited.ps1" }
if ($Warp -and -not $script:WarpCli) { $missing += "warp-cli" }
if (-not $NoZeroTokens) {
    if (-not $script:Python) { $missing += "python" }
    if (-not (Test-Path -LiteralPath $script:TokenHelper)) { $missing += "Zero-OpenCodeTokens.py" }
}
if ($missing.Count -gt 0) {
    Write-Err2 ("missing required tool(s): " + ($missing -join ", "))
    if ($missing -contains "opencode-unlimited.ps1") {
        Write-Info "install it first: powershell -ExecutionPolicy Bypass -File `"$env:USERPROFILE\Desktop\Opencode Niggfy\install.ps1`""
    }
    if ($missing -contains "python" -or $missing -contains "Zero-OpenCodeTokens.py") {
        Write-Info "install Python, or rerun with -NoZeroTokens to skip token/context zeroing"
    }
    exit 1
}

$script:InsideOpenCode = Test-InsideOpenCode
$script:Before = Get-Egress
$script:BaselineIp = Get-LastIp

if ($Warp -and $Proxy) {
    Write-Err2 "-Warp and -Proxy cannot be used together"
    exit 1
}
if ($ZeroTokens -and $NoZeroTokens) {
    Write-Err2 "-ZeroTokens and -NoZeroTokens cannot be used together"
    exit 1
}
$doWarp = $Warp -and (-not $SkipWarp) -and (-not $Proxy)
$doWait = ($Wait -or $PSBoundParameters.ContainsKey("WaitSeconds")) -and (-not $NoWait)

$egressPlanLabel = if ($doWarp) { "WARP (delete registration -> new registration -> mode warp -> connect -> verify ip)" } elseif ($doWait) { "external (wait for VPN/router change)" } else { "external (verify only)" }
$tokenPlanLabel = if ($NoZeroTokens) {
    "keep token/context counters (-NoZeroTokens)"
} elseif ($ZeroAllSessions) {
    "zero token/context counters for every session (backup first)"
} else {
    "zero token/context counters for this project (backup first)"
}

Write-Host ""
$serviceSkipNote = if ($script:InsideOpenCode) { "  [skipped: inside OpenCode]" } else { "" }

Write-WarpBox @(
    "RESET PIPELINE PLAN (7 stages)",
    "  1. stop bridge / oplire / OpenCode service" + $serviceSkipNote,
    "  2. repair plugin + slash-command config",
    ("  3. rotate egress: " + $egressPlanLabel),
    "  4. rotate project identity + clear stuck limit errors",
    ("  5. " + $tokenPlanLabel),
    "  6. restart OpenCode service",
    "  7. verify egress, identity, and zeroed counters"
) -Color DarkCyan

if ($Freeze) {
    $freezePlan = if ($FreezeMinutes -gt 0) { "freeze counters at 0 for " + $FreezeMinutes + " minute(s)" } else { "freeze counters at 0 until -Unfreeze" }
    Write-Host ("   + " + $freezePlan + " (old chat keeps working)") -ForegroundColor Gray
}
if ($Loop) {
    Write-Host ("   + loop counters at 0 every " + $LoopSeconds + "s (no service stop, no identity rotation)") -ForegroundColor Gray
}
if ($AutoCycle -and $LiveTest) {
    Write-Host ("   +   run live model check (opencode-unlimited test -live)") -ForegroundColor Gray
}
Write-Host ""
$projectLabel = if ($Project) { $Project } else { "current folder (" + $script:Root + ")" }

Write-WarpBox @(
    "CURRENT STATE",
    "  egress ip : " + $script:Before.IP + "  (warp=" + $script:Before.Warp + ")",
    "  warp mode : " + (Get-WarpModeLine),
    "  project   : " + $projectLabel
) -Color DarkGray
Write-Host ""
if ($script:InsideOpenCode) {
    Write-Host "  note          : running inside OpenCode, so the service will not be stopped." -ForegroundColor Yellow
}
Write-Host ""

if (-not $Yes -and -not $DryRun) {
    Write-Host "  starting in 3 seconds (Ctrl+C to cancel)..." -ForegroundColor Yellow
    for ($i = 3; $i -ge 1; $i--) {
        Write-Host ("   " + $i) -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
}

$exitCode = 2
try {
    Write-Step "[1/7] stopping running processes (ordered)"
    Stop-Bridge
    Stop-Oplire
    Stop-OpenCodeService

    Write-Step "[2/7] config"
    Repair-Config

    Write-Step "[3/7] egress"
    if ($doWarp) {
        Reset-WarpEgress
    } elseif ($doWait) {
        Wait-ExternalEgress
    } else {
        Read-ExternalEgress
    }

    Write-Step "[4/7] project identity"
    Reset-Identity
    Apply-ProxyChoice

    Write-Step "[5/7] token/context counters"
    Invoke-TokenZero
    if ($Freeze) {
        if ($DryRun) {
            Write-Info "dry-run: would keep counters at 0 (freeze) after the reset"
        } else {
            Start-Freeze
        }
    }
    if ($Loop) {
        if ($DryRun) {
            Write-Info "dry-run: would keep counters at 0 (loop) every " + $LoopSeconds + "s after the reset"
        } else {
            Start-Loop
        }
    }

    Write-Step "[6/7] restart"
    Start-OpenCodeService

    Write-Step "[7/7] verify"
    if (-not $DryRun) {
        $script:After = Get-Egress
        Write-Info ("egress now: " + $script:After.IP + " (warp=" + $script:After.Warp + ")")
    }
    if ($LiveTest -and -not $DryRun) {
        Write-Info "live check through the app (uses one message)..."
        $live = Invoke-Unlimited @("test", "-live")
        foreach ($line in ($live -split "`r?`n" | Where-Object { $_.Trim() })) { Write-Host $line }
        if ($live -match "WORKING")     { Write-Ok "live check: WORKING" }
        elseif ($live -match "EMPTY")   { Write-Warn2 "live check: EMPTY (still limited on this connection)" }
        else                            { Write-Warn2 "live check: could not confirm" }
    }

    $exitCode = Show-Summary
} catch {
    Write-Err2 ("unexpected error: " + $_.Exception.Message)
    Write-Log ("TRACE: " + $_.ScriptStackTrace)
    $script:After = Get-Egress
    try { Start-OpenCodeService } catch { }
    $exitCode = Show-Summary
} finally {
    # Never leave the background service down because of an early return/error.
    if (-not $DryRun -and -not $script:ServiceSkipped -and $script:ServiceStopped) {
        try { Start-OpenCodeService } catch { }
    }
}

exit $exitCode
