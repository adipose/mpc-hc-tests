@rem Stands in for yt-dlp.exe. Answers only the fake playlist URL, with the
@rem canned JSON beside it; any other URL fails, so the player cannot replace a
@rem playlist entry by re-resolving its webpage_url.
@echo %* | findstr /c:"list=PLfake" >nul || exit /b 1
@type "%~dp0playlist.json"
