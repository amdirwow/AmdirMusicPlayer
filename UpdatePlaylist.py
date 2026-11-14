#!/usr/bin/env python3
"""Build the Amdir Music Player library for WoW 3.3.5a.

Usage on Linux/Wine: bash UpdatePlaylist.sh [--convert]

Music lives in a separate folder AddOns/AmdirMusicLibrary (Music/, MusicCache/,
Playlist.lua and its own .toc), so updating AmdirMusicPlayer through the
Amdir AddOns Downloader never deletes the user's songs.
The MP3/OGG originals inside Music/ are never modified or deleted.
"""
from pathlib import Path
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import unicodedata

ADDON_DIR = Path(__file__).resolve().parent
LIBRARY_NAME = "AmdirMusicLibrary"
LIBRARY_DIR = ADDON_DIR.parent / LIBRARY_NAME
MUSIC_DIR = LIBRARY_DIR / "Music"
CACHE_DIR = LIBRARY_DIR / "MusicCache"
PLAYLIST_FILE = LIBRARY_DIR / "Playlist.lua"
SUPPORTED = {".mp3", ".ogg"}

LIBRARY_TOC = """## Interface: 30300
## Title: Amdir |cff6fd3ffMusic Library|r
## Notes: Ваша музика для Amdir Music Player. Створюється скриптом UpdatePlaylist.
## Author: Amdir
## Version: 1
Playlist.lua
"""

MUSIC_README = """Put your MP3 or OGG files in this folder (subfolders are supported).
Then run UpdatePlaylist.bat (Windows) or UpdatePlaylist.sh (Linux) in
Interface/AddOns/AmdirMusicPlayer and fully restart WoW.

Покладіть сюди MP3 або OGG (можна в підпапки), запустіть UpdatePlaylist.bat
(Windows) або UpdatePlaylist.sh (Linux) у папці AmdirMusicPlayer і повністю
перезапустіть WoW.
"""


def prepare_library():
    """Create AmdirMusicLibrary and move music from the old in-addon layout."""
    MUSIC_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    (LIBRARY_DIR / (LIBRARY_NAME + ".toc")).write_text(LIBRARY_TOC, encoding="utf-8")
    (MUSIC_DIR / "PUT_MUSIC_HERE.txt").write_text(MUSIC_README, encoding="utf-8")

    old_music = ADDON_DIR / "Music"
    if old_music.is_dir():
        for item in list(old_music.iterdir()):
            if item.name == "PUT_MUSIC_HERE.txt":
                item.unlink()
                continue
            target = MUSIC_DIR / item.name
            if target.exists():
                print("NOT MOVED (already exists in library):", item, file=sys.stderr)
                continue
            print("Moving to library:", item.name)
            shutil.move(str(item), str(target))
        try:
            old_music.rmdir()
        except OSError:
            pass
    old_cache = ADDON_DIR / "MusicCache"
    if old_cache.is_dir():
        shutil.rmtree(old_cache, ignore_errors=True)
    old_playlist = ADDON_DIR / "Playlist.lua"
    if old_playlist.exists():
        old_playlist.unlink()


def mp3_duration(path):
    """Duration by walking MPEG audio frames (works for CBR and VBR)."""
    bitrates = {
        (3, 3): [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
        (3, 2): [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
        (3, 1): [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
        (2, 3): [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
        (2, 2): [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    }
    bitrates[(2, 1)] = bitrates[(2, 2)]
    rates = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}
    data = path.read_bytes()
    pos = id3v2_size(data[:10])
    total = 0.0
    frames = 0
    end = len(data) - 4
    while pos < end:
        if data[pos] != 0xFF or (data[pos + 1] & 0xE0) != 0xE0:
            pos += 1
            continue
        version = (data[pos + 1] >> 3) & 3
        layer = (data[pos + 1] >> 1) & 3
        br_index = data[pos + 2] >> 4
        sr_index = (data[pos + 2] >> 2) & 3
        padding = (data[pos + 2] >> 1) & 1
        if version == 1 or layer == 0 or br_index in (0, 15) or sr_index == 3:
            pos += 1
            continue
        table = bitrates[(3 if version == 3 else 2, layer)]
        bitrate = table[br_index] * 1000
        rate = rates[version][sr_index]
        if layer == 3:  # Layer I
            samples, length = 384, (12 * bitrate // rate + padding) * 4
        else:
            samples = 1152 if (layer == 2 or version == 3) else 576
            length = samples // 8 * bitrate // rate + padding
        if length < 4:
            pos += 1
            continue
        total += samples / rate
        frames += 1
        pos += length
    return round(total, 2) if frames > 10 else 0


def ogg_duration(path):
    data = path.read_bytes()
    start = data.find(b"\x01vorbis")
    last = data.rfind(b"OggS")
    if start < 0 or last < 0:
        return 0
    rate = int.from_bytes(data[start + 12:start + 16], "little")
    granule = int.from_bytes(data[last + 6:last + 14], "little")
    return round(granule / rate, 2) if rate else 0


def lua_string(value):
    return ('"' + value.replace("\\", "\\\\").replace('"', '\\"')
            .replace("\r", "\\r").replace("\n", "\\n")
            .replace("\t", "\\t") + '"')


def duration_seconds(path):
    if not shutil.which("ffprobe"):
        try:
            if path.suffix.lower() == ".mp3":
                return mp3_duration(path)
            return ogg_duration(path)
        except (OSError, ValueError, KeyError, IndexError):
            return 0
    try:
        proc = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
            capture_output=True, text=True, timeout=30, check=False,
        )
        duration = float(proc.stdout.strip())
        if 0 < duration < 86400:
            return round(duration, 2)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return 0


def wow_title(value):
    """WoW fonts lack Latin diacritics (e.g. 'ž'); turn them into plain letters.
    Cyrillic and other scripts are kept unchanged."""
    out = []
    for ch in value:
        if 0x00C0 <= ord(ch) <= 0x024F:
            base = "".join(c for c in unicodedata.normalize("NFKD", ch)
                           if not unicodedata.combining(c))
            out.append(base if base.isascii() and base else ch)
        else:
            out.append(ch)
    return "".join(out)


def id3v2_size(data):
    if len(data) >= 10 and data[:3] == b"ID3":
        s = data[6:10]
        size = (s[0] << 21) | (s[1] << 14) | (s[2] << 7) | s[3]
        return 10 + size + (10 if data[5] & 0x10 else 0)
    return 0


def id3v2_is_broken(path):
    """True when the ID3v2 tag has undecodable / garbage text frames."""
    with open(path, "rb") as stream:
        head = stream.read(10)
        total = id3v2_size(head)
        if not total:
            return False
        data = head + stream.read(total - 10)
    if len(data) < total:
        return True
    version = data[3]
    pos = 10
    while pos + 10 <= total:
        frame_id = data[pos:pos + 4]
        if frame_id == b"\0\0\0\0":
            break
        raw = data[pos + 4:pos + 8]
        if version == 4:
            size = (raw[0] << 21) | (raw[1] << 14) | (raw[2] << 7) | raw[3]
        else:
            size = int.from_bytes(raw, "big")
        if not all(48 <= c <= 57 or 65 <= c <= 90 for c in frame_id):
            return True
        body = data[pos + 10:pos + 10 + size]
        if pos + 10 + size > total:
            return True
        if frame_id[:1] == b"T" and body:
            codec = {0: "latin-1", 1: "utf-16", 2: "utf-16-be", 3: "utf-8"}.get(body[0])
            if codec is None:
                return True
            try:
                text = body[1:].decode(codec).rstrip("\0")
            except UnicodeDecodeError:
                return True
            if any((ord(c) < 32 and c != "\0") or 0xD800 <= ord(c) <= 0xDFFF
                   or ord(c) in (0xFFFD, 0xFFFE, 0xFFFF) for c in text):
                return True
        pos += 10 + size
    return False


def strip_id3v2(src, dest):
    """Copy the file without its leading ID3v2 tag; audio bytes stay identical."""
    with open(src, "rb") as stream:
        skip = id3v2_size(stream.read(10))
        stream.seek(skip)
        with open(dest, "wb") as out:
            shutil.copyfileobj(stream, out)


def convert_compatible(src, dest):
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(src), "-map", "0:a:0", "-map_metadata", "-1",
        "-vn", "-sn", "-dn", "-ac", "2", "-ar", "44100",
        "-c:a", "libmp3lame", "-b:a", "192k", "-write_xing", "0",
        "-id3v2_version", "0", str(dest),
    ]
    proc = subprocess.run(command, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        dest.unlink(missing_ok=True)
        raise RuntimeError(proc.stderr.strip()[-500:] or "ffmpeg failed")


def list_content():
    """Scan every descendant folder; don't follow symlinked directories."""
    folders = []
    songs = []
    for root, dirs, files in os.walk(MUSIC_DIR, followlinks=False):
        dirs.sort(key=str.casefold)
        files.sort(key=str.casefold)
        root_path = Path(root)
        if root_path != MUSIC_DIR:
            folders.append(root_path.relative_to(MUSIC_DIR))
        for filename in files:
            path = root_path / filename
            if path.is_file() and path.suffix.lower() in SUPPORTED:
                songs.append(path)
    folders.sort(key=lambda p: str(p).casefold())
    songs.sort(key=lambda p: str(p.relative_to(MUSIC_DIR)).casefold())
    return folders, songs


def main():
    parser = argparse.ArgumentParser(description="Rebuild Amdir Music Player playlist")
    parser.add_argument("--convert", action="store_true",
                        help="Re-encode every song to old-client-friendly MP3 using ffmpeg")
    args = parser.parse_args()

    if args.convert and not shutil.which("ffmpeg"):
        parser.error("ffmpeg is required for --convert. Install: sudo apt install ffmpeg")

    prepare_library()
    folders, files = list_content()

    # Only touch generated files in MusicCache; never alter user music in Music.
    for old in CACHE_DIR.iterdir():
        if old.is_file() and old.name.startswith("track_") and old.suffix.lower() in SUPPORTED:
            old.unlink()

    lines = [
        "-- Generated by UpdatePlaylist.py. UTF-8 with ASCII-only playback paths.",
        "-- Put any folders/songs in Music/, regenerate, then restart WoW.",
        "AmdirMusicFolders = {",
    ]
    for folder in folders:
        folder_path = folder.as_posix()
        parent = folder.parent.as_posix() if len(folder.parts) > 1 else ""
        lines.append("    { path = " + lua_string(folder_path) + ", parent = "
                     + lua_string(parent) + ", name = " + lua_string(folder.name) + " },")
    lines.extend(["}", "AmdirMusicTracks = {"])

    errors = []
    for index, original in enumerate(files, 1):
        relative = original.relative_to(MUSIC_DIR)
        digest = hashlib.sha256(relative.as_posix().encode("utf-8")).hexdigest()[:10]
        suffix = ".mp3" if args.convert else original.suffix.lower()
        alias = f"track_{index:05d}_{digest}{suffix}"
        prepared = CACHE_DIR / alias
        try:
            if args.convert:
                print(f"Converting {index}/{len(files)}: {relative}", flush=True)
                convert_compatible(original, prepared)
            else:
                if original.suffix.lower() == ".mp3" and id3v2_is_broken(original):
                    print(f"Broken ID3 tag, stripping it: {relative}")
                    strip_id3v2(original, prepared)
                else:
                    try:
                        os.link(original, prepared)
                    except OSError:
                        shutil.copy2(original, prepared)
            duration = duration_seconds(prepared)
            game_path = "Interface\\AddOns\\" + LIBRARY_NAME + "\\MusicCache\\" + alias
            folder = relative.parent.as_posix() if len(relative.parts) > 1 else ""
            lines.append(
                "    { title = " + lua_string(wow_title(original.stem))
                + ", path = " + lua_string(game_path)
                + ", folder = " + lua_string(folder)
                + ", duration = " + str(duration) + " },"
            )
        except (OSError, RuntimeError) as err:
            errors.append((str(relative), str(err)))
    lines.append("}")

    temp = PLAYLIST_FILE.with_name("Playlist.lua.tmp")
    try:
        with temp.open("w", encoding="utf-8", newline="\n") as stream:
            stream.write("\n".join(lines) + "\n")
        temp.replace(PLAYLIST_FILE)
    finally:
        if temp.exists():
            temp.unlink()

    print("\nAmdir Music Player v1.5.0 (Linux/Wine)")
    print(f"Tracks found: {len(files) - len(errors)}")
    print(f"Folders found: {len(folders)}")
    print("Generated safe audio paths in:", CACHE_DIR)
    print("Playlist:", PLAYLIST_FILE)
    if not files:
        print("Add .mp3/.ogg files anywhere inside:", MUSIC_DIR)
    for name, message in errors:
        print("SKIPPED:", name, message, file=sys.stderr)
    if not args.convert:
        print("If a track stays silent, try: bash UpdatePlaylist.sh --convert")
    print("Fully close and RESTART WoW; /reload alone is insufficient for new audio files.")
    return 1 if errors else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print("Playlist generation failed:", exc, file=sys.stderr)
        sys.exit(1)
