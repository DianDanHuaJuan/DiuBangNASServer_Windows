#Requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap Windows build dependencies (media_kit native libs + FFmpeg LGPL).

.DESCRIPTION
  Unified entry for all gitignored / external Windows build dependencies.
  Downloads with limited retries, deletes corrupt partial files, and reports
  which dependency failed when retries are exhausted.

  Network: tool/bootstrap/bootstrap.properties
    localProxyEnabled / localProxyHost / localProxyPort — Clash HTTP/mixed proxy
    githubMirrorPrefix — used when local proxy is off (ignored when proxy is on)

  To add a dependency: register in tool/bootstrap/_Dependencies.ps1 and add
  tool/bootstrap/deps/<id>.ps1 exporting Ensure-<Id>Dependency.

.PARAMETER Only
  Process only selected dependencies: media_kit, ffmpeg.

.PARAMETER Force
  Force re-download even when cached files pass verification.

.EXAMPLE
  .\tool\bootstrap_windows.ps1

.EXAMPLE
  .\tool\bootstrap_windows.ps1 -Only media_kit -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RepoRoot = '',

    [Parameter(Mandatory = $false)]
    [int]$MaxAttempts = 3,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [ValidateSet('media_kit', 'ffmpeg')]
    [string[]]$Only = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bootstrapDir = $PSScriptRoot
if (-not $bootstrapDir) {
    $bootstrapDir = Join-Path (Get-Location).Path 'tool\bootstrap'
}

. (Join-Path $bootstrapDir 'bootstrap\_Download.ps1')
. (Join-Path $bootstrapDir 'bootstrap\_Dependencies.ps1')

$resolvedRepoRoot = Resolve-RepoRoot -RepoRoot $RepoRoot -ScriptRoot $bootstrapDir
$depsRoot = Join-Path $bootstrapDir 'bootstrap\deps'
$dependencies = Get-BootstrapDependencies -Only $Only

$propsPath = Get-BootstrapPropertiesPath -BootstrapDir (Join-Path $bootstrapDir 'bootstrap')
$props = Get-BootstrapPropertyMap -PropertiesPath $propsPath
$localProxy = Get-LocalProxyConfig -PropertyMap $props
$mirrorPrefix = Get-GithubMirrorPrefix -PropertyMap $props

$context = @{
    RepoRoot = $resolvedRepoRoot
    MaxAttempts = $MaxAttempts
    Force = [bool]$Force
    LocalProxy = $localProxy
    MirrorPrefix = $mirrorPrefix
}

Write-Host "Windows bootstrap starting (repo: $resolvedRepoRoot)"
Write-Host "Dependencies: $($dependencies.Id -join ', ')"
if ($localProxy.Enabled) {
    Write-Host "[localProxy] enabled $($localProxy.Host):$($localProxy.Port)"
} elseif (-not [string]::IsNullOrWhiteSpace($mirrorPrefix)) {
    Write-Host "[githubMirror] $mirrorPrefix"
} else {
    Write-Host '[network] direct github.com (no local proxy / mirror prefix)'
}

$allFailures = [System.Collections.Generic.List[object]]::new()

foreach ($dep in $dependencies) {
    Write-Host ''
    Write-Host "=== $($dep.DisplayName) [$($dep.Id)] ==="

    $depScript = Join-Path $depsRoot $dep.Script
    if (-not (Test-Path -LiteralPath $depScript)) {
        $allFailures.Add((New-BootstrapFailure `
            -Id $dep.Id `
            -DisplayName $dep.DisplayName `
            -ErrorMessage "Dependency script not found: $depScript" `
            -ManualHint 'Check tool/bootstrap/deps/ and _Dependencies.ps1 registration.'))
        continue
    }

    . $depScript

    $ensureFunction = $dep.EnsureFunction
    if (-not (Get-Command -Name $ensureFunction -ErrorAction SilentlyContinue)) {
        $allFailures.Add((New-BootstrapFailure `
            -Id $dep.Id `
            -DisplayName $dep.DisplayName `
            -ErrorMessage "Ensure function not found: $ensureFunction" `
            -ManualHint "Export $ensureFunction from $($dep.Script)."))
        continue
    }

    try {
        $result = & $ensureFunction -Context $context
        if (-not $result.Success) {
            foreach ($failure in $result.Failures) {
                $allFailures.Add($failure)
            }
        }
    } catch {
        $allFailures.Add((New-BootstrapFailure `
            -Id $dep.Id `
            -DisplayName $dep.DisplayName `
            -ErrorMessage $_.Exception.Message `
            -ManualHint "Re-run: .\tool\bootstrap_windows.ps1 -Only $($dep.Id) [-Force]"))
    }
}

Write-Host ''
if ($allFailures.Count -gt 0) {
    Write-BootstrapFailureReport -Failures $allFailures.ToArray() -RepoRoot $resolvedRepoRoot
    exit 1
}

Write-Host 'Windows bootstrap completed successfully.'
exit 0
