# ytdl suite

How the player turns yt-dlp's JSON into playlist entries. Host only: no
network, no rig, no real yt-dlp.

```
Invoke-Suite.ps1    copy the player into -OutDir, launch it on the fake URL,
                    read back the playlist it saved, assert
fake-ytdlp.cmd      stands in for yt-dlp.exe (YDLExePath): prints playlist.json
                    for the fake playlist URL, fails for any other URL
playlist.json       the canned yt-dlp -J output
```

The saved `default.mpcpl` (portable mode, beside the copied exe) holds each
entry's label, file, source URL and `ydl_sub` lines, which is everything
`CYoutubeDLInstance::GetHttpStreams` produced for it. `youtubedl.log`
(`DebugLogMask=4`) is copied to `-OutDir` next to it.

## Cases

The four entries are built so that a field carried over from one entry to the
next shows: A has a title, series, episode number and a subtitle; B a title
only; C no title and its own subtitle; D only a `url`.

| case | what must hold |
|---|---|
| `playlist-entry-count` | four entries |
| `playlist-titles-independent` | B is `Entry B` with no `E01. SeriesA - ` from A; C's title is empty, not B's |
| `playlist-subtitles-independent` | A has `a.en.vtt`, B none, C `c.en.vtt`, D none |
| `playlist-url-only-entry` | D has its own file, no title, and the playlist URL as its source rather than C's page |

Before the fix for ledger 33 (one `YDLStreamURL` reused across the loop) the
last three fail; the count passes either way.

## Traps

* **Never launch with `/add`.** `/add` always redirects to a player that is
  already running and ignores `/new` (`mplayerc.cpp`, the redirect condition
  in `InitInstance`), so on a desktop shared with other sessions it hands the
  URL to someone else's player and yours exits 0 having done nothing. The
  suite uses `/new /open`.
* **The fake must refuse every URL but the playlist.** Once the player opens
  an entry and fails (the files are on `example.invalid`), it moves to the
  next and re-resolves that entry's `webpage_url` through yt-dlp, then
  replaces the entry with the first stream of the answer. A fake that printed
  the playlist for any URL made every entry look like A on both builds.
* **Copying a source file back keeps its old mtime.** If you swap
  `YoutubeDL.cpp` to build an unfixed exe and copy the fixed one back, touch
  it before rebuilding, or MSBuild keeps the unfixed object and the "fixed"
  run fails like the unfixed one.
