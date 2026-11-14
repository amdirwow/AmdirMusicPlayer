@echo off
setlocal
cd /d "%~dp0"
for %%I in ("%~dp0..") do set "ADDONS=%%~fI"
set "LIB=%ADDONS%\AmdirMusicLibrary"
set "MUSIC=%LIB%\Music"

echo Amdir Music Player - updating playlist
echo.

rem --- 1. Create the music library folder right away, without PowerShell ---
if not exist "%MUSIC%" mkdir "%MUSIC%"
if not exist "%LIB%\MusicCache" mkdir "%LIB%\MusicCache"
if exist "%LIB%\AmdirMusicLibrary.toc" goto toc_done
> "%LIB%\AmdirMusicLibrary.toc" echo ## Interface: 30300
>> "%LIB%\AmdirMusicLibrary.toc" echo ## Title: Amdir ^|cff6fd3ffMusic Library^|r
>> "%LIB%\AmdirMusicLibrary.toc" echo ## Notes: Your music for Amdir Music Player
>> "%LIB%\AmdirMusicLibrary.toc" echo ## Author: Amdir
>> "%LIB%\AmdirMusicLibrary.toc" echo Playlist.lua
:toc_done
if exist "%LIB%\Playlist.lua" goto playlist_done
> "%LIB%\Playlist.lua" echo AmdirMusicFolders = {}
>> "%LIB%\Playlist.lua" echo AmdirMusicTracks = {}
:playlist_done
if not exist "%MUSIC%\PUT_MUSIC_HERE.txt" > "%MUSIC%\PUT_MUSIC_HERE.txt" echo Put MP3 or OGG files here, subfolders are allowed. Then run UpdatePlaylist.bat again and fully restart WoW.

echo Music folder:
echo   %MUSIC%
echo.

rem --- 2. Any music yet? Also counts music left in the old layout. ---
set "FOUND="
for /r "%MUSIC%" %%F in (*.mp3 *.ogg) do set "FOUND=1"
if exist "%~dp0Music" for /r "%~dp0Music" %%F in (*.mp3 *.ogg) do set "FOUND=1"
if defined FOUND goto build

echo No MP3/OGG files yet. The music folder is opening now.
echo Put your songs there, then run UpdatePlaylist.bat again.
start "" explorer "%MUSIC%"
goto end

rem --- 3. Build the playlist ---
:build
echo Building playlist, please wait...
echo.
cscript.exe //nologo //E:jscript "%~dp0scripts\UpdatePlaylist.js" "%ADDONS%" < nul
if errorlevel 1 goto failed
goto end

:failed
echo.
echo ERROR: Could not update the playlist. Send a screenshot of this window.

:end
echo.
pause
