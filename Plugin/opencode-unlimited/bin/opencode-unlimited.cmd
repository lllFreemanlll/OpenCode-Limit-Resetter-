@echo off
setlocal
set "SCRIPT=%~dp0unlimited-core.ps1"

if not exist "%SCRIPT%" (
  echo Missing unlimited-core.ps1 next to this wrapper.
  exit /b 1
)

where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%