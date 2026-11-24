#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Cloudflare WARP rotation script - standalone, portable.
    Deletes old registration, creates new one, forces mode warp, connects,
    and verifies egress IP change. No OpenCode dependency.
#>
[CmdletBinding()]
param(
    [switch]$NoPause,
    [int]$VerifySeconds = 20
)

$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$script:FromLauncher = ($env:RESETER_LAUNCHER -eq "1")

function Wait-BeforeClose {
    if ($script:FromLauncher -or $NoPause) { return }
    try {
        if ($Host.Name -eq "ConsoleHost") {
            Write-Host ""
            Read-Host "  Press Enter to close this window" | Out-Null
        }
    } catch { }
}

trap {
    Write-Host ""
    Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  at line $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    Wait-BeforeClose
    exit 1
}

function Warn-Line { param([string]$Text) Write-Host ("  [!] " + $Text) -ForegroundColor Yellow }

# Resolve warp-cli: PATH first, then the usual install folders.
$pf86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
$candidates = @(
    (Join-Path $env:ProgramFiles "Cloudflare\Cloudflare WARP\warp-cli.exe")
)
if ($pf86) { $candidates += (Join-Path $pf86 "Cloudflare\Cloudflare WARP\warp-cli.exe") }
$found = @(Get-Command "warp-cli.exe" -ErrorAction SilentlyContinue)
if ($found.Count -gt 0 -and $found[0].Source) { $candidates = @($found[0].Source) + $candidates }
$warpPath = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

if (-not $warpPath) {
    Write-Host ""
    Write-Host "  [ERROR] warp-cli not found on this PC." -ForegroundColor Red
    Write-Host "  Install Cloudflare WARP from https://1.1.1.1/ then rerun." -ForegroundColor Yellow
    Wait-BeforeClose
    exit 1
}

Write-Host ""
Write-Host "==> Cloudflare WARP rotation" -ForegroundColor Cyan
Write-Host ("    warp-cli: " + $warpPath) -ForegroundColor DarkGray
Write-Host ""

# ===== Step 1: Disconnect current WARP session =====
Write-Host "  [1/6] disconnecting current WARP session..." -ForegroundColor Yellow
& $warpPath disconnect 2>$null | Out-Null
Start-Sleep -Seconds 2

# ===== Step 2: Force mode warp (fixes DoH-vs-Warp tunnel trap) =====
Write-Host "  [2/6] forcing mode warp..." -ForegroundColor Yellow
& $warpPath mode warp 2>$null | Out-Null
Start-Sleep -Seconds 1

# ===== Step 3: Delete old WARP registration (fresh device identity) =====
Write-Host "  [3/6] deleting old WARP registration..." -ForegroundColor Red
& $warpPath registration delete 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Warn-Line "could not delete old registration (it may not exist yet)" }
Write-Host "  [+] old registration removed" -ForegroundColor Green

# ===== Step 4: Create new WARP registration =====
Write-Host "  [4/6] creating new WARP registration..." -ForegroundColor Green
& $warpPath --accept-tos registration new 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    & $warpPath registration new 2>$null | Out-Null
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [ERROR] WARP rotation failed at registration step" -ForegroundColor Red
    Wait-BeforeClose
    exit 1
}
Write-Host "  [+] new registration created" -ForegroundColor Green

# ===== Step 5: Connect to WARP tunnel =====
Write-Host "  [5/6] connecting to WARP tunnel..." -ForegroundColor Cyan
& $warpPath connect 2>$null | Out-Null
Start-Sleep -Seconds 8

# ===== Step 6: Verify egress IP change =====
Write-Host "  [6/6] verifying egress IP change..." -ForegroundColor Cyan
function Get-Ip {
    try {
        $page = Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing -TimeoutSec 4 -ErrorAction SilentlyContinue
        if ($page -and $page.Content) { return ([string]$page.Content).Trim() }
    } catch { }
    try {
        $page = Invoke-WebRequest -Uri "https://icanhazip.com" -UseBasicParsing -TimeoutSec 4 -ErrorAction SilentlyContinue
        if ($page -and $page.Content) { return ([string]$page.Content).Trim() }
    } catch { }
    return $null
}

$beforeIP = Get-Ip
if (-not $beforeIP) { $beforeIP = "unknown" }

$verified = $false
$afterIP = $null
for ($i = 0; $i -lt $VerifySeconds; $i++) {
    Start-Sleep -Seconds 1
    $afterIP = Get-Ip
    if ($afterIP -and $beforeIP -ne "unknown" -and $afterIP -ne $beforeIP) {
        $verified = $true
        break
    }
}

Write-Host ""
if ($verified) {
    Write-Host "  [+] SUCCESS: egress IP changed" -ForegroundColor Green
    Write-Host ("      old: " + $beforeIP) -ForegroundColor DarkGray
    Write-Host ("      new: " + $afterIP) -ForegroundColor DarkGray
} else {
    Warn-Line "IP did not change (same prefix, WARP down, or offline)"
    Write-Host "      current: $afterIP" -ForegroundColor DarkGray
    Write-Host "      WARP registration was still renewed. Try switching VPN/router." -ForegroundColor Yellow
}

Wait-BeforeClose
exit 0