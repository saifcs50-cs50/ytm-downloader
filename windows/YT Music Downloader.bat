@echo off
rem Double-click launcher: downloads the playlist link on the clipboard, or asks for one.
title YT Music Downloader
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ytm.ps1" %*
echo.
pause
