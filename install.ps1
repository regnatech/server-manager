# install.ps1 — put the server-manager CLI on your PATH (Windows).
#
#   PS> ./install.ps1
#
# Adds this repo's bin\ to your user PATH so `server` (server.cmd) works from
# any cmd/PowerShell window. The engine runs through Git Bash or WSL.
$ErrorActionPreference = 'Stop'

$bin = Join-Path $PSScriptRoot 'bin'
if (-not (Test-Path (Join-Path $bin 'server.cmd'))) {
  Write-Error "Run this from the server-manager repo root (bin\server.cmd not found)."
  exit 1
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -split ';' -notcontains $bin) {
  [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $bin), 'User')
  Write-Host "Added $bin to your user PATH." -ForegroundColor Green
  Write-Host "Open a NEW terminal, then run:  server help"
} else {
  Write-Host "$bin is already on your PATH."
}

# Check the Bash prerequisite.
$hasBash = (Get-Command bash -ErrorAction SilentlyContinue) -or
           (Test-Path "$env:ProgramFiles\Git\bin\bash.exe") -or
           (Get-Command wsl -ErrorAction SilentlyContinue)
if (-not $hasBash) {
  Write-Host ''
  Write-Host '  !! WSL is required to run server-manager on Windows.' -ForegroundColor Yellow
  Write-Host '     Install it (admin PowerShell):  wsl --install' -ForegroundColor Cyan
  Write-Host '     (Git Bash also works as an alternative.)'
} else {
  Write-Host "Bash backend detected." -ForegroundColor Green
}
