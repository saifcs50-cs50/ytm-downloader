#!/bin/bash
# Build the zip to send to a Windows user. Text files get Windows line endings
# (cmd.exe and old Notepad need them); tests and this script are left out.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIP_PATH="$SOURCE_DIR/../YT-Music-Downloader-Windows.zip"
FOLDER_NAME="YT Music Downloader"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

mkdir "$STAGING/$FOLDER_NAME"
for file in "ytm.ps1" "YT Music Downloader.bat" "YT Music Downloader (MP3).bat" "README.txt"; do
    perl -pe 's/\r?\n/\r\n/' "$SOURCE_DIR/$file" > "$STAGING/$FOLDER_NAME/$file"
done

rm -f "$ZIP_PATH"
(cd "$STAGING" && zip -qr -X "$ZIP_PATH" "$FOLDER_NAME")
echo "Built $ZIP_PATH"
