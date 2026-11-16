# YT Music Downloader for Windows.
#
# Double-click "YT Music Downloader.bat" instead of running this file directly.
#
#   ytm.ps1                     use the link on the clipboard, or ask for one
#   ytm.ps1 <link>              download that playlist (or single song)
#   ytm.ps1 <link> -Mp3         save mp3 instead of m4a
#   ytm.ps1 <link> -Browser firefox   use that browser's login for private playlists
#
# Songs land in Music\YouTube Music\<playlist name>\ and the folder opens when the
# download finishes. Running it again on the same playlist only fetches new songs.
#
# Written for the Windows PowerShell 5.1 that ships with Windows: plain ASCII only, no
# newer operators, and no double quotes inside arguments handed to other programs.

param(
    [Parameter(Position = 0)][string]$Link = '',
    [switch]$Mp3,
    [string]$Browser = '',
    [switch]$Update,
    [string[]]$YtDlpArguments = @(),
    [switch]$NoRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ToolsDir = Join-Path $PSScriptRoot 'tools'
$YtDlpName = 'yt-dlp.exe'
$UpdateMarkerName = '.last-update'
$UpdateIntervalDays = 7

$YtDlpUrl = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
$DenoUrl = 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip'
$FfmpegUrl = 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'

$MusicDir = Join-Path ([Environment]::GetFolderPath('MyMusic')) 'YouTube Music'
$SinglesFolder = 'Singles'
$FallbackFolder = 'Untitled playlist'
$ArchiveName = '.downloaded.txt'
$DefaultAudioFormat = 'm4a'
$AudioSuffixes = @('.m4a', '.mp3', '.opus', '.ogg', '.webm')
# Windows refuses paths over 260 characters, so keep both parts of the path short.
# 44 leaves room for the " (MP3)" folder suffix within 50 characters.
$MaxFolderNameLength = 44
$MaxFileNameLength = '100'
$DownloadThreads = '4'
$MaxAttempts = 2

$FileTemplate = '%(artist,uploader|Unknown)s - %(title)s.%(ext)s'
$ProgressTemplate = 'before_dl:[%(playlist_index|1)s/%(n_entries|1)s] %(title)s'
# One line: the song count, a space, then the title as ASCII-only JSON.
$SummaryTemplate = '%(playlist_count)s %(playlist_title)j'
# YouTube thumbnails are 16:9; crop them to the square cover a music player expects.
# (a+b-abs(a-b))/2 is min(a,b), written without the commas and quotes ffmpeg would need.
$SquareSide = '(iw+ih-abs(iw-ih))/2'
$SquareCoverArgs = "ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -vf crop=${SquareSide}:${SquareSide}"

$MusicHost = 'music.youtube.com'
$ShortHost = 'youtu.be'
$AllowedHosts = @($MusicHost, $ShortHost, 'youtube.com', 'www.youtube.com', 'm.youtube.com')
$IdPattern = '^[A-Za-z0-9_-]{2,}$'
$BarePlaylistPattern = '^(LM|LL|(PL|OLAK5uy_|RD|UU|FL)[A-Za-z0-9_-]{8,})$'
$UnsafeNamePattern = '[\\/:*?"<>|\x00-\x1f]'
$ReservedNamePattern = '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$'

$PrivateHint = 'Check the internet connection. If the playlist is private, open it in YouTube Music and set it to Unlisted, then try again.'
$RetryNote = 'Some songs failed. Trying those again...'
$FailureNote = 'Some songs could not be downloaded: they are unavailable, or there was a network or YouTube problem. See the messages above.'
$EmptyFolderNote = "Nothing new to download. Songs already fetched are listed in $ArchiveName inside this folder; delete that file to download them again."
$RepairHint = "Check the internet connection and try again. If it keeps failing, delete the 'tools' folder next to this program and run it again."

$ExitOk = 0
$ExitFailed = 1
$script:ExitCode = $ExitFailed

# Links

function Get-QueryValue([string]$Query, [string]$Key) {
    foreach ($pair in $Query.TrimStart('?').Split('&')) {
        $parts = @($pair -split '=', 2)
        if ($parts.Count -eq 2 -and $parts[0] -ceq $Key) {
            return [Uri]::UnescapeDataString($parts[1])
        }
    }
    return ''
}

function New-PlaylistLink([string]$PlaylistId) {
    if ($PlaylistId -cnotmatch $IdPattern) { throw 'That playlist link looks broken.' }
    return [pscustomobject]@{
        Url        = "https://$MusicHost/playlist?list=$PlaylistId"
        PlaylistId = $PlaylistId
    }
}

# Turn whatever was pasted into a clean playlist or song link.
function ConvertTo-Link([string]$Text) {
    $candidate = $Text.Trim()
    if (-not $candidate) { throw 'No link given.' }
    if ($candidate -cmatch $BarePlaylistPattern) { return New-PlaylistLink $candidate }

    if ($candidate -notmatch '://') { $candidate = "https://$candidate" }
    $uri = $null
    if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or
        $AllowedHosts -notcontains $uri.Host.ToLowerInvariant()) {
        throw 'That is not a YouTube or YouTube Music link.'
    }

    $playlistId = Get-QueryValue $uri.Query 'list'
    if ($playlistId) { return New-PlaylistLink $playlistId }

    if ($uri.Host -eq $ShortHost) { $videoId = $uri.AbsolutePath.Trim('/') }
    else { $videoId = Get-QueryValue $uri.Query 'v' }
    if ($videoId -cnotmatch $IdPattern) { throw 'That link has no playlist or song in it.' }
    return [pscustomobject]@{ Url = "https://$MusicHost/watch?v=$videoId"; PlaylistId = '' }
}

function Read-ClipboardText {
    try { return [string](Get-Clipboard -Raw) }
    catch { return '' }  # no usable clipboard: Select-Link falls back to asking
}

function Read-LinkFromUser {
    return Read-Host 'Paste the playlist link and press Enter'
}

function Select-Link([string]$Argument) {
    if ($Argument) { return ConvertTo-Link $Argument }
    try {
        $link = ConvertTo-Link (Read-ClipboardText)
        Write-Host "Using the link on your clipboard:`n  $($link.Url)"
        return $link
    } catch {
        Write-Host 'No YouTube link found on the clipboard.'
    }
    while ($true) {
        try { return ConvertTo-Link (Read-LinkFromUser) }
        catch { Write-Host "  $($_.Exception.Message) Try again." }
    }
}

# Folders

function Get-SafeFolderName([string]$Title) {
    $cleaned = ($Title -replace $UnsafeNamePattern, '-').Trim().TrimStart('. ')
    if ($cleaned.Length -gt $MaxFolderNameLength) {
        $cleaned = $cleaned.Substring(0, $MaxFolderNameLength)
        # Do not leave half an emoji behind when the cut lands inside one.
        if ([char]::IsHighSurrogate($cleaned[$cleaned.Length - 1])) {
            $cleaned = $cleaned.Substring(0, $cleaned.Length - 1)
        }
    }
    $cleaned = $cleaned.TrimEnd('. ')
    if (-not $cleaned.Trim('- ')) { return $FallbackFolder }
    if ($cleaned -match $ReservedNamePattern) { return "_$cleaned" }
    return $cleaned
}

function ConvertTo-Summary([string]$Line) {
    if ($Line -notmatch '^(\d+|NA) (.+)$') {
        throw 'Could not read the playlist. It may be empty.'
    }
    $count = 0
    if ($Matches[1] -ne 'NA') { $count = [int]$Matches[1] }
    $title = ('{"title":' + $Matches[2] + '}' | ConvertFrom-Json).title
    return [pscustomobject]@{ Folder = Get-SafeFolderName ([string]$title); SongCount = $count }
}

function Get-SongCount([string]$Folder) {
    $songs = Get-ChildItem -LiteralPath $Folder -File |
        Where-Object { $AudioSuffixes -contains $_.Extension.ToLowerInvariant() }
    return @($songs).Count
}

function Open-Folder([string]$Folder) {
    Invoke-Item -LiteralPath $Folder
}

# yt-dlp arguments

function Get-CookieArguments([string]$Browser) {
    if ($Browser) { return @('--cookies-from-browser', $Browser) }
    return @()
}

# Each format gets its own folder. Converting to mp3 deletes the m4a it was made from,
# so in a shared folder an MP3 run would destroy the songs of an earlier M4A run.
function Get-FolderName([string]$Base, [string]$AudioFormat) {
    if ($AudioFormat -eq $DefaultAudioFormat) { return $Base }
    return "$Base ($($AudioFormat.ToUpperInvariant()))"
}

function Get-SummaryArguments($Link, [string]$Browser = '') {
    return @('--flat-playlist', '--playlist-items', '1', '--no-warnings', '--print', $SummaryTemplate) +
        @(Get-CookieArguments $Browser) + @('--', $Link.Url)
}

# The yt-dlp call for one link. Paths are relative: run it inside the song folder.
function Get-DownloadArguments($Link, [string]$AudioFormat, [string]$Browser = '', [string[]]$ExtraArguments = @()) {
    if ($Link.PlaylistId) {
        $playlistArguments = @('--yes-playlist', '--download-archive', $ArchiveName)
    }
    else { $playlistArguments = @('--no-playlist') }
    return @(
        '--format', 'bestaudio[ext=m4a]/bestaudio/best',
        '--extract-audio', '--audio-format', $AudioFormat, '--audio-quality', '0',
        '--embed-metadata', '--embed-thumbnail', '--convert-thumbnails', 'jpg',
        '--postprocessor-args', $SquareCoverArgs,
        '--output', $FileTemplate, '--trim-filenames', $MaxFileNameLength,
        '--concurrent-fragments', $DownloadThreads,
        '--quiet', '--progress', '--no-warnings', '--no-simulate',
        '--print', $ProgressTemplate
    ) + $playlistArguments + @(Get-CookieArguments $Browser) + @($ExtraArguments) + @('--', $Link.Url)
}

# Tools (yt-dlp, FFmpeg, Deno)

function Test-UpdateDue([string]$Marker, [datetime]$Now) {
    if (-not (Test-Path -LiteralPath $Marker)) { return $true }
    return ($Now - (Get-Item -LiteralPath $Marker).LastWriteTime).TotalDays -gt $UpdateIntervalDays
}

function Save-Download([string]$Url, [string]$Target, [string]$Label) {
    Write-Host "Downloading $Label..."
    $partial = "$Target.part"
    if (Get-Command 'curl.exe' -ErrorAction SilentlyContinue) {
        & curl.exe --fail --location --progress-bar --output $partial $Url
        if ($LASTEXITCODE -ne 0) { throw "Could not download $Label." }
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'  # the progress bar makes this many times slower
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
    }
    Move-Item -LiteralPath $partial -Destination $Target -Force
}

function Expand-ToolArchive([string]$Zip, [string[]]$Names, [string]$Destination) {
    $unpacked = Join-Path $Destination 'unpack'
    try {
        Expand-Archive -LiteralPath $Zip -DestinationPath $unpacked -Force
        foreach ($name in $Names) {
            $found = Get-ChildItem -LiteralPath $unpacked -Recurse -File -Filter $name | Select-Object -First 1
            if (-not $found) { throw "The download did not contain $name." }
            Move-Item -LiteralPath $found.FullName -Destination (Join-Path $Destination $name) -Force
        }
    } finally {
        if (Test-Path -LiteralPath $unpacked) { Remove-Item -LiteralPath $unpacked -Recurse -Force }
    }
}

function Install-FromZip([string]$Url, [string[]]$Names, [string]$Label) {
    $zip = Join-Path $ToolsDir 'download.zip'
    try {
        Save-Download $Url $zip $Label
        Write-Host '  Unpacking...'
        Expand-ToolArchive -Zip $zip -Names $Names -Destination $ToolsDir
    } finally {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    }
}

function Test-Tool([string]$Name) {
    return Test-Path -LiteralPath (Join-Path $ToolsDir $Name)
}

function Install-Tools {
    [IO.Directory]::CreateDirectory($ToolsDir) | Out-Null
    if (-not (Test-Tool $YtDlpName)) {
        Write-Host 'First run: fetching the download tools. This happens only once.'
        Save-Download $YtDlpUrl (Join-Path $ToolsDir $YtDlpName) 'yt-dlp (18 MB)'
        Set-Content -LiteralPath (Join-Path $ToolsDir $UpdateMarkerName) -Value ''
    }
    if (-not (Test-Tool 'deno.exe')) {
        Install-FromZip $DenoUrl @('deno.exe') 'Deno (43 MB)'
    }
    if (-not ((Test-Tool 'ffmpeg.exe') -and (Test-Tool 'ffprobe.exe'))) {
        Install-FromZip $FfmpegUrl @('ffmpeg.exe', 'ffprobe.exe') 'FFmpeg (200 MB, the slow one)'
    }
}

# Keep yt-dlp current: YouTube breaks old versions within weeks.
function Update-Engine([switch]$Force) {
    $marker = Join-Path $ToolsDir $UpdateMarkerName
    if (-not ($Force -or (Test-UpdateDue -Marker $marker -Now (Get-Date)))) { return }
    Write-Host 'Checking for a newer download engine (yt-dlp)...'
    & (Join-Path $ToolsDir $YtDlpName) --update
    if ($LASTEXITCODE -eq 0) { Set-Content -LiteralPath $marker -Value '' }
    else { Write-Host '  Update failed (offline?). Carrying on with the installed version.' }
}

# Download

function Get-PlaylistSummary($Link, [string]$Browser) {
    if (-not $Link.PlaylistId) {
        return [pscustomobject]@{ Folder = $SinglesFolder; SongCount = 1 }
    }
    # Errors from yt-dlp go straight to the window; only the summary line is captured.
    $lines = @(& (Join-Path $ToolsDir $YtDlpName) (Get-SummaryArguments $Link $Browser))
    if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) {
        throw "Could not open that link.`n$PrivateHint"
    }
    return ConvertTo-Summary ([string]$lines[0])
}

# Sets $script:ExitCode instead of returning it: a returned value would make PowerShell
# capture yt-dlp's live progress output instead of showing it.
function Invoke-Download($Link, [string]$AudioFormat, [string]$Browser, [string[]]$ExtraArguments) {
    $summary = Get-PlaylistSummary $Link $Browser
    $folder = Join-Path $MusicDir (Get-FolderName $summary.Folder $AudioFormat)
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    $songsBefore = Get-SongCount $folder
    Write-Host "`n$($summary.Folder): $($summary.SongCount) song(s)`nSaving to $folder`n"

    $arguments = Get-DownloadArguments $Link $AudioFormat $Browser $ExtraArguments
    Push-Location -LiteralPath $folder
    try {
        # YouTube sometimes refuses a download that works seconds later, so go round
        # again once. Finished songs are skipped, so only the failures are retried.
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            & (Join-Path $ToolsDir $YtDlpName) $arguments
            if ($LASTEXITCODE -eq 0 -or $attempt -eq $MaxAttempts) { break }
            Write-Host "`n$RetryNote"
        }
    } finally { Pop-Location }
    $downloadFailed = $LASTEXITCODE -ne 0

    $songsAfter = Get-SongCount $folder
    Write-Host "`nDone: $($songsAfter - $songsBefore) new song(s), $songsAfter in the folder."
    if ($downloadFailed) { Write-Host $FailureNote }
    elseif ($songsAfter -eq $songsBefore -and $Link.PlaylistId) {
        Write-Host $EmptyFolderNote
    }
    Open-Folder $folder
    if ($downloadFailed) { $script:ExitCode = $ExitFailed } else { $script:ExitCode = $ExitOk }
}

function Invoke-Main {
    $script:ExitCode = $ExitFailed
    try {
        $chosen = Select-Link $Link
        try {
            Install-Tools
            Update-Engine -Force:$Update
        } catch {
            throw "$($_.Exception.Message)`n$RepairHint"
        }
        # yt-dlp finds ffmpeg, ffprobe and deno through PATH.
        $env:PATH = $ToolsDir + [IO.Path]::PathSeparator + $env:PATH
        if ($Mp3) { $audioFormat = 'mp3' } else { $audioFormat = $DefaultAudioFormat }
        Invoke-Download $chosen $audioFormat $Browser $YtDlpArguments
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if (-not $NoRun) {
    Invoke-Main
    exit $script:ExitCode
}
