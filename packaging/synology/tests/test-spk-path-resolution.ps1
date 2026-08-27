# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'path-utils.ps1')

$temporaryFile = [System.IO.Path]::GetTempFileName()
try {
    $pathInfo = Resolve-Path -LiteralPath $temporaryFile
    $providerQualifiedPath = 'Microsoft.PowerShell.Core\FileSystem::' + $pathInfo.ProviderPath
    $qualifiedPathInfo = Resolve-Path -LiteralPath $providerQualifiedPath

    if ($qualifiedPathInfo.Provider.Name -cne 'FileSystem') {
        throw 'Regression fixture did not resolve through the filesystem provider.'
    }

    $nativePath = Resolve-MaerFileSystemPath -LiteralPath $providerQualifiedPath -PathType Leaf
    if ($nativePath -cne $pathInfo.ProviderPath) {
        throw "Filesystem path normalization mismatch (actual='$nativePath', expected='$($pathInfo.ProviderPath)')."
    }
    if ($nativePath.Contains('::', [System.StringComparison]::Ordinal)) {
        throw "Native path still contains a PowerShell provider prefix: $nativePath"
    }

    Write-Host 'SPK filesystem path normalization test passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temporaryFile -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryFile -Force
    }
}
