# web suite

The web interface's JSON answers while the player is busy underneath them,
and requests that arrive in more than one read.

```
Invoke-Suite.ps1                  deploy the player and two clips, run one launch per case, assert
Run-WebStressCase.guest.ps1       target side: start the player, poll /status.json and /playlist.json
                                  from several clients in tight loops while command lines alternate
                                  two files under them, record what came back (result.json)
Run-WebSplitHeaderCase.guest.ps1  target side: start the player with no file, send one request per
                                  split of its header terminator over a raw socket, record the
                                  status line each got (result.json)
```

## Cases

| case | what it does | what must hold |
|---|---|---|
| `json-under-file-changes` | two clients poll both documents as fast as they can for 60 s while a WM_COPYDATA command line alternates a 150 entry playlist of `stereo.mkv` with `subs.mkv` alone (two embedded subtitle tracks) every 700 ms | the player survives and exits 0 on close; every 200 body parses; no failed request; the pollers saw both playlist sizes (1 and 150) and both subtitle track counts (0 and 3), so the opens really ran under the reads, and no size the player never had |
| `header-split-across-reads` | five connections each write `GET /status.html HTTP/1.0\r\n\r\n` with the last 0 to 4 bytes held back, wait 200 ms so the server reads the first part alone, write the rest and read with a 3 s timeout. 1 to 3 split the `\r\n\r\n` across two reads; 0 and 4 are the controls | every connection gets `200`; the player survives and closes |

Before the fix (ledger 30) `CWebClientSocket::OnReceive` started the next
search for `\r\n\r\n` at the end of everything received so far, past the bytes
holding the start of a split terminator, so it was never found and the client
waited until it gave up. On the unfixed build on the host the three splits got
no answer and both controls got their 200.

## Why this shape

`remote.html` polls both documents once a second for as long as it is open.
Before the fix (ledger 29) `OnStatusJSON` and `OnPlaylistJSON` ran on the web
server's thread and walked `m_pSubStreams` and the playlist directly, lists the
UI thread rebuilds on every open. Neither has a lock the web thread could take:
`m_csSubLock` is held for the `RemoveAll` in `CloseMediaPrivate` but not for
the `AddTail`s in `LoadSubtitle` and `OnGetSubtitles`, and the playlist has no
lock at all. After the fix the builders run on the UI thread, reached with a
`SendMessageTimeout` bounded at 5 s, and a frame that does not answer in time
gets a 503 (reported by the case, not asserted).

A torn read does not have to crash. On the unfixed build 120 s runs on the
host and on a guest both survived while the pollers reported playlist sizes
of 0, 261 and 299 for a list that was only ever 1 or 150 entries long: a walk
that crossed nodes being freed and reused. So the case checks the set of
sizes seen as well as whether the player is still there, and that set is what
separates the builds. The subtitle count for `subs.mkv` is 3, not 2: LAV
Splitter lists a "no subtitles" entry in the subtitle group.

Refused connections are reported, not asserted. Two tight loops overrun the
web server's listen backlog, on a guest by tens of thousands in 120 s, and a
refused connection carries no information about the race.

## Traps

* **The opener must not look like an Explorer selection.** Command lines that
  arrive within `RedirectOpenToAppendThreshold` ms (default 1000) of each other
  are appended to the playlist instead of replacing it. The ini sets it to 0.
* **EVR-CP needs `D3DX9_43.dll`.** The suite copies it from `distrib\x64`. With
  any other renderer `m_pCAP` is null, the internal subtitle renderer is not
  used, and `m_pSubStreams` stays empty, so the subtitle half of the race is
  not exercised. From a sandboxed pane on the host only the null renderer
  opens a file at all, which is why this runs in a guest.
