@echo off
rem ---------------------------------------------------------------------------
rem server.cmd — Windows launcher for the server-manager CLI.
rem
rem The engine is a Bash script that drives OpenSSH (ssh/scp/ControlMaster), so
rem on Windows it runs through Git Bash or WSL — both ship bash + ssh. Put this
rem bin\ directory on your PATH (or run install.ps1) and use `server ...` from
rem cmd or PowerShell exactly like on Linux/macOS.
rem ---------------------------------------------------------------------------
setlocal EnableDelayedExpansion

rem Directory of this launcher, with forward slashes for bash.
set "DIR=%~dp0"
set "UDIR=%DIR:\=/%"
set "SCRIPT=%UDIR%server"

rem 1) bash already on PATH (Git Bash / MSYS2).
where bash >nul 2>nul
if %ERRORLEVEL%==0 (
  bash "%SCRIPT%" %*
  exit /b %ERRORLEVEL%
)

rem 2) Common Git for Windows install locations.
for %%P in (
  "%ProgramFiles%\Git\bin\bash.exe"
  "%ProgramFiles%\Git\usr\bin\bash.exe"
  "%ProgramFiles(x86)%\Git\bin\bash.exe"
  "%LocalAppData%\Programs\Git\bin\bash.exe"
) do (
  if exist "%%~P" (
    "%%~P" "%SCRIPT%" %*
    exit /b !ERRORLEVEL!
  )
)

rem 3) WSL — translate the path and run there.
where wsl >nul 2>nul
if %ERRORLEVEL%==0 (
  for /f "delims=" %%i in ('wsl wslpath "%~dp0server" 2^>nul') do set "WP=%%i"
  if defined WP (
    wsl bash "!WP!" %*
    exit /b !ERRORLEVEL!
  )
)

echo(
echo ============================================================
echo  server-manager requires WSL to run on Windows.
echo(
echo  Install it once (admin PowerShell), then reopen the terminal:
echo      wsl --install
echo(
echo  (Git Bash also works as an alternative.)
echo  More: https://learn.microsoft.com/windows/wsl/install
echo ============================================================
exit /b 1
