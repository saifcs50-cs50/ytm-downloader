# Tests for ytm.ps1. Run with:  powershell -ExecutionPolicy Bypass -File ytm.tests.ps1
# Plain assertions (no Pester) so it runs on a stock Windows PowerShell 5.1 and on pwsh.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ytm.ps1') -NoRun

$script:Failures = 0
$script:Passes = 0

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:Passes++
    } catch {
        $script:Failures++
        Write-Host "FAIL: $Name`n      $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal($Actual, $Expected) {
    if ("$Actual" -cne "$Expected") { throw "expected <$Expected> but got <$Actual>" }
}

function Assert-True($Condition, [string]$Message = 'expected condition to be true') {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Body, [string]$Pattern = '.') {
    try { & $Body } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "threw, but message <$($_.Exception.Message)> does not match <$Pattern>"
        }
        return
    }
    throw 'expected an error but none was thrown'
}

$Playlist = 'https://music.youtube.com/playlist?list=PLabc12345678'

# ConvertTo-Link

Test-Case 'keeps only the list id from a YouTube Music playlist link' {
    $link = ConvertTo-Link 'https://music.youtube.com/playlist?list=PLabc123_-x&si=tracking'
    Assert-Equal $link.Url 'https://music.youtube.com/playlist?list=PLabc123_-x'
    Assert-Equal $link.PlaylistId 'PLabc123_-x'
}

Test-Case 'treats a song link with a list parameter as the whole playlist' {
    $link = ConvertTo-Link 'https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc123'
    Assert-Equal $link.Url 'https://music.youtube.com/playlist?list=PLabc123'
}

Test-Case 'accepts regular YouTube playlist links' {
    Assert-Equal (ConvertTo-Link 'https://www.youtube.com/playlist?list=OLAK5uy_abc').PlaylistId 'OLAK5uy_abc'
}

Test-Case 'accepts a bare playlist id' {
    $link = ConvertTo-Link 'PLexampleplaylistid0123456789'
    Assert-Equal $link.Url 'https://music.youtube.com/playlist?list=PLexampleplaylistid0123456789'
}

Test-Case 'accepts a single song link without a playlist' {
    $link = ConvertTo-Link 'https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=x'
    Assert-Equal $link.Url 'https://music.youtube.com/watch?v=dQw4w9WgXcQ'
    Assert-Equal $link.PlaylistId ''
}

Test-Case 'accepts a short youtu.be link' {
    Assert-Equal (ConvertTo-Link 'https://youtu.be/dQw4w9WgXcQ?si=x').Url 'https://music.youtube.com/watch?v=dQw4w9WgXcQ'
}

Test-Case 'accepts a link pasted without https' {
    Assert-Equal (ConvertTo-Link 'music.youtube.com/playlist?list=PLabc123').PlaylistId 'PLabc123'
}

Test-Case 'ignores surrounding whitespace' {
    Assert-Equal (ConvertTo-Link "  $Playlist`r`n").PlaylistId 'PLabc12345678'
}

Test-Case 'keeps playlist ids case-sensitive' {
    Assert-Equal (ConvertTo-Link 'https://music.youtube.com/playlist?list=PLaBcDeF').PlaylistId 'PLaBcDeF'
}

Test-Case 'rejects links from other sites' {
    Assert-Throws { ConvertTo-Link 'https://example.com/playlist?list=PLabc123' } 'not a YouTube'
}

Test-Case 'rejects lookalike hosts' {
    Assert-Throws { ConvertTo-Link 'https://youtube.com.evil.example/playlist?list=PLabc123' }
    Assert-Throws { ConvertTo-Link 'https://music.youtube.com@evil.example/playlist?list=PLabc123' }
}

Test-Case 'rejects text that is not a link' {
    Assert-Throws { ConvertTo-Link 'my favourite songs' }
}

Test-Case 'rejects empty input' {
    Assert-Throws { ConvertTo-Link '   ' } 'No link'
    Assert-Throws { ConvertTo-Link $null } 'No link'
}

Test-Case 'rejects ids with characters outside the id alphabet' {
    Assert-Throws { ConvertTo-Link 'https://music.youtube.com/playlist?list=--exec=rm' }
    Assert-Throws { ConvertTo-Link 'https://music.youtube.com/playlist?list=PL"abc' }
}

Test-Case 'option-like ids only ever appear inside a YouTube Music url' {
    $link = ConvertTo-Link 'https://music.youtube.com/playlist?list=--help'
    Assert-True ($link.Url.StartsWith('https://music.youtube.com/'))
}

# Get-SafeFolderName

Test-Case 'replaces characters Windows does not allow in folder names' {
    Assert-Equal (Get-SafeFolderName 'Rock/Pop: Best | "Hits" <2024>?*') 'Rock-Pop- Best - -Hits- -2024---'
}

Test-Case 'strips leading and trailing dots and spaces' {
    Assert-Equal (Get-SafeFolderName ' ..hidden.. ') 'hidden'
}

Test-Case 'falls back when nothing usable is left' {
    Assert-Equal (Get-SafeFolderName '///') $FallbackFolder
    Assert-Equal (Get-SafeFolderName '') $FallbackFolder
    Assert-Equal (Get-SafeFolderName $null) $FallbackFolder
}

Test-Case 'avoids reserved Windows device names' {
    foreach ($title in 'CON', 'nul', 'COM1', 'LPT9', 'aux.txt') {
        Assert-True ((Get-SafeFolderName $title) -cne $title) "<$title> was kept as is"
    }
    Assert-Equal (Get-SafeFolderName 'Concert') 'Concert'
}

Test-Case 'caps the length so file paths stay under the Windows limit' {
    $name = Get-SafeFolderName ('x' * 300)
    Assert-True ($name.Length -le $MaxFolderNameLength)
}

Test-Case 'a name cut at the length cap does not end in a dot or space' {
    $name = Get-SafeFolderName (('y' * ($MaxFolderNameLength - 1)) + '. tail')
    Assert-True ($name -notmatch '[. ]$') "<$name> ends in a dot or space"
}

Test-Case 'a name cut at the length cap does not end in half an emoji' {
    $emoji = [char]::ConvertFromUtf32(0x1F3B5)
    $name = Get-SafeFolderName (('z' * ($MaxFolderNameLength - 1)) + $emoji + ' tail')
    Assert-True (-not [char]::IsHighSurrogate($name[$name.Length - 1])) 'ends in a lone surrogate'
}

Test-Case 'hostile titles stay a single folder inside the music folder' {
    foreach ($title in '..', '.', '...', '../..', '..\..', 'a/../../b', "`0", 'C:\Windows', '') {
        $name = Get-SafeFolderName $title
        Assert-True ($name -notmatch '[\\/:]') "<$title> gave <$name>"
        Assert-True (@('', '.', '..') -notcontains $name) "<$title> gave <$name>"
    }
}

# Get-DownloadArguments

$PlaylistLink = ConvertTo-Link $Playlist
$SongLink = ConvertTo-Link 'https://music.youtube.com/watch?v=dQw4w9WgXcQ'

function Get-ValueAfter([string[]]$Arguments, [string]$Option) {
    return $Arguments[[array]::IndexOf($Arguments, $Option) + 1]
}

Test-Case 'puts the link last after an option terminator' {
    $arguments = @(Get-DownloadArguments -Link $PlaylistLink -AudioFormat 'm4a')
    Assert-Equal ($arguments[-2..-1] -join ' ') "-- $($PlaylistLink.Url)"
}

Test-Case 'tracks finished songs so reruns only fetch new ones' {
    $arguments = @(Get-DownloadArguments -Link $PlaylistLink -AudioFormat 'm4a')
    Assert-Equal (Get-ValueAfter $arguments '--download-archive') $ArchiveName
    Assert-True ($arguments -contains '--yes-playlist')
}

# Converting to mp3 deletes the m4a it was made from, so sharing a folder with an
# earlier m4a download would destroy those files.
Test-Case 'mp3 downloads get their own folder; the default format uses the plain name' {
    Assert-Equal (Get-FolderName 'Road Trip' 'm4a') 'Road Trip'
    Assert-Equal (Get-FolderName 'Road Trip' 'mp3') 'Road Trip (MP3)'
}

Test-Case 'the longest folder name plus the format suffix stays within the path budget' {
    $name = Get-FolderName (Get-SafeFolderName ('x' * 300)) 'mp3'
    Assert-True ($name.Length -le 50) "<$name> is $($name.Length) characters"
}

Test-Case 'does not keep an archive for single songs' {
    $arguments = @(Get-DownloadArguments -Link $SongLink -AudioFormat 'm4a')
    Assert-True ($arguments -notcontains '--download-archive')
    Assert-True ($arguments -contains '--no-playlist')
}

Test-Case 'requests the chosen audio format' {
    $arguments = @(Get-DownloadArguments -Link $PlaylistLink -AudioFormat 'mp3')
    Assert-Equal (Get-ValueAfter $arguments '--audio-format') 'mp3'
}

Test-Case 'uses browser cookies only when asked' {
    Assert-True (@(Get-DownloadArguments -Link $PlaylistLink -AudioFormat 'm4a') -notcontains '--cookies-from-browser')
    $arguments = @(Get-DownloadArguments -Link $PlaylistLink -AudioFormat 'm4a' -Browser 'firefox')
    Assert-Equal (Get-ValueAfter $arguments '--cookies-from-browser') 'firefox'
}

Test-Case 'passes extra options through before the link' {
    $arguments = @(Get-DownloadArguments -Link $PlaylistLink -AudioFormat 'm4a' -ExtraArguments '--playlist-items', '1-3')
    Assert-Equal ($arguments[-4..-1] -join ' ') "--playlist-items 1-3 -- $($PlaylistLink.Url)"
}

Test-Case 'uses a relative file template so folder names need no escaping' {
    $template = Get-ValueAfter @(Get-DownloadArguments -Link $PlaylistLink -AudioFormat 'm4a') '--output'
    Assert-True (-not [IO.Path]::IsPathRooted($template))
}

# Windows PowerShell 5.1 does not escape quotes when it builds a program's command line,
# and a trailing backslash would swallow the closing quote it adds around an argument.
Test-Case 'no argument contains a double quote or ends in a backslash' {
    $all = @(Get-DownloadArguments -Link $PlaylistLink -AudioFormat 'mp3' -Browser 'firefox') +
        @(Get-SummaryArguments -Link $PlaylistLink -Browser 'firefox')
    foreach ($argument in $all) {
        Assert-True ($argument -notmatch '"') "double quote in <$argument>"
        Assert-True ($argument -notmatch '\\$') "trailing backslash in <$argument>"
    }
}

Test-Case 'the summary query also ends with the terminator and the link' {
    $arguments = @(Get-SummaryArguments -Link $PlaylistLink)
    Assert-Equal ($arguments[-2..-1] -join ' ') "-- $($PlaylistLink.Url)"
}

# ConvertTo-Summary

Test-Case 'reads the song count and title from the summary line' {
    $summary = ConvertTo-Summary '89 "Road Trip"'
    Assert-Equal $summary.Folder 'Road Trip'
    Assert-Equal $summary.SongCount 89
}

Test-Case 'decodes escaped non-English titles' {
    Assert-Equal (ConvertTo-Summary '3 "Caf\u00e9 \u2013 Mix"').Folder "Caf$([char]0xE9) $([char]0x2013) Mix"
}

Test-Case 'makes the title safe to use as a folder' {
    Assert-Equal (ConvertTo-Summary '2 "A | B"').Folder 'A - B'
}

Test-Case 'copes with a missing count or title' {
    $summary = ConvertTo-Summary 'NA "NA"'
    Assert-Equal $summary.SongCount 0
    Assert-Equal (ConvertTo-Summary '5 null').Folder $FallbackFolder
}

Test-Case 'rejects an empty or unreadable summary' {
    Assert-Throws { ConvertTo-Summary '' }
    Assert-Throws { ConvertTo-Summary $null }
    Assert-Throws { ConvertTo-Summary 'something unexpected' }
}

# Test-UpdateDue

$Scratch = Join-Path ([IO.Path]::GetTempPath()) ("ytm-tests-" + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($Scratch) | Out-Null
try {
    $marker = Join-Path $Scratch 'marker'

    Test-Case 'an update is due when the marker is missing' {
        Assert-True (Test-UpdateDue -Marker $marker -Now (Get-Date))
    }

    Set-Content -LiteralPath $marker -Value ''
    $written = (Get-Item -LiteralPath $marker).LastWriteTime

    Test-Case 'no update is due shortly after the last one' {
        Assert-True (-not (Test-UpdateDue -Marker $marker -Now $written.AddMinutes(1)))
    }

    Test-Case 'an update is due after the interval has passed' {
        Assert-True (Test-UpdateDue -Marker $marker -Now $written.AddDays($UpdateIntervalDays + 1))
    }

    # Get-SongCount

    Test-Case 'counts audio files and ignores partial and hidden files' {
        $folder = Join-Path $Scratch 'songs [mix]'
        [IO.Directory]::CreateDirectory($folder) | Out-Null
        foreach ($name in 'a.m4a', 'b.MP3', 'c.m4a.part', '.downloaded.txt', 'cover.jpg') {
            Set-Content -LiteralPath (Join-Path $folder $name) -Value ''
        }
        Assert-Equal (Get-SongCount $folder) 2
    }

    # Expand-ToolArchive

    Test-Case 'pulls the named programs out of a nested zip and cleans up' {
        $source = Join-Path $Scratch 'ffmpeg-build'
        [IO.Directory]::CreateDirectory((Join-Path $source 'bin')) | Out-Null
        foreach ($name in 'ffmpeg.exe', 'ffprobe.exe', 'ffplay.exe') {
            Set-Content -LiteralPath (Join-Path (Join-Path $source 'bin') $name) -Value $name
        }
        $zip = Join-Path $Scratch 'build.zip'
        Compress-Archive -Path $source -DestinationPath $zip
        $tools = Join-Path $Scratch 'tools'
        [IO.Directory]::CreateDirectory($tools) | Out-Null

        Expand-ToolArchive -Zip $zip -Names 'ffmpeg.exe', 'ffprobe.exe' -Destination $tools

        Assert-True (Test-Path -LiteralPath (Join-Path $tools 'ffmpeg.exe'))
        Assert-True (Test-Path -LiteralPath (Join-Path $tools 'ffprobe.exe'))
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tools 'ffplay.exe')))
        Assert-Equal (@(Get-ChildItem -LiteralPath $tools).Count) 2
    }

    Test-Case 'fails clearly when the zip does not contain the program' {
        $zip = Join-Path $Scratch 'build.zip'
        $tools = Join-Path $Scratch 'tools2'
        [IO.Directory]::CreateDirectory($tools) | Out-Null
        Assert-Throws { Expand-ToolArchive -Zip $zip -Names 'deno.exe' -Destination $tools } 'deno.exe'
    }
} finally {
    Remove-Item -LiteralPath $Scratch -Recurse -Force
}

# Select-Link (clipboard and prompt are replaced with stand-ins)

Test-Case 'prefers the link given on the command line' {
    function Read-ClipboardText { throw 'clipboard must not be read' }
    Assert-Equal (Select-Link $Playlist).PlaylistId 'PLabc12345678'
}

Test-Case 'uses the clipboard when it holds a YouTube link' {
    function Read-ClipboardText { return $Playlist }
    function Read-LinkFromUser { throw 'must not ask' }
    Assert-Equal (Select-Link '').PlaylistId 'PLabc12345678'
}

Test-Case 'asks until a valid link is typed when the clipboard is unrelated' {
    $script:Answers = New-Object System.Collections.Queue
    $script:Answers.Enqueue('not a link')
    $script:Answers.Enqueue($Playlist)
    function Read-ClipboardText { return 'shopping list' }
    function Read-LinkFromUser { return $script:Answers.Dequeue() }
    Assert-Equal (Select-Link '').PlaylistId 'PLabc12345678'
    Assert-Equal $script:Answers.Count 0
}

# The shipped files must survive Windows PowerShell 5.1 and cmd.exe

Test-Case 'shipped scripts are plain ASCII (5.1 reads files without a BOM as ANSI)' {
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in '.ps1', '.bat', '.txt' }) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $bad = @($bytes | Where-Object { $_ -gt 127 })
        Assert-True ($bad.Count -eq 0) "$($file.Name) has $($bad.Count) non-ASCII bytes"
    }
}

Test-Case 'the script avoids syntax that Windows PowerShell 5.1 does not have' {
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ytm.ps1') -Raw
    foreach ($pattern in '\?\?', '&&', '\|\|', '\?\.', '\$IsWindows', '\$IsMacOS', '-Parallel') {
        Assert-True ($source -notmatch $pattern) "found <$pattern>"
    }
}

Write-Host "$script:Passes passed, $script:Failures failed"
if ($script:Failures -gt 0) { exit 1 }
