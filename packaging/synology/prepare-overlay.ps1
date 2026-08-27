# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $SpksrcPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedSpksrcCommit = '954871e356f7f990c179eb58af11c20d82872d8f'
$synologyRoot = $PSScriptRoot
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $synologyRoot)
$overlayRoot = Join-Path $synologyRoot 'spksrc-overlay'
$locksPath = Join-Path $synologyRoot 'LOCKS.json'

$resolvedSpksrc = (Resolve-Path -LiteralPath $SpksrcPath).Path
$head = (& git -C $resolvedSpksrc rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "The supplied path is not a Git checkout: $resolvedSpksrc"
}
if ($head -ne $expectedSpksrcCommit) {
    throw "spksrc HEAD is $head; expected $expectedSpksrcCommit"
}

$workingTreeStatus = @(& git -C $resolvedSpksrc status --porcelain)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect the spksrc working tree.'
}
if ($workingTreeStatus.Count -ne 0) {
    throw 'The spksrc checkout must be clean before applying the MAER overlay.'
}

$locks = Get-Content -LiteralPath $locksPath -Raw | ConvertFrom-Json
$canonicalIcon = Join-Path $repositoryRoot 'maer\assets\maer-mark.png'
$canonicalCopying = Join-Path $repositoryRoot 'COPYING'
$packagedIcon = Join-Path $overlayRoot 'spk\maerxmppserver\src\maerxmppserver.png'
$packagedCopying = Join-Path $overlayRoot 'spk\maerxmppserver\src\COPYING'

if (-not (Test-Path -LiteralPath $canonicalIcon -PathType Leaf)) {
    throw "MAER icon not found: $canonicalIcon"
}
if (-not (Test-Path -LiteralPath $canonicalCopying -PathType Leaf)) {
    throw "Server license not found: $canonicalCopying"
}
if (-not (Test-Path -LiteralPath $packagedIcon -PathType Leaf)) {
    throw "Packaged MAER icon not found: $packagedIcon"
}
if (-not (Test-Path -LiteralPath $packagedCopying -PathType Leaf)) {
    throw "Packaged server license not found: $packagedCopying"
}

$canonicalIconHash = (Get-FileHash -LiteralPath $canonicalIcon -Algorithm SHA256).Hash.ToLowerInvariant()
$packagedIconHash = (Get-FileHash -LiteralPath $packagedIcon -Algorithm SHA256).Hash.ToLowerInvariant()
if ($canonicalIconHash -ne $locks.assets.maer_mark_sha256 -or $packagedIconHash -ne $canonicalIconHash) {
    throw 'MAER icon hash mismatch.'
}
$canonicalCopyingHash = (Get-FileHash -LiteralPath $canonicalCopying -Algorithm SHA256).Hash.ToLowerInvariant()
$packagedCopyingHash = (Get-FileHash -LiteralPath $packagedCopying -Algorithm SHA256).Hash.ToLowerInvariant()
if ($canonicalCopyingHash -ne $locks.assets.copying_sha256 -or $packagedCopyingHash -ne $canonicalCopyingHash) {
    throw 'Server COPYING hash mismatch.'
}

$overlayDirectories = @(
    'native\erlang-maer',
    'cross\erlang-maer',
    'cross\openssl3-maer',
    'cross\maerxmppserver',
    'spk\maerxmppserver'
)

foreach ($relativePath in $overlayDirectories) {
    $sourcePath = Join-Path $overlayRoot $relativePath
    $destinationPath = Join-Path $resolvedSpksrc $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Overlay source missing: $sourcePath"
    }
    if (Test-Path -LiteralPath $destinationPath) {
        throw "Refusing to overwrite an existing spksrc path: $destinationPath"
    }
}

foreach ($relativePath in $overlayDirectories) {
    $sourcePath = Join-Path $overlayRoot $relativePath
    $destinationPath = Join-Path $resolvedSpksrc $relativePath
    $destinationParent = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse
}

$packageSource = Join-Path $resolvedSpksrc 'spk\maerxmppserver\src'
$copiedIconHash = (Get-FileHash -LiteralPath (Join-Path $packageSource 'maerxmppserver.png') -Algorithm SHA256).Hash.ToLowerInvariant()
if ($copiedIconHash -ne $locks.assets.maer_mark_sha256) {
    throw 'The copied MAER icon failed its post-copy hash check.'
}
$copiedLicenseHash = (Get-FileHash -LiteralPath (Join-Path $packageSource 'COPYING') -Algorithm SHA256).Hash.ToLowerInvariant()
if ($copiedLicenseHash -ne $locks.assets.copying_sha256) {
    throw 'The copied server license failed its post-copy hash check.'
}

Write-Host "MAER Synology overlay prepared in $resolvedSpksrc"
Write-Host 'No package was built or installed.'
