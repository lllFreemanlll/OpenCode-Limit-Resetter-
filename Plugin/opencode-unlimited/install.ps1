#requires -version 5.1

[CmdletBinding()]
param(
    [switch]$NoPath,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$bin = Join-Path $root "bin"
$entry = Join-Path $bin "opencode-unlimited.cmd"
$ps1 = Join-Path $bin "unlimited-core.ps1"
$pluginSrc = Join-Path $root "plugins\unlimited-shield.js"
$bridge = Join-Path $root "lib\proxy-bridge.js"

$userHome = [Environment]::GetFolderPath("UserProfile")
if (-not $userHome) { $userHome = $env:USERPROFILE }
$configDir = Join-Path $userHome ".config\opencode"
$pluginDir = Join-Path $configDir "plugins"
$pluginDst = Join-Path $pluginDir "unlimited-shield.js"

function Ok($t) { Write-Host "  [+] $t" -ForegroundColor Green }
function Bad($t) { Write-Host "  [x] $t" -ForegroundColor Red; if (-not $NoPause) { try { Read-Host "  Press Enter to close" | Out-Null } catch {} }; exit 1 }
function Info($t) { Write-Host "      $t" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "==> opencode-unlimited install" -ForegroundColor Cyan

foreach ($required in @($entry, $ps1, $pluginSrc, $bridge)) {
    if (-not (Test-Path -LiteralPath $required)) { Bad "missing build artifact: $required" }
}
Ok "build artifacts present"

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) { Ok "node $((& $node.Source --version).Trim())" } else { Info "node not found: proxy bridge and -Db rotation stay unavailable" }

if (-not (Test-Path -LiteralPath $pluginDir)) { New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null }
Copy-Item -LiteralPath $pluginSrc -Destination $pluginDst -Force
Ok "plugin deployed: $pluginDst"

if (-not $NoPath) {
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($null -eq $userPath) { $userPath = "" }
    if ($userPath -notlike "*$bin*") {
        $newPath = if ($userPath.Trim()) { $userPath.TrimEnd(";") + ";" + $bin } else { $bin }
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Ok "added to user PATH: $bin"
        Info "open a new terminal to pick it up"
    } else {
        Info "already on user PATH: $bin"
    }
    $currentPath = $env:PATH
    if ($null -eq $currentPath) { $currentPath = "" }
    $env:PATH = $currentPath.TrimEnd(";") + ";" + $bin
}

$shell = Get-Command powershell -ErrorAction SilentlyContinue
if ($shell) {
    & $shell.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ps1 install
}

Write-Host ""
Write-Host "  next:" -ForegroundColor Cyan
Info "opencode-unlimited status     identity, plugin, network, bucket"
Info "opencode-unlimited id         rotate the project id"
Info "opencode-unlimited test       probe the bucket on this IP (free)"
Write-Host ""
Ok "installed"

if ($env:RESETER_LAUNCHER -ne "1" -and -not $NoPause) {
    Write-Host ""
    try { Read-Host "  Press Enter to close this window" | Out-Null } catch { }
}