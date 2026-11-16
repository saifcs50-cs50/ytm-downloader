# ytm

`ytm` is a small command-line tool that downloads a YouTube Music playlist (or a single song) as tagged audio files
with square cover art. I made it because I couldn't find my downloaded songs afterwards, so it gives each playlist
its own folder and opens it when the download finishes.

It is a thin wrapper around [yt-dlp](https://github.com/yt-dlp/yt-dlp): `ytm` handles the link, the folders, the
retry and the weekly yt-dlp update, and yt-dlp does the downloading. There is a macOS version (`ytm.py`, Python) and
a Windows version (`windows/ytm.ps1`, PowerShell).

> This is an independent hobby project. It is not made, endorsed or sponsored by YouTube or Google.
> "YouTube" and "YouTube Music" are trademarks of Google LLC, used here only to say what the tool works with.

## Please use it responsibly

Downloading from YouTube can break [YouTube's Terms of Service](https://www.youtube.com/t/terms), and most music
is protected by copyright. Only download things you have the right to download: your own uploads, public-domain
or Creative Commons material, or content whose owner allows it. You are responsible for what you download and
for following the laws and terms that apply to you. This software is provided as is, with no warranty (see
[LICENSE](LICENSE)).

## How it works

`ytm` takes a playlist link, a song link, a `youtu.be` link or a bare playlist ID, drops tracking parameters and
refuses links that aren't from YouTube. It saves `m4a` (default) or `mp3` with embedded title/artist tags and a
square cover image. A hidden `.downloaded.txt` in each playlist folder lists the finished songs, so running it
again only fetches songs added since.

A failed download is retried once before `ytm` reports what went wrong. I added the retry after YouTube returned
HTTP 403 on a first pass and the same download worked seconds later. `ytm` keeps its own yt-dlp in a private
virtualenv and updates it about once a week, because YouTube breaks old versions quickly.

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

Make sure `~/.local/bin` is on your `PATH`. The first run creates a `.venv/` folder in the project and installs
yt-dlp into it, so it needs an internet connection.

It's built for macOS, where the unit tests pass with Python 3.14. The clipboard and "open the folder when done"
features use the macOS commands `pbpaste` and `open`. Elsewhere you pass the link yourself, and it's untested.

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

`YT Music Downloader.command` does the same as a bare `ytm` when you double-click it, so copy a playlist link
first. You can copy the launcher to your Desktop if you like.

`--browser` makes yt-dlp read your YouTube login cookies from that browser on your own computer; `ytm` doesn't
store them. Using a logged-in account with a downloader is at your own risk, so prefer setting a playlist to
Unlisted.

### Where the songs go

Playlists go to `~/Music/YouTube Music/<playlist name>/` and single songs to `~/Music/YouTube Music/Singles/`. The
folder opens in Finder when the download finishes.

MP3 downloads get their own folder, `<playlist name> (MP3)`, because converting to mp3 deletes the m4a it was made
from. To download a playlist again from scratch, delete the hidden `.downloaded.txt` inside its folder.

### If something goes wrong

- "Could not open that link": the playlist is probably private. Set it to Unlisted in YouTube Music, or add
  `--browser chrome`.
- Downloads fail with HTTP 403: YouTube changed something. Run `ytm --update`.
- Some songs are missing: videos that were removed or are blocked in your region are skipped, and everything else
  still downloads.
- Strange errors about the environment: delete the `.venv/` folder and run again.

## Tests

The Python tests run offline (the downloads and the clipboard are replaced with stand-ins):

```bash
python3 -m unittest -v test_ytm
```

## Windows version

`windows/` holds a PowerShell port for a PC with nothing installed.

- `ytm.ps1` behaves like `ytm.py` and is written for the Windows PowerShell 5.1 that ships with Windows. The
  repository includes no tools. On first run the script downloads yt-dlp, Deno and an FFmpeg build from their
  official GitHub releases (about 260 MB in total) into a `tools` folder beside it.
- `YT Music Downloader.bat` and `YT Music Downloader (MP3).bat` are double-click launchers.
- `README.txt` is the end-user guide that goes into the zip.
- `package.sh` builds `YT-Music-Downloader-Windows.zip` from those files, converting line endings for Windows. The
  zip and the downloaded tools are git-ignored.
- `ytm.tests.ps1` holds the tests. Run them with `powershell -ExecutionPolicy Bypass -File ytm.tests.ps1`.

I've only run the script with PowerShell 7 on a Mac, with the Mac tools standing in for the `.exe` files. It has
never run on an actual Windows PC.

## Credits and licence

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) (Unlicense) does all the downloading.
- [FFmpeg](https://ffmpeg.org/) converts audio and embeds covers; [Deno](https://deno.com/) (MIT) runs YouTube's
  player code for yt-dlp. None of these are bundled here; you install or download them yourself.

`ytm` itself is released under the [MIT licence](LICENSE).
