@echo off
setlocal EnableExtensions
title OpenCode Reseter

set "PS1=%~dp0Reset-OpenCode.ps1"
set "CODE=1"

echo.
echo   RESETER launcher
echo   folder: %~dp0
echo.

if not exist "%PS1%" (
  echo   [ERROR] Missing Reset-OpenCode.ps1 next to this launcher.
  echo   expected: "%PS1%"
  echo.
  echo   Keep Reset-OpenCode.cmd and Reset-OpenCode.ps1 in the same folder.
  goto done
)

rem Let the script know it was started by the launcher so it does not pause twice.
set "RESETER_LAUNCHER=1"

set "ARGS=%*"
if "%ARGS%"=="" set "ARGS=-Interactive -Yes"

where pwsh >nul 2>nul
if not errorlevel 1 (
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARGS%
) else (
  powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARGS%
)
set "CODE=%ERRORLEVEL%"

:done
echo.
if "%CODE%"=="0" (
  echo   [OK] Reset finished.
) else if "%CODE%"=="2" (
  echo   [PARTIAL] Identity-only reset ^(exit code 2^).
  echo   Counters may not be zeroed. For a full reset, close OpenCode
  echo   and double-click this launcher again from Explorer.
) else (
  echo   [ERROR] Reset did not finish. Exit code: %CODE%
  echo   log      : %USERPROFILE%\.config\opencode\resetter.log
  echo   crash log: %USERPROFILE%\.config\opencode\reseter-crash.log
  echo.
  echo   Open the crash log above, or send it to whoever set this up.
)
echo   exit code: %CODE%
echo.

if "%RESETER_NOPAUSE%"=="1" exit /b %CODE%
echo   Press any key to close this window . . .
pause >nul
exit /b %CODE%