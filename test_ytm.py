"""Unit tests for ytm.py. Run with: python3 -m unittest -v test_ytm"""

import argparse
import contextlib
import io
import os
import subprocess
import time
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

import ytm


class NormalizeLinkTests(unittest.TestCase):
    def test_keeps_only_the_list_id_from_a_youtube_music_playlist_link(self):
        link = "https://music.youtube.com/playlist?list=PLabc123_-x&si=tracking"

        result = ytm.normalize_link(link)

        self.assertEqual(result.url, "https://music.youtube.com/playlist?list=PLabc123_-x")
        self.assertEqual(result.playlist_id, "PLabc123_-x")

    def test_treats_a_song_link_with_a_list_parameter_as_the_whole_playlist(self):
        link = "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc123"

        result = ytm.normalize_link(link)

        self.assertEqual(result.url, "https://music.youtube.com/playlist?list=PLabc123")

    def test_accepts_regular_youtube_playlist_links(self):
        result = ytm.normalize_link("https://www.youtube.com/playlist?list=OLAK5uy_abc")

        self.assertEqual(result.playlist_id, "OLAK5uy_abc")

    def test_accepts_a_bare_playlist_id(self):
        result = ytm.normalize_link("PLexampleplaylistid0123456789")

        self.assertEqual(
            result.url,
            "https://music.youtube.com/playlist?list=PLexampleplaylistid0123456789",
        )

    def test_accepts_a_single_song_link_without_a_playlist(self):
        result = ytm.normalize_link("https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=x")

        self.assertEqual(result.url, "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
        self.assertIsNone(result.playlist_id)

    def test_accepts_a_short_youtu_be_link(self):
        result = ytm.normalize_link("https://youtu.be/dQw4w9WgXcQ?si=x")

        self.assertEqual(result.url, "https://music.youtube.com/watch?v=dQw4w9WgXcQ")

    def test_ignores_surrounding_whitespace(self):
        result = ytm.normalize_link("  https://music.youtube.com/playlist?list=PLabc123\n")

        self.assertEqual(result.playlist_id, "PLabc123")

    def test_rejects_links_from_other_sites(self):
        with self.assertRaises(ValueError):
            ytm.normalize_link("https://example.com/playlist?list=PLabc123")

    def test_rejects_lookalike_hosts(self):
        with self.assertRaises(ValueError):
            ytm.normalize_link("https://youtube.com.evil.example/playlist?list=PLabc123")

    def test_rejects_text_that_is_not_a_link(self):
        with self.assertRaises(ValueError):
            ytm.normalize_link("my favourite songs")

    def test_rejects_empty_input(self):
        with self.assertRaises(ValueError):
            ytm.normalize_link("   ")

    def test_rejects_ids_with_characters_outside_the_id_alphabet(self):
        with self.assertRaises(ValueError):
            ytm.normalize_link("https://music.youtube.com/playlist?list=--exec=rm")

    def test_option_like_ids_only_ever_appear_inside_a_youtube_music_url(self):
        result = ytm.normalize_link("https://music.youtube.com/playlist?list=--help")

        self.assertTrue(result.url.startswith("https://music.youtube.com/"))


class SafeFolderNameTests(unittest.TestCase):
    HOSTILE_TITLES = ("..", ".", "...", "../..", "..\\..", "a/../../b", "\x00", "/etc", "")

    def test_hostile_titles_stay_a_single_folder_inside_the_music_folder(self):
        for title in self.HOSTILE_TITLES:
            with self.subTest(title=title):
                name = ytm.safe_folder_name(title)

                self.assertNotIn("/", name)
                self.assertNotIn(name, {"", ".", ".."})

    def test_replaces_path_separators(self):
        self.assertEqual(ytm.safe_folder_name("Rock/Pop: Best"), "Rock-Pop- Best")

    def test_strips_leading_dots_and_spaces(self):
        self.assertEqual(ytm.safe_folder_name(" ..hidden "), "hidden")

    def test_falls_back_when_nothing_usable_is_left(self):
        self.assertEqual(ytm.safe_folder_name("///"), ytm.FALLBACK_FOLDER)
        self.assertEqual(ytm.safe_folder_name(""), ytm.FALLBACK_FOLDER)


class FolderNameTests(unittest.TestCase):
    def test_the_default_format_uses_the_playlist_name_as_is(self):
        self.assertEqual(ytm.folder_name("Road Trip", "m4a"), "Road Trip")

    # Converting to mp3 deletes the m4a it was made from, so sharing a folder with an
    # earlier m4a download would destroy those files.
    def test_other_formats_get_their_own_folder(self):
        self.assertEqual(ytm.folder_name("Road Trip", "mp3"), "Road Trip (MP3)")


class BuildCommandTests(unittest.TestCase):
    def setUp(self):
        self.link = ytm.normalize_link("https://music.youtube.com/playlist?list=PLabc123")

    def build(self, **overrides):
        options = {"audio_format": "m4a", "browser": None, **overrides}
        return ytm.build_command(Path("/venv/bin/yt-dlp"), self.link, **options)

    def test_uses_a_relative_file_template_so_folder_names_need_no_escaping(self):
        command = self.build()

        template = command[command.index("--output") + 1]
        self.assertFalse(Path(template).is_absolute())

    def test_puts_the_link_last_after_an_option_terminator(self):
        command = self.build()

        self.assertEqual(command[-2:], ["--", self.link.url])

    def test_tracks_finished_songs_so_reruns_only_fetch_new_ones(self):
        command = self.build()

        archive = command[command.index("--download-archive") + 1]
        self.assertEqual(archive, ytm.ARCHIVE_NAME)

    def test_passes_extra_options_through_before_the_link(self):
        command = self.build(extra_args=("--playlist-items", "1-3"))

        self.assertEqual(command[-4:], ["--playlist-items", "1-3", "--", self.link.url])

    def test_requests_the_chosen_audio_format(self):
        command = self.build(audio_format="mp3")

        self.assertEqual(command[command.index("--audio-format") + 1], "mp3")

    def test_omits_browser_cookies_by_default(self):
        self.assertNotIn("--cookies-from-browser", self.build())

    def test_uses_browser_cookies_when_asked(self):
        command = self.build(browser="chrome")

        self.assertEqual(command[command.index("--cookies-from-browser") + 1], "chrome")

    def test_does_not_keep_an_archive_for_single_songs(self):
        single = ytm.normalize_link("https://music.youtube.com/watch?v=dQw4w9WgXcQ")

        command = ytm.build_command(
            Path("/venv/bin/yt-dlp"), single, audio_format="m4a", browser=None
        )

        self.assertNotIn("--download-archive", command)
        self.assertIn("--no-playlist", command)


class NeedsUpdateTests(unittest.TestCase):
    def test_true_when_the_marker_is_missing(self):
        with TemporaryDirectory() as folder:
            self.assertTrue(ytm.needs_update(Path(folder) / "missing", now=time.time()))

    def test_false_when_recently_updated(self):
        with TemporaryDirectory() as folder:
            marker = Path(folder) / "marker"
            marker.touch()

            self.assertFalse(ytm.needs_update(marker, now=marker.stat().st_mtime + 60))

    def test_true_when_older_than_the_update_interval(self):
        with TemporaryDirectory() as folder:
            marker = Path(folder) / "marker"
            marker.touch()
            later = marker.stat().st_mtime + ytm.UPDATE_INTERVAL_SECONDS + 1

            self.assertTrue(ytm.needs_update(marker, now=later))


class ChooseLinkTests(unittest.TestCase):
    PLAYLIST = "https://music.youtube.com/playlist?list=PLabc12345678"

    def test_prefers_the_link_given_on_the_command_line(self):
        with mock.patch.object(ytm, "read_clipboard") as clipboard:
            link = ytm.choose_link(self.PLAYLIST)

        self.assertEqual(link.playlist_id, "PLabc12345678")
        clipboard.assert_not_called()

    def test_uses_the_clipboard_when_it_holds_a_youtube_link(self):
        with mock.patch.object(ytm, "read_clipboard", return_value=self.PLAYLIST), \
                mock.patch("builtins.print"):
            link = ytm.choose_link(None)

        self.assertEqual(link.playlist_id, "PLabc12345678")

    def test_asks_until_a_valid_link_is_typed_when_the_clipboard_is_unrelated(self):
        answers = ["not a link", self.PLAYLIST]
        with mock.patch.object(ytm, "read_clipboard", return_value="shopping list"), \
                mock.patch("builtins.input", side_effect=answers) as prompt, \
                mock.patch("builtins.print"):
            link = ytm.choose_link(None)

        self.assertEqual(link.playlist_id, "PLabc12345678")
        self.assertEqual(prompt.call_count, 2)


class ParseArgsTests(unittest.TestCase):
    def test_everything_after_the_separator_goes_to_yt_dlp_not_the_link(self):
        args, extra = ytm.parse_args(["--mp3", "--", "--playlist-items", "1-2"])

        self.assertIsNone(args.link)
        self.assertTrue(args.mp3)
        self.assertEqual(extra, ("--playlist-items", "1-2"))

    def test_no_extra_options_without_the_separator(self):
        args, extra = ytm.parse_args(["PLabc12345678"])

        self.assertEqual(args.link, "PLabc12345678")
        self.assertEqual(extra, ())

    def test_rejects_unknown_options_instead_of_guessing(self):
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit):
            ytm.parse_args(["--mp4"])


def completed(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr=stderr)


class FetchSummaryTests(unittest.TestCase):
    LINK = ytm.Link(url="https://music.youtube.com/playlist?list=PLabc123", playlist_id="PLabc123")

    def test_puts_the_link_last_after_an_option_terminator(self):
        info = '{"_type": "playlist", "title": "Mix", "entries": [{}]}'
        with mock.patch.object(ytm.subprocess, "run", return_value=completed(stdout=info)) as run:
            summary = ytm.fetch_summary(self.LINK, None, {})

        self.assertEqual(run.call_args.args[0][-2:], ["--", self.LINK.url])
        self.assertEqual(summary, ytm.Summary(folder="Mix", song_count=1))

    def test_reports_the_reason_when_yt_dlp_cannot_open_the_link(self):
        failure = completed(returncode=1, stderr="WARNING: x\nERROR: playlist does not exist")
        with mock.patch.object(ytm.subprocess, "run", return_value=failure):
            with self.assertRaisesRegex(ytm.DownloadError, "playlist does not exist"):
                ytm.fetch_summary(self.LINK, None, {})

    def test_raises_a_readable_error_when_the_reply_is_not_json(self):
        with mock.patch.object(ytm.subprocess, "run", return_value=completed(stdout="<html>")):
            with self.assertRaises(ytm.DownloadError):
                ytm.fetch_summary(self.LINK, None, {})


class CountSongsTests(unittest.TestCase):
    def test_counts_audio_files_and_ignores_partial_and_hidden_files(self):
        with TemporaryDirectory() as folder:
            for name in ("a.m4a", "b.MP3", "c.m4a.part", ".downloaded.txt", "cover.jpg"):
                (Path(folder) / name).touch()

            self.assertEqual(ytm.count_songs(Path(folder)), 2)


class DownloadTests(unittest.TestCase):
    LINK = ytm.Link(url="https://music.youtube.com/playlist?list=PLabc123", playlist_id="PLabc123")
    ARGS = argparse.Namespace(mp3=False, browser=None)

    def run_download(self, music_dir, *, exit_code, new_files=(), args=ARGS):
        def fake_run(command, **options):
            if command[0] != "open":
                for name in new_files:
                    (Path(options["cwd"]) / name).touch()
            return completed(returncode=0 if command[0] == "open" else exit_code)

        output = io.StringIO()
        with mock.patch.object(ytm, "MUSIC_DIR", Path(music_dir)), \
                mock.patch.object(ytm, "which", return_value="/usr/local/bin/ffmpeg"), \
                mock.patch.object(ytm, "fetch_summary", return_value=ytm.Summary("Mix", 2)), \
                mock.patch.object(ytm.subprocess, "run", side_effect=fake_run), \
                contextlib.redirect_stdout(output):
            status = ytm.download(self.LINK, args, ())
        return status, output.getvalue()

    def test_mp3_downloads_leave_an_earlier_m4a_folder_untouched(self):
        mp3_args = argparse.Namespace(mp3=True, browser=None)
        with TemporaryDirectory() as music_dir:
            (Path(music_dir) / "Mix").mkdir()
            (Path(music_dir) / "Mix" / "old.m4a").touch()

            self.run_download(music_dir, exit_code=0, new_files=("a.mp3",), args=mp3_args)

            self.assertTrue((Path(music_dir) / "Mix (MP3)" / "a.mp3").exists())
            self.assertEqual(os.listdir(Path(music_dir) / "Mix"), ["old.m4a"])

    def test_succeeds_and_reports_new_songs_when_yt_dlp_succeeds(self):
        with TemporaryDirectory() as music_dir:
            status, output = self.run_download(music_dir, exit_code=0, new_files=("a.m4a", "b.m4a"))

        self.assertEqual(status, ytm.EXIT_OK)
        self.assertIn("2 new song(s)", output)

    def test_fails_when_yt_dlp_fails_even_if_the_folder_already_has_songs(self):
        with TemporaryDirectory() as music_dir:
            (Path(music_dir) / "Mix").mkdir()
            (Path(music_dir) / "Mix" / "old.m4a").touch()

            status, output = self.run_download(music_dir, exit_code=1)

        self.assertEqual(status, ytm.EXIT_FAILED)
        self.assertIn("ytm --update", output)

    def test_goes_round_again_once_when_the_first_pass_fails(self):
        exit_codes = iter([1, 0])
        calls = []

        def flaky_run(command, **options):
            if command[0] == "open":
                return completed()
            calls.append(command)
            return completed(returncode=next(exit_codes))

        with TemporaryDirectory() as music_dir, \
                mock.patch.object(ytm, "MUSIC_DIR", Path(music_dir)), \
                mock.patch.object(ytm, "which", return_value="/usr/local/bin/ffmpeg"), \
                mock.patch.object(ytm, "fetch_summary", return_value=ytm.Summary("Mix", 2)), \
                mock.patch.object(ytm.subprocess, "run", side_effect=flaky_run), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            status = ytm.download(self.LINK, self.ARGS, ())

        self.assertEqual(status, ytm.EXIT_OK)
        self.assertEqual(len(calls), 2)
        self.assertIn(ytm.RETRY_NOTE, output.getvalue())

    def test_gives_up_after_the_retry_instead_of_looping(self):
        with TemporaryDirectory() as music_dir, \
                mock.patch.object(ytm, "run_with_retry", wraps=ytm.run_with_retry) as runner:
            status, _ = self.run_download(music_dir, exit_code=1)

        self.assertEqual(status, ytm.EXIT_FAILED)
        runner.assert_called_once()

    def test_explains_the_skip_list_when_nothing_is_new_and_the_folder_is_empty(self):
        with TemporaryDirectory() as music_dir:
            status, output = self.run_download(music_dir, exit_code=0)

        self.assertEqual(status, ytm.EXIT_OK)
        self.assertIn(ytm.ARCHIVE_NAME, output)

    def test_explains_the_skip_list_when_nothing_is_new_in_a_folder_that_has_songs(self):
        with TemporaryDirectory() as music_dir:
            (Path(music_dir) / "Mix").mkdir()
            (Path(music_dir) / "Mix" / "old.m4a").touch()

            _, output = self.run_download(music_dir, exit_code=0)

        self.assertIn(ytm.ARCHIVE_NAME, output)

    def test_stops_with_a_clear_message_when_ffmpeg_is_missing(self):
        with mock.patch.object(ytm, "which", return_value=None):
            with self.assertRaisesRegex(ytm.DownloadError, "ffmpeg"):
                ytm.download(self.LINK, self.ARGS, ())


class EngineSetupTests(unittest.TestCase):
    def patch_paths(self, folder):
        venv = Path(folder)
        return mock.patch.multiple(
            ytm,
            VENV_DIR=venv,
            VENV_PYTHON=venv / "python",
            YTDLP=venv / "yt-dlp",
            UPDATE_MARKER=venv / ".last-update",
        )

    def test_rebuilds_the_environment_when_its_python_is_gone(self):
        with TemporaryDirectory() as folder, self.patch_paths(folder), \
                mock.patch.object(ytm.subprocess, "run", return_value=completed()) as run, \
                mock.patch.object(ytm, "update_ytdlp") as update, mock.patch("builtins.print"):
            (Path(folder) / "yt-dlp").touch()

            ytm.ensure_ytdlp(force_update=False)

        self.assertIn("--clear", run.call_args.args[0])
        update.assert_called_once()

    def test_does_nothing_when_the_engine_is_present_and_recently_updated(self):
        with TemporaryDirectory() as folder, self.patch_paths(folder), \
                mock.patch.object(ytm.subprocess, "run") as run, \
                mock.patch.object(ytm, "update_ytdlp") as update:
            for name in ("python", "yt-dlp", ".last-update"):
                (Path(folder) / name).touch()

            ytm.ensure_ytdlp(force_update=False)

        run.assert_not_called()
        update.assert_not_called()

    def test_a_failed_update_is_fatal_only_when_nothing_is_installed(self):
        failure = completed(returncode=1, stderr="noise\nERROR: no matching distribution")
        with TemporaryDirectory() as folder, self.patch_paths(folder), \
                mock.patch.object(ytm.subprocess, "run", return_value=failure), \
                mock.patch("builtins.print") as printed:
            with self.assertRaisesRegex(ytm.DownloadError, "no matching distribution"):
                ytm.update_ytdlp()

            (Path(folder) / "yt-dlp").touch()
            ytm.update_ytdlp()

        self.assertIn("no matching distribution", printed.call_args.args[0])


class MainTests(unittest.TestCase):
    LINK = ytm.Link(url="https://music.youtube.com/playlist?list=PLabc123", playlist_id="PLabc123")

    def run_main(self, *, choose=None, ensure=None, download=None):
        with mock.patch.object(ytm, "choose_link", side_effect=choose, return_value=self.LINK), \
                mock.patch.object(ytm, "ensure_ytdlp", side_effect=ensure) as ensured, \
                mock.patch.object(ytm, "download", side_effect=download, return_value=ytm.EXIT_OK), \
                mock.patch("sys.stderr", io.StringIO()) as errors, \
                contextlib.redirect_stdout(io.StringIO()):
            status = ytm.main([])
        return status, errors.getvalue(), ensured

    def test_returns_the_download_status(self):
        status, _, _ = self.run_main()

        self.assertEqual(status, ytm.EXIT_OK)

    def test_checks_the_link_before_doing_any_setup(self):
        status, _, ensured = self.run_main(choose=ValueError("bad link"))

        self.assertEqual(status, ytm.EXIT_FAILED)
        ensured.assert_not_called()

    def test_reports_download_errors_without_a_traceback(self):
        status, _, _ = self.run_main(download=ytm.DownloadError("nope"))

        self.assertEqual(status, ytm.EXIT_FAILED)

    def test_a_broken_environment_fails_cleanly_with_a_repair_hint(self):
        status, errors, _ = self.run_main(ensure=FileNotFoundError("no python"))

        self.assertEqual(status, ytm.EXIT_FAILED)
        self.assertIn(".venv", errors)

    def test_a_failed_setup_command_fails_cleanly(self):
        broken = subprocess.CalledProcessError(1, ["python", "-m", "venv"])

        status, _, _ = self.run_main(ensure=broken)

        self.assertEqual(status, ytm.EXIT_FAILED)

    def test_no_terminal_to_ask_on_is_an_error_not_an_interruption(self):
        status, errors, _ = self.run_main(choose=EOFError())

        self.assertEqual(status, ytm.EXIT_FAILED)
        self.assertIn("ytm <link>", errors)

    def test_interrupting_returns_the_interrupted_status(self):
        status, _, _ = self.run_main(download=KeyboardInterrupt())

        self.assertEqual(status, ytm.EXIT_INTERRUPTED)


class PlaylistSummaryTests(unittest.TestCase):
    def test_reads_title_and_song_count_from_playlist_info(self):
        info = {"_type": "playlist", "title": "Road Trip", "entries": [{}, {}, {}]}

        self.assertEqual(ytm.summarize(info), ytm.Summary(folder="Road Trip", song_count=3))

    def test_single_songs_go_into_the_singles_folder(self):
        info = {"_type": "video", "title": "Some Song"}

        self.assertEqual(
            ytm.summarize(info), ytm.Summary(folder=ytm.SINGLES_FOLDER, song_count=1)
        )


if __name__ == "__main__":
    unittest.main()
