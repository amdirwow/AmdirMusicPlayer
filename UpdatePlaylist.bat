@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UpdatePlaylist.ps1"
if errorlevel 1 (
    echo.
    echo ERROR: Could not update the playlist.
)
echo.
pause
