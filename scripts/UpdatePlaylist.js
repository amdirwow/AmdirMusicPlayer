// Amdir Music Player - Windows playlist builder (JScript, runs with the built-in cscript).
// Usage (called by UpdatePlaylist.bat): cscript //nologo //E:jscript UpdatePlaylist.js "<AddOns dir>"
// Music lives in AddOns\AmdirMusicLibrary, so addon updates never delete it.

function main() {
var fso = new ActiveXObject("Scripting.FileSystemObject");
var addonsDir = WScript.Arguments.length > 0 ? WScript.Arguments(0)
    : fso.GetParentFolderName(fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName)));
addonsDir = fso.GetAbsolutePathName(addonsDir);
var playerDir = fso.BuildPath(addonsDir, "AmdirMusicPlayer");
var libDir = fso.BuildPath(addonsDir, "AmdirMusicLibrary");
var musicDir = fso.BuildPath(libDir, "Music");
var cacheDir = fso.BuildPath(libDir, "MusicCache");
var playlistFile = fso.BuildPath(libDir, "Playlist.lua");

function log(s) { WScript.Echo(s); }
function ensureDir(p) { if (!fso.FolderExists(p)) fso.CreateFolder(p); }

ensureDir(libDir);
ensureDir(musicDir);
ensureDir(cacheDir);

// --- Move music from the old layout (AmdirMusicPlayer\Music) -------------
var oldMusic = fso.BuildPath(playerDir, "Music");
if (fso.FolderExists(oldMusic)) {
    var old = fso.GetFolder(oldMusic);
    var e;
    for (e = new Enumerator(old.SubFolders); !e.atEnd(); e.moveNext()) {
        var f = e.item();
        var t = fso.BuildPath(musicDir, f.Name);
        if (fso.FolderExists(t)) { log("NOT MOVED (already exists): " + f.Name); continue; }
        log("Moving folder to library: " + f.Name);
        fso.MoveFolder(f.Path, t);
    }
    for (e = new Enumerator(old.Files); !e.atEnd(); e.moveNext()) {
        var file = e.item();
        if (file.Name == "PUT_MUSIC_HERE.txt") continue;
        var tf = fso.BuildPath(musicDir, file.Name);
        if (fso.FileExists(tf)) { log("NOT MOVED (already exists): " + file.Name); continue; }
        fso.MoveFile(file.Path, tf);
    }
}

// --- Collect folders and songs ---------------------------------------------
var folders = [], songs = [];
function walk(folder, rel) {
    var e;
    for (e = new Enumerator(folder.SubFolders); !e.atEnd(); e.moveNext()) {
        var sub = e.item();
        var subRel = rel == "" ? sub.Name : rel + "/" + sub.Name;
        folders.push({ rel: subRel, name: sub.Name, parent: rel });
        walk(sub, subRel);
    }
    for (e = new Enumerator(folder.Files); !e.atEnd(); e.moveNext()) {
        var file = e.item();
        var ext = fso.GetExtensionName(file.Name).toLowerCase();
        if (ext != "mp3" && ext != "ogg") continue;
        songs.push({
            path: file.Path, dir: folder.Path, fileName: file.Name, ext: ext,
            rel: rel == "" ? file.Name : rel + "/" + file.Name,
            folder: rel, title: fso.GetBaseName(file.Name)
        });
    }
}
walk(fso.GetFolder(musicDir), "");
function byRel(a, b) {
    var x = a.rel.toLowerCase(), y = b.rel.toLowerCase();
    return x < y ? -1 : (x > y ? 1 : 0);
}
folders.sort(byRel);
songs.sort(byRel);
log("Found songs: " + songs.length + ", folders: " + folders.length);

// --- Remove old generated cache files (only our own track_* files) ---------
for (var ce = new Enumerator(fso.GetFolder(cacheDir).Files); !ce.atEnd(); ce.moveNext()) {
    var cf = ce.item();
    if (/^track_.*\.(mp3|ogg)$/i.test(cf.Name)) {
        try { cf.Delete(true); } catch (err) { log("Cannot delete " + cf.Name + ": " + err.message); }
    }
}

// --- Helpers ------------------------------------------------------------------
function pad5(n) { var s = "" + n; while (s.length < 5) s = "0" + s; return s; }

// Lua string literal in pure ASCII: non-ASCII text becomes UTF-8 bytes as \ddd
// escapes (Lua 5.1 decimal escapes), so no UTF-8 file writer is needed.
function luaString(s) {
    var out = '"';
    for (var i = 0; i < s.length; i++) {
        var c = s.charCodeAt(i);
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
            var lo = s.charCodeAt(i + 1);
            if (lo >= 0xDC00 && lo <= 0xDFFF) { c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00); i++; }
        }
        if (c == 92) out += "\\\\";
        else if (c == 34) out += '\\"';
        else if (c >= 32 && c < 127) out += String.fromCharCode(c);
        else if (c < 128) out += "\\" + c;
        else {
            var bytes;
            if (c < 0x800) bytes = [0xC0 | (c >> 6), 0x80 | (c & 63)];
            else if (c < 0x10000) bytes = [0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)];
            else bytes = [0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)];
            for (var b = 0; b < bytes.length; b++) out += "\\" + bytes[b];
        }
    }
    return out + '"';
}

// WoW fonts lack Latin diacritics (e.g. z with caron): map them to plain letters.
// Latin letters with diacritics, as char codes (built at runtime).
var DIACRITIC_CODES = {
    "A": [0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x0100, 0x0102, 0x0104, 0x01CD, 0x01DE, 0x01E0, 0x01FA, 0x0200, 0x0202, 0x0226],
    "C": [0x00C7, 0x0106, 0x0108, 0x010A, 0x010C],
    "D": [0x010E],
    "E": [0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x0112, 0x0114, 0x0116, 0x0118, 0x011A, 0x0204, 0x0206, 0x0228],
    "G": [0x011C, 0x011E, 0x0120, 0x0122, 0x01E6, 0x01F4],
    "H": [0x0124, 0x021E],
    "I": [0x00CC, 0x00CD, 0x00CE, 0x00CF, 0x0128, 0x012A, 0x012C, 0x012E, 0x0130, 0x01CF, 0x0208, 0x020A],
    "J": [0x0134],
    "K": [0x0136, 0x01E8],
    "L": [0x0139, 0x013B, 0x013D],
    "N": [0x00D1, 0x0143, 0x0145, 0x0147, 0x01F8],
    "O": [0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x014C, 0x014E, 0x0150, 0x01A0, 0x01D1, 0x01EA, 0x01EC, 0x020C, 0x020E, 0x022A, 0x022C, 0x022E, 0x0230],
    "R": [0x0154, 0x0156, 0x0158, 0x0210, 0x0212],
    "S": [0x015A, 0x015C, 0x015E, 0x0160, 0x0218],
    "T": [0x0162, 0x0164, 0x021A],
    "U": [0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x0168, 0x016A, 0x016C, 0x016E, 0x0170, 0x0172, 0x01AF, 0x01D3, 0x01D5, 0x01D7, 0x01D9, 0x01DB, 0x0214, 0x0216],
    "W": [0x0174],
    "Y": [0x00DD, 0x0176, 0x0178, 0x0232],
    "Z": [0x0179, 0x017B, 0x017D],
    "a": [0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x0101, 0x0103, 0x0105, 0x01CE, 0x01DF, 0x01E1, 0x01FB, 0x0201, 0x0203, 0x0227],
    "c": [0x00E7, 0x0107, 0x0109, 0x010B, 0x010D],
    "d": [0x010F],
    "e": [0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x0113, 0x0115, 0x0117, 0x0119, 0x011B, 0x0205, 0x0207, 0x0229],
    "g": [0x011D, 0x011F, 0x0121, 0x0123, 0x01E7, 0x01F5],
    "h": [0x0125, 0x021F],
    "i": [0x00EC, 0x00ED, 0x00EE, 0x00EF, 0x0129, 0x012B, 0x012D, 0x012F, 0x01D0, 0x0209, 0x020B],
    "j": [0x0135, 0x01F0],
    "k": [0x0137, 0x01E9],
    "l": [0x013A, 0x013C, 0x013E],
    "n": [0x00F1, 0x0144, 0x0146, 0x0148, 0x01F9],
    "o": [0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x014D, 0x014F, 0x0151, 0x01A1, 0x01D2, 0x01EB, 0x01ED, 0x020D, 0x020F, 0x022B, 0x022D, 0x022F, 0x0231],
    "r": [0x0155, 0x0157, 0x0159, 0x0211, 0x0213],
    "s": [0x015B, 0x015D, 0x015F, 0x0161, 0x017F, 0x0219],
    "t": [0x0163, 0x0165, 0x021B],
    "u": [0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x0169, 0x016B, 0x016D, 0x016F, 0x0171, 0x0173, 0x01B0, 0x01D4, 0x01D6, 0x01D8, 0x01DA, 0x01DC, 0x0215, 0x0217],
    "w": [0x0175],
    "y": [0x00FD, 0x00FF, 0x0177, 0x0233],
    "z": [0x017A, 0x017C, 0x017E]
};
var DIACRITICS = {};
for (var dk in DIACRITIC_CODES) {
    var dl = DIACRITIC_CODES[dk], ds = "";
    for (var dj = 0; dj < dl.length; dj++) ds += String.fromCharCode(dl[dj]);
    DIACRITICS[dk] = ds;
}
function wowTitle(s) {
    var out = "";
    for (var i = 0; i < s.length; i++) {
        var ch = s.charAt(i), code = s.charCodeAt(i), plain = ch;
        if (code >= 0xC0 && code <= 0x24F) {
            for (var base in DIACRITICS) {
                if (DIACRITICS[base].indexOf(ch) >= 0) { plain = base; break; }
            }
        }
        out += plain;
    }
    return out;
}

// Size of a leading ID3v2 tag (0 if none). Only reads the first 10 bytes.
function id3Size(path) {
    var st = new ActiveXObject("ADODB.Stream");
    st.Type = 2; st.Charset = "iso-8859-1"; st.Open();
    try {
        st.LoadFromFile(path);
        var h = st.ReadText(10);
        if (h.length < 10 || h.substr(0, 3) != "ID3") return 0;
        var b = [];
        for (var i = 0; i < 10; i++) b.push(h.charCodeAt(i) & 0xFF);
        var size = 10 + b[6] * 2097152 + b[7] * 16384 + b[8] * 128 + b[9];
        if (b[5] & 0x10) size += 10;
        return size;
    } finally { st.Close(); }
}

// Copy an MP3 without its ID3v2 tag (broken tags make WoW stay silent).
function copyWithoutId3(src, dest) {
    var skip = 0;
    try { skip = id3Size(src); } catch (err) { skip = 0; }
    var inS = new ActiveXObject("ADODB.Stream");
    inS.Type = 1; inS.Open();
    try {
        inS.LoadFromFile(src);
        if (skip <= 0 || skip >= inS.Size) { inS.Close(); fso.CopyFile(src, dest, true); return; }
        inS.Position = skip;
        var outS = new ActiveXObject("ADODB.Stream");
        outS.Type = 1; outS.Open();
        try {
            inS.CopyTo(outS);
            outS.SaveToFile(dest, 2);
        } finally { outS.Close(); }
    } finally { if (inS.State == 1) inS.Close(); }
}

// Track length from Windows file properties ("Length" column, e.g. 00:03:05).
var shell = null, lengthColumn = -1;
try { shell = new ActiveXObject("Shell.Application"); } catch (err) { shell = null; }
function parseLength(text) {
    var m = /(\d+):(\d\d):(\d\d)/.exec("" + text);
    return m ? parseInt(m[1], 10) * 3600 + parseInt(m[2], 10) * 60 + parseInt(m[3], 10) : 0;
}
function durationSeconds(song) {
    if (!shell) return 0;
    try {
        var ns = shell.NameSpace(song.dir);
        var item = ns.ParseName(song.fileName);
        if (lengthColumn < 0) {
            if (parseLength(ns.GetDetailsOf(item, 27)) > 0) {
                lengthColumn = 27;
            } else {
                for (var c = 0; c < 320; c++) {
                    if (parseLength(ns.GetDetailsOf(item, c)) > 0) { lengthColumn = c; break; }
                }
            }
            if (lengthColumn < 0) return 0;
        }
        return parseLength(ns.GetDetailsOf(item, lengthColumn));
    } catch (err) { return 0; }
}

// --- Build the playlist --------------------------------------------------------
var lines = [];
lines.push("-- Generated by UpdatePlaylist.bat (UTF-8). Put songs in Music, run it again, restart WoW.");
lines.push("AmdirMusicFolders = {");
for (var fi = 0; fi < folders.length; fi++) {
    var fo = folders[fi];
    lines.push("    { path = " + luaString(fo.rel) + ", parent = " + luaString(fo.parent)
        + ", name = " + luaString(fo.name) + " },");
}
lines.push("}");
lines.push("AmdirMusicTracks = {");
var ok = 0;
for (var si = 0; si < songs.length; si++) {
    var song = songs[si];
    var alias = "track_" + pad5(si + 1) + "." + song.ext;
    var dest = fso.BuildPath(cacheDir, alias);
    var prefix = "[" + (si + 1) + "/" + songs.length + "] ";
    try {
        if (song.ext == "mp3") copyWithoutId3(song.path, dest); else fso.CopyFile(song.path, dest, true);
    } catch (err) {
        try { fso.CopyFile(song.path, dest, true); } catch (err2) {
            log(prefix + "SKIPPED: " + err2.message);
            continue;
        }
    }
    var duration = durationSeconds(song);
    lines.push("    { title = " + luaString(wowTitle(song.title))
        + ", path = " + luaString("Interface\\AddOns\\AmdirMusicLibrary\\MusicCache\\" + alias)
        + ", folder = " + luaString(song.folder) + ", duration = " + duration + " },");
    ok++;
    log(prefix + (duration > 0 ? "ok, " + duration + " s" : "ok"));
}
lines.push("}");

// The playlist is pure ASCII (see luaString), so a plain text file is enough.
var out = fso.CreateTextFile(playlistFile, true, false);
out.Write(lines.join("\n") + "\n");
out.Close();

log("");
log("Playlist saved: " + ok + " songs.");
log("Fully restart WoW to hear new songs (/reload is not enough).");
}

try {
    main();
} catch (e) {
    WScript.Echo("");
    WScript.Echo("ERROR: " + (e.message || "unknown") + " (code " + e.number + ")");
    WScript.Quit(1);
}
