Amdir Music Player - Linux / Wine
=================================

1. bash scripts/UpdatePlaylist.sh        (creates ../AmdirMusicLibrary/Music)
2. Put MP3/OGG files (subfolders allowed) into Interface/AddOns/AmdirMusicLibrary/Music/
3. bash scripts/UpdatePlaylist.sh        (builds the playlist; needs only Python 3)
4. Fully restart WoW.

Music from the old layout (AmdirMusicPlayer/Music) is moved to the library automatically.
Originals are never modified. MusicCache holds hard links (or tag-stripped copies of MP3s
with broken ID3 tags). Optional: bash scripts/UpdatePlaylist.sh --convert re-encodes everything
with ffmpeg if some file still stays silent.

See README.md for features and commands.
