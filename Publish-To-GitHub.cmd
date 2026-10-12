@echo off
REM ---------------------------------------------------------------------------
REM  Publish Polish to GitHub
REM
REM  Run this once. It will:
REM    1. sign you in to GitHub (opens your browser)
REM    2. create the repository
REM    3. push everything
REM    4. print the one-line command to share with friends
REM
REM  Safe to re-run. If you are already signed in it skips step 1, and if the
REM  repo already exists it just pushes.
REM ---------------------------------------------------------------------------

setlocal
cd /d "%~dp0"

set "GH=%ProgramFiles%\GitHub CLI\gh.exe"
set "GIT=%ProgramFiles%\Git\cmd\git.exe"
set "REPO=Polish-made-by-spandy"
set "DESC=A Windows tune-up and debloat tool that can undo itself"

if not exist "%GH%" (
    echo   GitHub CLI not found at "%GH%"
    echo   Install it with:  winget install GitHub.cli
    pause & exit /b 1
)
if not exist "%GIT%" (
    echo   Git not found at "%GIT%"
    echo   Install it with:  winget install Git.Git
    pause & exit /b 1
)

echo.
echo  ==============================================
echo   Publishing Polish to GitHub
echo  ==============================================
echo.

REM -- 1. sign in ------------------------------------------------------------
"%GH%" auth status >nul 2>&1
if errorlevel 1 (
    echo   [1/4] Signing you in to GitHub.
    echo         Your browser will open. Pick your account and approve.
    echo.
    "%GH%" auth login --web --git-protocol https
    if errorlevel 1 (
        echo.
        echo   Sign-in did not complete. Run this file again when ready.
        pause & exit /b 1
    )
) else (
    echo   [1/4] Already signed in.
)

REM let git reuse the gh credentials so the push does not prompt again
"%GH%" auth setup-git >nul 2>&1

for /f "delims=" %%u in ('"%GH%" api user --jq .login 2^>nul') do set "USER=%%u"
if "%USER%"=="" (
    echo   Could not read your GitHub username. Is the sign-in complete?
    pause & exit /b 1
)
echo         Signed in as: %USER%
echo.

REM -- 2. create the repository ---------------------------------------------
echo   [2/4] Creating repository "%REPO%"
"%GH%" repo view "%USER%/%REPO%" >nul 2>&1
if errorlevel 1 (
    "%GH%" repo create "%REPO%" --public --description "%DESC%" --source=. --remote=origin
    if errorlevel 1 (
        echo         Could not create it. The name may already be taken on your account.
        pause & exit /b 1
    )
    echo         Created.
) else (
    echo         Already exists, reusing it.
    "%GIT%" remote remove origin >nul 2>&1
    "%GIT%" remote add origin "https://github.com/%USER%/%REPO%.git"
)

REM -- 3. push ---------------------------------------------------------------
echo.
echo   [3/4] Pushing
"%GIT%" push -u origin main
if errorlevel 1 (
    echo         Push failed. If it mentions authentication, run this file again.
    pause & exit /b 1
)
echo         Pushed.

REM -- 4. the shareable command ---------------------------------------------
echo.
echo   [4/4] Done.
echo.
echo  ==============================================
echo.
echo   Your repository:
echo     https://github.com/%USER%/%REPO%
echo.
echo   SHARE THIS with your friends. They paste it into
echo   PowerShell running as administrator:
echo.
echo     irm https://raw.githubusercontent.com/%USER%/%REPO%/main/dist/Polish.ps1 ^| iex
echo.
echo  ==============================================
echo.
echo   Copying that command to your clipboard...
powershell -NoProfile -Command "Set-Clipboard -Value ('irm https://raw.githubusercontent.com/%USER%/%REPO%/main/dist/Polish.ps1 | iex')"
echo   Copied. Paste it anywhere to share.
echo.
echo   NOTE: the README and the landing page still say YOUR-USERNAME.
echo   Tell Claude your username is %USER% and it will fix those.
echo.
pause
endlocal
