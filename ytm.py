#!/usr/bin/env python3
"""Download a YouTube Music playlist as tagged audio files.

    ytm                      use the link on the clipboard, or ask for one
    ytm <link>               download that playlist (or single song)
    ytm <link> --mp3         save as mp3 instead of m4a
    ytm <link> --browser chrome   use that browser's login for private playlists
    ytm <link> -- <options>  anything after "--" goes straight to yt-dlp

Songs land in ~/Music/YouTube Music/<playlist name>/ and the folder opens in
Finder when the download finishes. Running it again on the same playlist only
fetches songs that were added since.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from shutil import which
from typing import Any
from urllib.parse import parse_qs, urlparse

PROJECT_DIR = Path(__file__).resolve().parent
VENV_DIR = PROJECT_DIR / ".venv"
VENV_PYTHON = VENV_DIR / "bin" / "python"
YTDLP = VENV_DIR / "bin" / "yt-dlp"
UPDATE_MARKER = VENV_DIR / ".last-update"
UPDATE_INTERVAL_SECONDS = 7 * 24 * 60 * 60
YTDLP_PACKAGE = "yt-dlp[default]"

MUSIC_DIR = Path.home() / "Music" / "YouTube Music"
SINGLES_FOLDER = "Singles"
FALLBACK_FOLDER = "Untitled playlist"
ARCHIVE_NAME = ".downloaded.txt"
DEFAULT_AUDIO_FORMAT = "m4a"
FILE_TEMPLATE = "%(artist,uploader|Unknown)s - %(title)s.%(ext)s"
PROGRESS_TEMPLATE = "before_dl:[%(playlist_index|1)s/%(n_entries|1)s] %(title)s"
# YouTube thumbnails are 16:9; crop them to the square cover a music player expects.
SQUARE_COVER_ARGS = (
    "ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -vf crop=\"'min(iw,ih)':'min(iw,ih)'\""
)
AUDIO_SUFFIXES = frozenset({".m4a", ".mp3", ".opus", ".ogg", ".webm"})
DOWNLOAD_THREADS = "4"
PASSTHROUGH_SEPARATOR = "--"
MAX_ATTEMPTS = 2
CLIPBOARD_TIMEOUT_SECONDS = 5
EXIT_OK = 0
EXIT_FAILED = 1
EXIT_INTERRUPTED = 130
EXTRA_PATH_DIRS = ("/usr/local/bin", "/opt/homebrew/bin")

MUSIC_HOST = "music.youtube.com"
SHORT_HOST = "youtu.be"
ALLOWED_HOSTS = frozenset(
    {MUSIC_HOST, SHORT_HOST, "youtube.com", "www.youtube.com", "m.youtube.com"}
)
ID_PATTERN = re.compile(r"[A-Za-z0-9_-]{2,}")
BARE_PLAYLIST_ID = re.compile(r"LM|LL|(?:PL|OLAK5uy_|RD|UU|FL)[A-Za-z0-9_-]{8,}")
UNSAFE_NAME_CHARS = re.compile(r"[/:\x00-\x1f]")

PRIVATE_HINT = (
    "Check your internet connection. If the playlist is private, set it to Unlisted in "
    "YouTube Music, or run again with --browser chrome (or safari, firefox) to use your login."
)
RETRY_NOTE = "Some songs failed. Trying those again..."
FAILURE_NOTE = (
    "yt-dlp reported errors: some videos are unavailable, or there was a network or "
    "YouTube problem. See above; `ytm --update` may help."
)
EMPTY_FOLDER_NOTE = (
    f"Nothing new to download. Songs already fetched are listed in {ARCHIVE_NAME} "
    "inside this folder; delete that file to download them again."
)
REPAIR_HINT = f"If this keeps happening, delete {VENV_DIR} and run again."
NO_TERMINAL_HINT = "No link given and no terminal to ask on. Run: ytm <link>"


class DownloadError(Exception):
    """A problem worth showing to the user without a traceback."""


@dataclass(frozen=True)
class Link:
    url: str
    playlist_id: str | None


@dataclass(frozen=True)
class Summary:
    folder: str
    song_count: int


def normalize_link(text: str) -> Link:
    """Turn whatever was pasted into a clean playlist or song link."""
    candidate = text.strip()
    if not candidate:
        raise ValueError("No link given.")
    if BARE_PLAYLIST_ID.fullmatch(candidate):
        return _playlist_link(candidate)

    parsed = urlparse(candidate if "://" in candidate else f"https://{candidate}")
    host = (parsed.hostname or "").lower()
    if host not in ALLOWED_HOSTS:
        raise ValueError("That is not a YouTube or YouTube Music link.")

    query = parse_qs(parsed.query)
    playlist_id = _first(query, "list")
    if playlist_id:
        return _playlist_link(playlist_id)

    video_id = parsed.path.strip("/") if host == SHORT_HOST else _first(query, "v")
    if not video_id or not ID_PATTERN.fullmatch(video_id):
        raise ValueError("That link has no playlist or song in it.")
    return Link(url=f"https://{MUSIC_HOST}/watch?v={video_id}", playlist_id=None)


def _first(query: dict[str, list[str]], key: str) -> str:
    return next(iter(query.get(key, [])), "")


def _playlist_link(playlist_id: str) -> Link:
    if not ID_PATTERN.fullmatch(playlist_id):
        raise ValueError("That playlist link looks broken.")
    return Link(url=f"https://{MUSIC_HOST}/playlist?list={playlist_id}", playlist_id=playlist_id)


def safe_folder_name(title: str) -> str:
    cleaned = UNSAFE_NAME_CHARS.sub("-", title).strip().lstrip(". ")
    return cleaned if cleaned.strip("- ") else FALLBACK_FOLDER


def summarize(info: dict[str, Any]) -> Summary:
    if info.get("_type") != "playlist":
        return Summary(folder=SINGLES_FOLDER, song_count=1)
    return Summary(
        folder=safe_folder_name(info.get("title") or ""),
        song_count=len(info.get("entries") or []),
    )


def needs_update(marker: Path, now: float) -> bool:
    return not marker.exists() or now - marker.stat().st_mtime > UPDATE_INTERVAL_SECONDS


def folder_name(base: str, audio_format: str) -> str:
    """Each format gets its own folder.

    Converting to mp3 deletes the m4a it was made from, so in a shared folder an mp3
    run would destroy the songs of an earlier m4a run.
    """
    if audio_format == DEFAULT_AUDIO_FORMAT:
        return base
    return f"{base} ({audio_format.upper()})"


def _cookie_args(browser: str | None) -> list[str]:
    return ["--cookies-from-browser", browser] if browser else []


def build_command(
    ytdlp: Path,
    link: Link,
    *,
    audio_format: str,
    browser: str | None,
    extra_args: tuple[str, ...] = (),
) -> list[str]:
    """The yt-dlp call for one link. Paths are relative: run it inside the song folder."""
    playlist_args = (
        ["--yes-playlist", "--download-archive", ARCHIVE_NAME]
        if link.playlist_id
        else ["--no-playlist"]
    )
    return [
        str(ytdlp),
        "--format", "bestaudio[ext=m4a]/bestaudio/best",
        "--extract-audio", "--audio-format", audio_format, "--audio-quality", "0",
        "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg",
        "--postprocessor-args", SQUARE_COVER_ARGS,
        "--output", FILE_TEMPLATE,
        "--concurrent-fragments", DOWNLOAD_THREADS,
        "--quiet", "--progress", "--no-warnings", "--no-simulate",
        "--print", PROGRESS_TEMPLATE,
        *playlist_args,
        *_cookie_args(browser),
        *extra_args,
        "--", link.url,
    ]  # fmt: skip


def tool_environment() -> dict[str, str]:
    """Finder-launched scripts get a bare PATH; make sure ffmpeg and deno are found."""
    path = os.pathsep.join([*EXTRA_PATH_DIRS, os.environ.get("PATH", "")])
    return {**os.environ, "PATH": path}


def _last_line(text: str, fallback: str) -> str:
    return next(iter(text.strip().splitlines()[-1:]), fallback)


def update_ytdlp() -> None:
    print("Updating the download engine (yt-dlp)...")
    pip = [str(VENV_PYTHON), "-m", "pip", "install", "--quiet", "--upgrade"]
    result = subprocess.run([*pip, YTDLP_PACKAGE], capture_output=True, text=True)
    if result.returncode == 0:
        UPDATE_MARKER.touch()
        return
    reason = _last_line(result.stderr, "pip gave no reason")
    if not YTDLP.exists():
        raise DownloadError(f"Could not install yt-dlp: {reason}")
    print(f"  Update failed ({reason}). Carrying on with the installed version.")


def ensure_ytdlp(force_update: bool) -> None:
    """Keep a private, current yt-dlp: YouTube breaks old versions within weeks."""
    # Check the interpreter, not the yt-dlp script: the script survives when the
    # Python it points at is uninstalled, and a rebuild is the only way out of that.
    if not VENV_PYTHON.exists():
        print("Setting up the download engine...")
        subprocess.run([sys.executable, "-m", "venv", "--clear", str(VENV_DIR)], check=True)
    if force_update or not YTDLP.exists() or needs_update(UPDATE_MARKER, now=time.time()):
        update_ytdlp()


def read_clipboard() -> str:
    try:
        pasted = subprocess.run(
            ["pbpaste"], capture_output=True, text=True, timeout=CLIPBOARD_TIMEOUT_SECONDS
        )
    except (OSError, subprocess.SubprocessError):
        return ""  # no clipboard tool: choose_link falls back to asking
    return pasted.stdout


def choose_link(argument: str | None) -> Link:
    if argument:
        return normalize_link(argument)
    try:
        link = normalize_link(read_clipboard())
        print(f"Using the link on your clipboard:\n  {link.url}")
        return link
    except ValueError:
        pass
    while True:
        try:
            return normalize_link(input("Paste the playlist link and press Enter: "))
        except ValueError as error:
            print(f"  {error} Try again.")


def fetch_summary(link: Link, browser: str | None, env: dict[str, str]) -> Summary:
    scope = "--yes-playlist" if link.playlist_id else "--no-playlist"
    command = [
        str(YTDLP), "--flat-playlist", "--dump-single-json", "--no-warnings", scope,
        *_cookie_args(browser), "--", link.url,
    ]  # fmt: skip
    result = subprocess.run(command, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        reason = _last_line(result.stderr, "yt-dlp gave no reason.")
        raise DownloadError(f"Could not open that link.\n  {reason}\n{PRIVATE_HINT}")
    try:
        return summarize(json.loads(result.stdout))
    except json.JSONDecodeError as error:
        raise DownloadError(f"yt-dlp returned something unreadable: {error}") from error


def count_songs(folder: Path) -> int:
    return sum(1 for item in folder.iterdir() if item.suffix.lower() in AUDIO_SUFFIXES)


def run_with_retry(command: list[str], folder: Path, env: dict[str, str]) -> int:
    """YouTube sometimes refuses a download that works seconds later, so go round once more.

    Finished songs are in the archive, so the second pass only retries the failures.
    """
    for attempt in range(1, MAX_ATTEMPTS + 1):
        exit_code = subprocess.run(command, cwd=folder, env=env).returncode
        if exit_code == 0 or attempt == MAX_ATTEMPTS:
            break
        print(f"\n{RETRY_NOTE}")
    return exit_code


def download(link: Link, args: argparse.Namespace, extra_args: tuple[str, ...]) -> int:
    env = tool_environment()
    if which("ffmpeg", path=env["PATH"]) is None:
        raise DownloadError("ffmpeg is missing. Install it with: brew install ffmpeg")

    audio_format = "mp3" if args.mp3 else DEFAULT_AUDIO_FORMAT
    summary = fetch_summary(link, args.browser, env)
    folder = MUSIC_DIR / folder_name(summary.folder, audio_format)
    folder.mkdir(parents=True, exist_ok=True)
    songs_before = count_songs(folder)
    print(f"\n{summary.folder}: {summary.song_count} song(s)\nSaving to {folder}\n")

    command = build_command(
        YTDLP, link, audio_format=audio_format, browser=args.browser, extra_args=extra_args
    )
    exit_code = run_with_retry(command, folder, env)

    songs_after = count_songs(folder)
    print(f"\nDone: {songs_after - songs_before} new song(s), {songs_after} in the folder.")
    if exit_code != 0:
        print(FAILURE_NOTE)
    elif songs_after == songs_before and link.playlist_id:
        print(EMPTY_FOLDER_NOTE)
    if sys.platform == "darwin":
        subprocess.run(["open", str(folder)], check=False)
    return EXIT_OK if exit_code == 0 else EXIT_FAILED


def parse_args(argv: list[str] | None) -> tuple[argparse.Namespace, tuple[str, ...]]:
    parser = argparse.ArgumentParser(
        prog="ytm", description="Download a YouTube Music playlist as audio files."
    )
    parser.add_argument("link", nargs="?", help="playlist link (default: clipboard)")
    parser.add_argument("--mp3", action="store_true", help="save mp3 instead of m4a")
    parser.add_argument("--browser", help="browser to borrow your YouTube login from")
    parser.add_argument("--update", action="store_true", help="update yt-dlp first")
    arguments = sys.argv[1:] if argv is None else argv
    if PASSTHROUGH_SEPARATOR not in arguments:
        return parser.parse_args(arguments), ()
    split_at = arguments.index(PASSTHROUGH_SEPARATOR)
    return parser.parse_args(arguments[:split_at]), tuple(arguments[split_at + 1 :])


def main(argv: list[str] | None = None) -> int:
    args, extra_args = parse_args(argv)
    try:
        link = choose_link(args.link)
        ensure_ytdlp(force_update=args.update)
        return download(link, args, extra_args)
    except (ValueError, DownloadError) as error:
        print(f"Error: {error}", file=sys.stderr)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Error: {error}\n{REPAIR_HINT}", file=sys.stderr)
    except EOFError:
        print(f"Error: {NO_TERMINAL_HINT}", file=sys.stderr)
    except KeyboardInterrupt:
        print("\nStopped. Run it again to carry on where it left off.")
        return EXIT_INTERRUPTED
    return EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main())
