@echo off
rem Same as "YT Music Downloader.bat", but saves MP3 files instead of M4A.
title YT Music Downloader (MP3)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ytm.ps1" -Mp3 %*
echo.
pause
