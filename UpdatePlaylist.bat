@echo off
setlocal
cd /d "%~dp0"
echo Amdir Music Player - updating playlist...
echo Please wait, this can take a minute for large music folders.
echo.
where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: PowerShell was not found on this computer.
    goto end
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\UpdatePlaylist.ps1"
if errorlevel 1 (
    echo.
    echo ERROR: Could not update the playlist. Send a screenshot of this window.
)
:end
echo.
pause
