#Requires -Version 5.1
Set-StrictMode -Version Latest

# BtbN/FFmpeg-Builds — win64-lgpl static (8.1 release branch), NOT gyan GPLv3 essentials.
# Use the floating "latest" tag: stable filenames that always point at the newest 8.1 lgpl build.
# Daily autobuild-* tags are only kept ~14 days and will 404 if pinned.
$Script:FfmpegReleaseTag = 'latest'
$Script:FfmpegZipFileName = 'ffmpeg-n8.1-latest-win64-lgpl-8.1.zip'
$Script:FfmpegChecksumFileName = 'checksums.sha256'
$Script:FfmpegZipUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/$($Script:FfmpegReleaseTag)/$($Script:FfmpegZipFileName)"
$Script:FfmpegChecksumUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/$($Script:FfmpegReleaseTag)/$($Script:FfmpegChecksumFileName)"
$Script:MinFfmpegExeBytes = 50 * 1024 * 1024
$Script:MinFfmpegZipBytes = 100 * 1024 * 1024

function Get-FileSha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }

    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-Sha256FromChecksumsFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChecksumsPath,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    if (-not (Test-Path -LiteralPath $ChecksumsPath)) {
        throw "Checksums file not found: $ChecksumsPath"
    }

    foreach ($line in Get-Content -LiteralPath $ChecksumsPath) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) {
            continue
        }

        # Format: "<sha256>  <filename>" or "<sha256> *<filename>"
        if ($trimmed -match '^(?<hash>[0-9a-fA-F]{64})\s+\*?(?<name>.+)$') {
            $entryName = $Matches['name'].Trim()
            # Paths may be relative (./name or name)
            $entryBase = Split-Path -Leaf ($entryName -replace '^\./', '')
            if ($entryBase -eq $FileName) {
                return $Matches['hash'].ToLowerInvariant()
            }
        }
    }

    throw "SHA256 for $FileName not found in $ChecksumsPath"
}

function Test-FfmpegExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $sizeBytes = (Get-Item -LiteralPath $Path).Length
    if ($sizeBytes -lt $Script:MinFfmpegExeBytes) {
        return $false
    }

    try {
        $null = & $Path -hide_banner -version 2>&1
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
    } catch {
        return $false
    }

    return Test-FfmpegLgplCompliance -Path $Path
}

function Test-FfmpegLgplCompliance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $buildConf = & $Path -hide_banner -buildconf 2>&1 | Out-String
        if ($buildConf -match '--enable-gpl' -or $buildConf -match '--enable-nonfree') {
            Write-Warning 'FFmpeg buildconf contains GPL/nonfree flags.'
            return $false
        }

        $encoders = & $Path -hide_banner -encoders 2>&1 | Out-String
        if ($encoders -match '\blibx264\b' -or $encoders -match '\blibx265\b') {
            Write-Warning 'FFmpeg encoders include GPL-only libx264/libx265.'
            return $false
        }

        if ($encoders -notmatch '\bh264_mf\b' -and $encoders -notmatch '\blibopenh264\b') {
            Write-Warning 'FFmpeg lacks LGPL-safe H.264 encoders (h264_mf / libopenh264).'
            return $false
        }

        $muxers = & $Path -hide_banner -muxers 2>&1 | Out-String
        if ($muxers -notmatch '\bhls\b') {
            Write-Warning 'FFmpeg lacks HLS muxer.'
            return $false
        }
    } catch {
        return $false
    }

    return $true
}

function Get-ExtractedFfmpegExe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExtractRoot
    )

    $binMatches = @(Get-ChildItem -LiteralPath $ExtractRoot -Recurse -Filter 'ffmpeg.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -match '[\\/]bin$' })

    if ($binMatches.Count -eq 0) {
        throw "Could not find bin\ffmpeg.exe under extracted archive at $ExtractRoot"
    }

    return $binMatches[0].FullName
}

function Ensure-FfmpegDependency {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    $repoRoot = $Context.RepoRoot
    $maxAttempts = $Context.MaxAttempts
    $force = [bool]$Context.Force
    $localProxy = $null
    if ($Context.ContainsKey('LocalProxy')) {
        $localProxy = $Context.LocalProxy
    }
    $mirrorPrefix = ''
    if ($Context.ContainsKey('MirrorPrefix') -and $null -ne $Context.MirrorPrefix) {
        $mirrorPrefix = [string]$Context.MirrorPrefix
    }
    $failures = [System.Collections.Generic.List[object]]::new()

    $assetsDir = Join-Path $repoRoot 'assets'
    $ffmpegDest = Join-Path $assetsDir 'ffmpeg.exe'
    $cacheDir = Join-Path $repoRoot 'tool\.cache'
    $zipCachePath = Join-Path $cacheDir $Script:FfmpegZipFileName
    $checksumsPath = Join-Path $cacheDir $Script:FfmpegChecksumFileName
    $displayName = 'FFmpeg LGPL (BtbN win64-lgpl, ffmpeg.exe)'

    if ((Test-FfmpegExecutable -Path $ffmpegDest) -and -not $force) {
        $existingSize = (Get-Item -LiteralPath $ffmpegDest).Length
        Write-Host "$displayName`: already present ($([math]::Round($existingSize / 1MB, 1)) MB, LGPL verification OK)."
        return @{
            Success = $true
            Failures = @()
        }
    }

    if ($force -and (Test-Path -LiteralPath $ffmpegDest)) {
        Write-Host 'Force: removing existing assets\ffmpeg.exe'
        Remove-Item -LiteralPath $ffmpegDest -Force
    }

    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

    # Always refresh checksums.sha256 so SHA matches the current "latest" zip.
    $checksumResult = Invoke-RetryDownload `
        -Id 'ffmpeg/checksums' `
        -DisplayName "$displayName (checksums.sha256)" `
        -Url $Script:FfmpegChecksumUrl `
        -DestinationPath $checksumsPath `
        -MaxAttempts $maxAttempts `
        -MinSizeBytes 64 `
        -TimeoutSec 120 `
        -Force `
        -LocalProxy $localProxy `
        -MirrorPrefix $mirrorPrefix

    if (-not $checksumResult.Success) {
        $failures.Add((New-BootstrapFailure `
            -Id 'ffmpeg' `
            -DisplayName $displayName `
            -Url $Script:FfmpegChecksumUrl `
            -ErrorMessage "Failed to download checksums.sha256: $($checksumResult.LastError)" `
            -ManualHint @"
手动下载 $($Script:FfmpegZipFileName) 从 https://github.com/BtbN/FFmpeg-Builds/releases/tag/latest
选择 win64-lgpl 静态构建（非 gpl），解压 bin\ffmpeg.exe 到 assets\ffmpeg.exe
或在 tool\bootstrap\bootstrap.properties 设 localProxyEnabled=true / 调整 githubMirrorPrefix 后重试。
"@))
        return @{
            Success = $false
            Failures = $failures.ToArray()
        }
    }

    try {
        $expectedSha256 = Get-Sha256FromChecksumsFile `
            -ChecksumsPath $checksumsPath `
            -FileName $Script:FfmpegZipFileName
    } catch {
        $failures.Add((New-BootstrapFailure `
            -Id 'ffmpeg' `
            -DisplayName $displayName `
            -Url $Script:FfmpegChecksumUrl `
            -ErrorMessage $_.Exception.Message `
            -ManualHint 'checksums.sha256 is missing the target zip entry; check that BtbN latest still ships n8.1 win64-lgpl.'))
        return @{
            Success = $false
            Failures = $failures.ToArray()
        }
    }

    Write-Host "$displayName`: expected SHA256 $expectedSha256"

    $needZipDownload = $force
    if (-not $needZipDownload -and (Test-Path -LiteralPath $zipCachePath)) {
        $cachedSize = (Get-Item -LiteralPath $zipCachePath).Length
        if ($cachedSize -lt $Script:MinFfmpegZipBytes) {
            Write-Warning "$displayName`: cached zip too small; re-downloading."
            $needZipDownload = $true
        } else {
            $cachedSha = Get-FileSha256Hex -Path $zipCachePath
            if ($cachedSha -ne $expectedSha256) {
                Write-Warning "$displayName`: cached zip SHA256 mismatch (got $cachedSha); re-downloading."
                $needZipDownload = $true
            } else {
                Write-Host "$displayName`: zip cache SHA256 OK ($([math]::Round($cachedSize / 1MB, 1)) MB)."
            }
        }
    } else {
        $needZipDownload = $true
    }

    if ($needZipDownload) {
        $zipResult = Invoke-RetryDownload `
            -Id 'ffmpeg' `
            -DisplayName "$displayName (zip cache)" `
            -Url $Script:FfmpegZipUrl `
            -DestinationPath $zipCachePath `
            -MaxAttempts $maxAttempts `
            -MinSizeBytes $Script:MinFfmpegZipBytes `
            -TimeoutSec 900 `
            -Force `
            -LocalProxy $localProxy `
            -MirrorPrefix $mirrorPrefix

        if (-not $zipResult.Success) {
            $failures.Add((New-BootstrapFailure `
                -Id 'ffmpeg' `
                -DisplayName $displayName `
                -Url $Script:FfmpegZipUrl `
                -ErrorMessage "$($zipResult.LastError) (after $maxAttempts attempts)" `
                -ManualHint @"
手动下载 $($Script:FfmpegZipFileName) 从 https://github.com/BtbN/FFmpeg-Builds/releases/tag/latest
选择 win64-lgpl 静态构建（非 gpl），解压 bin\ffmpeg.exe 到 assets\ffmpeg.exe
或在 tool\bootstrap\bootstrap.properties 设 localProxyEnabled=true / 调整 githubMirrorPrefix 后重试。
"@))
            return @{
                Success = $false
                Failures = $failures.ToArray()
            }
        }

        $actualSha = Get-FileSha256Hex -Path $zipCachePath
        if ($actualSha -ne $expectedSha256) {
            Remove-FileIfExists -Path $zipCachePath
            $failures.Add((New-BootstrapFailure `
                -Id 'ffmpeg' `
                -DisplayName $displayName `
                -Url $Script:FfmpegZipUrl `
                -ErrorMessage "SHA256 mismatch (expected $expectedSha256, got $actualSha)." `
                -ManualHint "Delete tool\.cache\ffmpeg-n8.1-latest-win64-lgpl-8.1.zip and re-run with -Force."))
            return @{
                Success = $false
                Failures = $failures.ToArray()
            }
        }

        Write-Host "$displayName`: zip SHA256 verified."
    }

    $extractRoot = Join-Path $cacheDir 'ffmpeg-btbn-lgpl-extract'
    try {
        if (Test-Path -LiteralPath $extractRoot) {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

        Write-Host "$displayName`: extracting BtbN lgpl build ..."
        Expand-Archive -LiteralPath $zipCachePath -DestinationPath $extractRoot -Force

        $extractedFfmpeg = Get-ExtractedFfmpegExe -ExtractRoot $extractRoot
        New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
        Copy-Item -LiteralPath $extractedFfmpeg -Destination $ffmpegDest -Force
    } catch {
        Remove-FileIfExists -Path $ffmpegDest
        $failures.Add((New-BootstrapFailure `
            -Id 'ffmpeg' `
            -DisplayName $displayName `
            -Url $Script:FfmpegZipUrl `
            -ErrorMessage $_.Exception.Message `
            -ManualHint "Ensure the BtbN lgpl zip is valid; re-run with -Force."))
        return @{
            Success = $false
            Failures = $failures.ToArray()
        }
    } finally {
        if (Test-Path -LiteralPath $extractRoot) {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-FfmpegExecutable -Path $ffmpegDest)) {
        Remove-FileIfExists -Path $ffmpegDest
        $failures.Add((New-BootstrapFailure `
            -Id 'ffmpeg' `
            -DisplayName $displayName `
            -Url $Script:FfmpegZipUrl `
            -ErrorMessage 'Extracted ffmpeg.exe failed LGPL compliance verification.' `
            -ManualHint "Re-run with -Force or manually place a BtbN win64-lgpl ffmpeg.exe under assets."))
        return @{
            Success = $false
            Failures = $failures.ToArray()
        }
    }

    $finalSize = (Get-Item -LiteralPath $ffmpegDest).Length
    Write-Host "$displayName`: ready at assets\ffmpeg.exe ($([math]::Round($finalSize / 1MB, 1)) MB)."
    return @{
        Success = $true
        Failures = @()
    }
}
