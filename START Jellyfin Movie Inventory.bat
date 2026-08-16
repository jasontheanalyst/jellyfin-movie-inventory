@echo off
setlocal
cd /d "%~dp0"
set "JELLYFIN_APP_DIR=%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -Command "$scriptPath = Join-Path $env:JELLYFIN_APP_DIR 'JellyfinMovieInventory.ps1'; $tokens = $null; $parseErrors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors); if ($parseErrors.Count -gt 0) { foreach ($parseError in $parseErrors) { Write-Host $parseError }; exit 1 }; & $scriptPath"
if errorlevel 1 (
  echo.
  echo The app stopped with an error. Press any key to close this window.
  pause >nul
)
