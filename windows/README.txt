YT MUSIC DOWNLOADER (Windows)
=============================

Downloads a YouTube Music playlist as audio files with cover art.


BEFORE YOU UNZIP (do this once)

Right-click the zip file > Properties > tick "Unblock" at the bottom > OK.
Then right-click the zip > Extract All. This stops Windows from warning
you every time you start the program.

Keep the whole extracted folder together somewhere, for example in
Documents. It does not work from inside the zip.


HOW TO USE

1. In YouTube Music, open your playlist, then Share > Copy link.
2. Double-click "YT Music Downloader".
   It picks up the copied link by itself and starts. If it does not find
   a link, it asks you to paste one: right-click in the window to paste,
   then press Enter.
3. When it finishes, the folder with your songs opens.

Want MP3 files instead? Double-click "YT Music Downloader (MP3)".
MP3 copies go into their own folder, named "(playlist name) (MP3)".

Tip: do not click inside the black window while it is downloading. On
some PCs that pauses it. If it looks frozen, click the window and press
Enter.


WHERE THE SONGS GO

  Music > YouTube Music > (playlist name)

Run it again on the same playlist later and it only downloads the songs
you added since.


THE FIRST TIME

- If Windows shows a security warning when you double-click, choose
  "Run" (or "More info", then "Run anyway"). It appears because the
  program was downloaded from the internet.
- It downloads three tools it needs (about 260 MB in total, FFmpeg is
  the big one). This takes a few minutes and happens only once. They go
  into a "tools" folder next to the program.


IF SOMETHING GOES WRONG

"Could not open that link"
  Check the internet connection first. Otherwise the playlist is
  probably private: in YouTube Music open the playlist, click the pencil
  (Edit), set Privacy to Unlisted, save, and try again.

Some songs are missing
  Videos that were removed or are blocked in your country are skipped.
  Everything else still downloads. Running it again retries the rest.

Every song fails
  YouTube changed something. The program updates its download engine by
  itself once a week. To update it right now, open the "tools" folder,
  delete "yt-dlp.exe", and run the program again.

It says nothing new to download, but you want the songs again
  In that playlist folder, delete the file ".downloaded.txt" and run
  the program again.

The tools will not download, or Windows blocks the program completely
  Some PCs (school or work computers, or ones with Smart App Control
  switched on) do not allow programs like this to run. It cannot be
  used on those.
