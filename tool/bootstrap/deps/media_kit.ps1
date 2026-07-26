#Requires -Version 5.1
Set-StrictMode -Version Latest

# Must match media_kit_libs_windows_video 1.0.11 windows/CMakeLists.txt
$Script:MediaKitArchives = @(
    @{
        Id = 'media_kit/libmpv'
        Name = 'libmpv'
        FileName = 'mpv-dev-x86_64-20230924-git-652a1dd.7z'
        Url = 'https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/mpv-dev-x86_64-20230924-git-652a1dd.7z'
        Md5 = 'a832ef24b3a6ff97cd2560b5b9d04cd8'
        EmptyDirName = 'libmpv'
    },
    @{
        Id = 'media_kit/ANGLE'
        Name = 'ANGLE'
        FileName = 'ANGLE.7z'
        Url = 'https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z'
        Md5 = 'e866f13e8d552348058afaafe869b1ed'
        EmptyDirName = 'ANGLE'
    }
)

function Test-DirectoryExistsAndNotEmpty {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    return @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count -gt 0
}

function Remove-EmptyNativeDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildDir,

        [Parameter(Mandatory = $true)]
        [string]$DirName
    )

    $target = Join-Path $BuildDir $DirName
    if (-not (Test-Path -LiteralPath $target)) {
        return
    }

    if (-not (Test-DirectoryExistsAndNotEmpty -Path $target)) {
        Write-Host "Removing empty directory: $target"
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

function Ensure-MediaKitDependency {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    $repoRoot = $Context.RepoRoot
    $maxAttempts = $Context.MaxAttempts
    $force = [bool]$Context.Force
    $failures = [System.Collections.Generic.List[object]]::new()

    $buildDir = Join-Path $repoRoot 'build\windows\x64'
    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

    Write-Host "Preparing media_kit native archives in: $buildDir"

    foreach ($archive in $Script:MediaKitArchives) {
        Remove-EmptyNativeDirectory -BuildDir $buildDir -DirName $archive.EmptyDirName

        $destination = Join-Path $buildDir $archive.FileName
        $displayName = "$($archive.Name) ($($archive.FileName))"

        $result = Invoke-RetryDownload `
            -Id $archive.Id `
            -DisplayName $displayName `
            -Url $archive.Url `
            -DestinationPath $destination `
            -MaxAttempts $maxAttempts `
            -ExpectedMd5 $archive.Md5 `
            -MinSizeBytes 1024 `
            -TimeoutSec 600 `
            -Force:$force `
            -LocalProxy $Context.LocalProxy `
            -MirrorPrefix $Context.MirrorPrefix

        if (-not $result.Success) {
            $failures.Add((New-BootstrapFailure `
                -Id $archive.Id `
                -DisplayName $displayName `
                -Url $archive.Url `
                -ErrorMessage "$($result.LastError) (after $maxAttempts attempts)" `
                -ManualHint @"
检查 github.com 访问；安装 7-Zip (https://www.7-zip.org/)；
flutter clean 后删除 build\windows\x64\ 下 *.7z、libmpv\、ANGLE\ 再重试。
或在 tool\bootstrap\bootstrap.properties 设 localProxyEnabled=true / 调整 githubMirrorPrefix。
"@))
        }
    }

    if ($failures.Count -gt 0) {
        return @{
            Success = $false
            Failures = $failures.ToArray()
        }
    }

    Write-Host 'media_kit: all native archives ready.'
    return @{
        Success = $true
        Failures = @()
    }
}
