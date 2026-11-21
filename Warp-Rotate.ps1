#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Cloudflare WARP rotation script - standalone.
    Deletes old registration, creates new one, forces mode warp, connects,
    and verifies egress IP change. No OpenCode dependency.
#>

# Resolve warp-cli path
$pf86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
$warpCandidates = @(
    Join-Path "C:\Program Files" "Cloudflare\Cloudflare WARP\warp-cli.exe"
)
if ($pf86) {
    $warpCandidates += Join-Path $pf86 "Cloudflare\Cloudflare WARP\warp-cli.exe"
}
$warpPath = $warpCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $warpPath) {
    Write-Host "warp-cli not found" -ForegroundColor Red
    exit 1
}

# ===== Step 1: Disconnect current WARP session =====
Write-Host "Disconnecting current WARP session..." -ForegroundColor Yellow
& $warpPath disconnect 2>$null
Start-Sleep -Seconds 2

# ===== Step 2: Force mode warp (fixes DoH-vs-Warp tunnel trap) =====
Write-Host "Forcing mode warp..." -ForegroundColor Yellow
& $warpPath mode warp 2>$null
Start-Sleep -Seconds 1

# ===== Step 3: Delete old WARP registration (fresh device identity) =====
Write-Host "Deleting old WARP registration..." -ForegroundColor Red
$removeResult = & $warpPath registration delete 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Warn2 "Could not delete old registration (may not exist)"
}
Write-Host "Old registration removed" -ForegroundColor Green

# ===== Step 4: Create new WARP registration (fresh device identity) =====
Write-Host "Creating new WARP registration..." -ForegroundColor Green
$newResult = & $warpPath registration new 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Warn2 "Could not create new registration"
    Write-Host "WARP rotation failed at registration step" -ForegroundColor Red
    exit 1
}
Write-Host "New registration created" -ForegroundColor Green

# ===== Step 5: Connect to WARP tunnel =====
Write-Host "Connecting to WARP tunnel..." -ForegroundColor Cyan
& $warpPath connect 2>$null
Start-Sleep -Seconds 12

# ===== Step 6: Verify egress IP change =====
Write-Host "Verifying egress IP change..." -ForegroundColor Cyan
$beforeIP = & ipconfig | Select-String "IPv4 Address" | Select-String "\d+\.\d+\.\d+\.\d" | ForEach-Object { $_.Matches[0].Value } | Select-Object -First 1
if (-not $beforeIP) { $beforeIP = "unknown" }

$verified = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    $afterResult = & ipconfig | Select-String "IPv4 Address" | Select-String "\d+\.\d+\.\d+\.\d" | ForEach-Object { $_.Matches[0].Value } | Select-Object -First 1
    if ($afterResult -and $afterResult -ne $beforeIP) {
        $verified = $true
        break
    }
}

if ($verified) {
    Write-Host "SUCCESS: Egress IP changed from $beforeIP to $afterResult" -ForegroundColor Green
    Write-Host "WARP tunnel is active and routing traffic" -ForegroundColor Green
} else {
    Write-Host "WARNING: IP did not change (may be same ISP prefix)" -ForegroundColor Yellow
    Write-Host "Try: switch VPN/router manually, or use -Proxy" -ForegroundColor Yellow
}