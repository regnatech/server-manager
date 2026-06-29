# server.ps1 — PowerShell launcher for the server-manager CLI on Windows.
#
# The engine is a Bash script that drives OpenSSH, so it runs through Git Bash
# or WSL. Use `server ...` from PowerShell once bin\ is on your PATH (install.ps1).
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$script = (Join-Path $dir 'server') -replace '\\', '/'

function Find-Bash {
  $cmd = Get-Command bash -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($p in @(
      "$env:ProgramFiles\Git\bin\bash.exe",
      "$env:ProgramFiles\Git\usr\bin\bash.exe",
      "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
      "$env:LocalAppData\Programs\Git\bin\bash.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

$bash = Find-Bash
if ($bash) {
  & $bash $script @args
  exit $LASTEXITCODE
}

$wsl = Get-Command wsl -ErrorAction SilentlyContinue
if ($wsl) {
  $wp = & wsl wslpath (Join-Path $dir 'server') 2>$null
  if ($wp) {
    & wsl bash $wp @args
    exit $LASTEXITCODE
  }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Yellow
Write-Host ' server-manager requires WSL to run on Windows.' -ForegroundColor Yellow
Write-Host ''
Write-Host ' Install it once (admin PowerShell), then reopen the terminal:'
Write-Host '     wsl --install' -ForegroundColor Cyan
Write-Host ''
Write-Host ' (Git Bash also works as an alternative.)'
Write-Host ' More: https://learn.microsoft.com/windows/wsl/install'
Write-Host '============================================================' -ForegroundColor Yellow
exit 1
