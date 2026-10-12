@echo off
REM ---------------------------------------------------------------------------
REM  Polish launcher
REM
REM  Double-click this to open Polish. It asks for administrator once, because
REM  without it Polish cannot create a system restore point and has to skip the
REM  actions marked (admin).
REM
REM  Pass arguments through if you want the command line, e.g.
REM     Polish.cmd -List
REM     Polish.cmd -Preset safe -DryRun
REM ---------------------------------------------------------------------------

setlocal
set "SCRIPT=%~dp0dist\Polish.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo   Could not find dist\Polish.ps1 next to this launcher.
    echo   Expected it at: %SCRIPT%
    echo.
    echo   If you are running from the source repo, build it first:
    echo     powershell -ExecutionPolicy Bypass -File "%~dp0build\Build-SingleFile.ps1"
    echo.
    pause
    exit /b 1
)

REM Already elevated? Run directly. -STA is required for the WPF window.
net session >nul 2>&1
if %errorlevel% equ 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%" %*
    exit /b %errorlevel%
)

REM Not elevated: relaunch this launcher through the UAC prompt.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"

endlocal
