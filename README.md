# ytm

A small command-line tool that downloads a YouTube Music playlist (or a single song) as tagged audio
files with square cover art. It is a thin wrapper around [yt-dlp](https://github.com/yt-dlp/yt-dlp):
`ytm` handles the link, the folders, the retry and the weekly yt-dlp update, and yt-dlp does the downloading.

There is a macOS version (`ytm.py`, Python) and a Windows version (`windows/ytm.ps1`, PowerShell).

> This is an independent hobby project. It is not made, endorsed or sponsored by YouTube or Google.
> "YouTube" and "YouTube Music" are trademarks of Google LLC, used here only to say what the tool works with.

## Please use it responsibly

Downloading from YouTube can break [YouTube's Terms of Service](https://www.youtube.com/t/terms), and most music
is protected by copyright. Only download things you have the right to download: your own uploads, public-domain
or Creative Commons material, or content whose owner allows it. You are responsible for what you download and
for following the laws and terms that apply to you. This software is provided as is, with no warranty (see
[LICENSE](LICENSE)).

## What it does

- Takes a playlist link, a song link, a `youtu.be` link or a bare playlist ID, and cleans it up (tracking
  parameters are dropped; links that are not YouTube links are refused).
- Saves audio as `m4a` (default) or `mp3` with embedded title/artist tags and a square cover image.
- Keeps a hidden list of finished songs (`.downloaded.txt`) in each playlist folder, so running it again only
  fetches songs added since.
- Retries once if a download fails, then reports what went wrong.
- Keeps its own copy of yt-dlp in a private virtualenv and updates it about once a week, because YouTube breaks
  old versions quickly.

## Setup (macOS)

You need Python 3, [ffmpeg](https://ffmpeg.org/) and [Deno](https://deno.com/) (yt-dlp uses Deno to deal with
YouTube's player code):

```bash
brew install ffmpeg deno
git clone https://github.com/saifcs50-cs50/ytm-downloader.git
cd ytm-downloader
mkdir -p ~/.local/bin
ln -s "$PWD/ytm.py" ~/.local/bin/ytm
```

Make sure `~/.local/bin` is on your `PATH`. The first run creates a `.venv/` folder inside the project and
installs yt-dlp into it, so it needs an internet connection.

Built for macOS; the unit tests pass there with Python 3.14. The clipboard and "open the folder when done" features use the
macOS commands `pbpaste` and `open`; on other systems you pass the link yourself (not tested there).

## Use it

```bash
ytm "https://music.youtube.com/playlist?list=..."
```

| Command | What it does |
|---------|--------------|
| `ytm` | Use the link on the clipboard, or ask for one |
| `ytm <link>` | Download that playlist (a single song link works too) |
| `ytm <link> --mp3` | Save mp3 instead of m4a |
| `ytm <link> --browser chrome` | Use that browser's login (via yt-dlp), for private playlists and Liked Music |
| `ytm --update` | Force an update of yt-dlp before downloading |
| `ytm <link> -- <options>` | Pass anything after `--` straight to yt-dlp (download step only; for logins use `--browser`) |

There is also a double-click launcher, `YT Music Downloader.command`: copy a playlist link, then double-click it
(copy it to your Desktop if you like). It uses the link on the clipboard, or asks you to paste one.

`--browser` makes yt-dlp read your YouTube login cookies from that browser on your own computer. They are not
stored by `ytm`. Using a logged-in account with a downloader is at your own risk, so prefer setting a playlist
to Unlisted instead.

### Where the songs go

`~/Music/YouTube Music/<playlist name>/`, and the folder opens in Finder when the download finishes. Single songs
go to `~/Music/YouTube Music/Singles/`.

MP3 downloads go into their own folder, `<playlist name> (MP3)`: converting to mp3 deletes the m4a it was made
from, so the two cannot share a folder. To download a playlist again from scratch, delete the hidden
`.downloaded.txt` inside its folder.

### If something goes wrong

- **"Could not open that link"**: the playlist is probably private. Set it to Unlisted in YouTube Music, or add
  `--browser chrome`.
- **Downloads fail with HTTP 403**: YouTube changed something. Run `ytm --update`.
- **Some songs are missing**: videos that were removed or are blocked in your region are skipped; everything
  else still downloads.
- **Strange errors about the environment**: delete the `.venv/` folder and run again.

## Tests

The Python tests run offline (the downloads and the clipboard are replaced with stand-ins):

```bash
python3 -m unittest -v test_ytm
```

## Windows version

`windows/` holds a PowerShell port for a PC with nothing installed.

- `ytm.ps1` behaves like `ytm.py` and is written for the Windows PowerShell 5.1 that ships with Windows. No
  tools are included in this repository. On first run it downloads, from their official GitHub releases,
  yt-dlp, Deno and an FFmpeg build (about 260 MB in total) into a `tools` folder beside the script.
- `YT Music Downloader.bat` and `YT Music Downloader (MP3).bat` are double-click launchers.
- `README.txt` is the end-user guide that goes into the zip.
- `package.sh` builds `YT-Music-Downloader-Windows.zip` from those files (converting line endings for Windows).
  The zip and the downloaded tools are git-ignored.
- `ytm.tests.ps1` holds the tests; run them with `powershell -ExecutionPolicy Bypass -File ytm.tests.ps1`.

Honest status: the PowerShell script was exercised with PowerShell 7 on a Mac, using the Mac tools in place of the
`.exe` files, and it has never been run on an actual Windows PC.

## Credits and licence

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) (Unlicense) does all the downloading.
- [FFmpeg](https://ffmpeg.org/) converts audio and embeds covers; [Deno](https://deno.com/) (MIT) runs YouTube's
  player code for yt-dlp. None of these are bundled here; you install or download them yourself.

`ytm` itself is released under the [MIT licence](LICENSE).
