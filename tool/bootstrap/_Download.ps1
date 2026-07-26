#Requires -Version 5.1
Set-StrictMode -Version Latest

function Resolve-RepoRoot {
    param(
        [Parameter(Mandatory = $false)]
        [string]$RepoRoot = '',

        [Parameter(Mandatory = $false)]
        [string]$ScriptRoot = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        return (Resolve-Path -LiteralPath $RepoRoot).Path
    }

    if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
        return (Resolve-Path (Join-Path $ScriptRoot '..')).Path
    }

    return (Get-Location).Path
}

function Get-BootstrapPropertiesPath {
    param(
        [Parameter(Mandatory = $false)]
        [string]$BootstrapDir = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($BootstrapDir)) {
        return (Join-Path $BootstrapDir 'bootstrap.properties')
    }

    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here)) {
        $here = Join-Path (Get-Location).Path 'tool\bootstrap'
    }
    return (Join-Path $here 'bootstrap.properties')
}

function Get-BootstrapPropertyMap {
    param(
        [Parameter(Mandatory = $false)]
        [string]$PropertiesPath = ''
    )

    $map = @{}
    if ([string]::IsNullOrWhiteSpace($PropertiesPath)) {
        $PropertiesPath = Get-BootstrapPropertiesPath
    }
    if (-not (Test-Path -LiteralPath $PropertiesPath)) {
        return $map
    }

    foreach ($line in Get-Content -LiteralPath $PropertiesPath) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) {
            continue
        }
        $eq = $trimmed.IndexOf('=')
        if ($eq -lt 1) {
            continue
        }
        $key = $trimmed.Substring(0, $eq).Trim()
        $value = $trimmed.Substring($eq + 1).Trim()
        $map[$key] = $value
    }
    return $map
}

function Get-LocalProxyConfig {
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$PropertyMap = $null
    )

    if ($null -eq $PropertyMap) {
        $PropertyMap = Get-BootstrapPropertyMap
    }

    $enabled = $false
    if ($PropertyMap.ContainsKey('localProxyEnabled')) {
        $enabled = $PropertyMap['localProxyEnabled'].Equals('true', [System.StringComparison]::OrdinalIgnoreCase)
    }

    $hostName = '127.0.0.1'
    if ($PropertyMap.ContainsKey('localProxyHost') -and -not [string]::IsNullOrWhiteSpace($PropertyMap['localProxyHost'])) {
        $hostName = $PropertyMap['localProxyHost'].Trim()
    }

    $port = '7890'
    if ($PropertyMap.ContainsKey('localProxyPort') -and -not [string]::IsNullOrWhiteSpace($PropertyMap['localProxyPort'])) {
        $port = $PropertyMap['localProxyPort'].Trim()
    }

    return [pscustomobject]@{
        Enabled = $enabled
        Host = $hostName
        Port = $port
        ProxyUrl = "http://${hostName}:${port}"
    }
}

function Get-GithubMirrorPrefix {
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$PropertyMap = $null
    )

    if ($null -eq $PropertyMap) {
        $PropertyMap = Get-BootstrapPropertyMap
    }

    if ($PropertyMap.ContainsKey('githubMirrorPrefix')) {
        return $PropertyMap['githubMirrorPrefix'].Trim()
    }
    return ''
}

function Get-CandidateUrls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [bool]$LocalProxyEnabled,

        [Parameter(Mandatory = $false)]
        [string]$MirrorPrefix = ''
    )

    $urls = [System.Collections.Generic.List[string]]::new()
    if ($LocalProxyEnabled) {
        $urls.Add($BaseUrl)
        return $urls
    }

    if (-not [string]::IsNullOrWhiteSpace($MirrorPrefix)) {
        $prefix = if ($MirrorPrefix.EndsWith('/')) { $MirrorPrefix } else { "$MirrorPrefix/" }
        $urls.Add("$prefix$BaseUrl")
    }
    $urls.Add($BaseUrl)
    return @($urls | Select-Object -Unique)
}

function Get-FileMd5Hex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $md5.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
    } finally {
        $md5.Dispose()
    }

    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Remove-FileIfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Test-DownloadedFileValid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$ExpectedMd5 = '',

        [Parameter(Mandatory = $false)]
        [long]$MinSizeBytes = 1024
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $sizeBytes = (Get-Item -LiteralPath $Path).Length
    if ($sizeBytes -lt $MinSizeBytes) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedMd5)) {
        $actualMd5 = Get-FileMd5Hex -Path $Path
        if ($actualMd5 -ne $ExpectedMd5.ToLowerInvariant()) {
            return $false
        }
    }

    return $true
}

function Invoke-RetryDownload {
    <#
    .SYNOPSIS
      Download a file with limited retries, cleanup on failure, optional MD5 verification.
      Honors tool/bootstrap/bootstrap.properties localProxy / githubMirrorPrefix when
      ProxyUrl / LocalProxyEnabled / MirrorPrefix are not explicitly overridden.
    .OUTPUTS
      Hashtable: Success, LastError, Url, DestinationPath
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [int]$MaxAttempts,

        [Parameter(Mandatory = $false)]
        [string]$ExpectedMd5 = '',

        [Parameter(Mandatory = $false)]
        [long]$MinSizeBytes = 1024,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 600,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [object]$LocalProxy = $null,

        [Parameter(Mandatory = $false)]
        [string]$MirrorPrefix = ''
    )

    if ($null -eq $LocalProxy) {
        $props = Get-BootstrapPropertyMap
        $LocalProxy = Get-LocalProxyConfig -PropertyMap $props
        if ([string]::IsNullOrWhiteSpace($MirrorPrefix)) {
            $MirrorPrefix = Get-GithubMirrorPrefix -PropertyMap $props
        }
    } elseif ([string]::IsNullOrWhiteSpace($MirrorPrefix)) {
        $MirrorPrefix = Get-GithubMirrorPrefix
    }

    $destinationDir = Split-Path -Parent $DestinationPath
    if (-not [string]::IsNullOrWhiteSpace($destinationDir)) {
        New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
    }

    if ((Test-Path -LiteralPath $DestinationPath) -and -not $Force) {
        if (Test-DownloadedFileValid -Path $DestinationPath -ExpectedMd5 $ExpectedMd5 -MinSizeBytes $MinSizeBytes) {
            $existingSize = (Get-Item -LiteralPath $DestinationPath).Length
            Write-Host "$DisplayName`: already present ($([math]::Round($existingSize / 1MB, 1)) MB, verification OK)."
            return @{
                Success = $true
                Id = $Id
                DisplayName = $DisplayName
                Url = $Url
                DestinationPath = $DestinationPath
                LastError = $null
            }
        }

        Write-Warning "$DisplayName`: existing file failed verification. Deleting and re-downloading."
        Remove-FileIfExists -Path $DestinationPath
    }

    if ($Force) {
        Remove-FileIfExists -Path $DestinationPath
    }

    $candidateUrls = Get-CandidateUrls `
        -BaseUrl $Url `
        -LocalProxyEnabled ([bool]$LocalProxy.Enabled) `
        -MirrorPrefix $MirrorPrefix

    $lastError = $null
    $lastAttemptedUrl = $Url

    foreach ($candidateUrl in $candidateUrls) {
        $lastAttemptedUrl = $candidateUrl
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            try {
                Write-Host "$DisplayName`: downloading (attempt $attempt/$MaxAttempts) ..."
                Write-Host "  URL: $candidateUrl"
                if ($LocalProxy.Enabled) {
                    Write-Host "  Proxy: $($LocalProxy.ProxyUrl)"
                }

                Remove-FileIfExists -Path $DestinationPath

                $iwrParams = @{
                    Uri = $candidateUrl
                    OutFile = $DestinationPath
                    UseBasicParsing = $true
                    TimeoutSec = $TimeoutSec
                }
                if ($LocalProxy.Enabled) {
                    $iwrParams['Proxy'] = $LocalProxy.ProxyUrl
                }

                Invoke-WebRequest @iwrParams

                if (-not (Test-Path -LiteralPath $DestinationPath)) {
                    throw "Download did not create $DestinationPath"
                }

                if (-not (Test-DownloadedFileValid -Path $DestinationPath -ExpectedMd5 $ExpectedMd5 -MinSizeBytes $MinSizeBytes)) {
                    $sizeBytes = (Get-Item -LiteralPath $DestinationPath).Length
                    if (-not [string]::IsNullOrWhiteSpace($ExpectedMd5)) {
                        $actualMd5 = Get-FileMd5Hex -Path $DestinationPath
                        throw "Verification failed (expected MD5 $($ExpectedMd5.ToLowerInvariant()), got $actualMd5, size $sizeBytes bytes)."
                    }

                    throw "Downloaded file is too small ($sizeBytes bytes); likely incomplete or blocked."
                }

                $finalSize = (Get-Item -LiteralPath $DestinationPath).Length
                Write-Host "$DisplayName`: download verified ($([math]::Round($finalSize / 1MB, 1)) MB)."
                return @{
                    Success = $true
                    Id = $Id
                    DisplayName = $DisplayName
                    Url = $candidateUrl
                    DestinationPath = $DestinationPath
                    LastError = $null
                }
            } catch {
                $lastError = $_.Exception.Message
                Remove-FileIfExists -Path $DestinationPath

                if ($attempt -lt $MaxAttempts) {
                    $delaySeconds = [math]::Pow(2, $attempt)
                    Write-Warning "$DisplayName`: attempt $attempt failed: $lastError"
                    Write-Host "Retrying in ${delaySeconds}s ..."
                    Start-Sleep -Seconds $delaySeconds
                }
            }
        }
    }

    return @{
        Success = $false
        Id = $Id
        DisplayName = $DisplayName
        Url = $lastAttemptedUrl
        DestinationPath = $DestinationPath
        LastError = $lastError
    }
}

function New-BootstrapFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage,

        [Parameter(Mandatory = $false)]
        [string]$Url = '',

        [Parameter(Mandatory = $false)]
        [string]$ManualHint = ''
    )

    return @{
        Id = $Id
        DisplayName = $DisplayName
        Url = $Url
        LastError = $ErrorMessage
        ManualHint = $ManualHint
    }
}

function Write-BootstrapFailureReport {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Failures,

        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    Write-Host ''
    Write-Host '========================================'
    Write-Host 'Bootstrap FAILED — 以下依赖未能准备就绪:'
    Write-Host '========================================'

    foreach ($failure in $Failures) {
        Write-Host ''
        Write-Host "[$($failure.Id)] $($failure.DisplayName)"
        if (-not [string]::IsNullOrWhiteSpace($failure.Url)) {
            Write-Host "  URL: $($failure.Url)"
        }
        Write-Host "  Error: $($failure.LastError)"
        if (-not [string]::IsNullOrWhiteSpace($failure.ManualHint)) {
            Write-Host "  Hint: $($failure.ManualHint)"
        }
    }

    Write-Host ''
    Write-Host '========================================'
    Write-Host "Re-run: .\tool\bootstrap_windows.ps1 [-Force]"
    Write-Host "  Or fix individually: -Only media_kit | -Only ffmpeg"
    Write-Host '  Network: set localProxyEnabled=true or adjust githubMirrorPrefix'
    Write-Host '           in tool\bootstrap\bootstrap.properties'
    Write-Host '========================================'
}
