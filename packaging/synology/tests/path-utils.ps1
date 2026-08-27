# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

function Resolve-MaerFileSystemPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $LiteralPath,

        [ValidateSet('Any', 'Leaf', 'Container')]
        [string] $PathType = 'Any'
    )

    $resolvedItems = @(Resolve-Path -LiteralPath $LiteralPath -ErrorAction Stop)
    if ($resolvedItems.Count -ne 1) {
        throw "Expected one filesystem path but resolved $($resolvedItems.Count): $LiteralPath"
    }

    $resolvedItem = $resolvedItems[0]
    if ($resolvedItem.Provider.Name -cne 'FileSystem') {
        throw "Path is not provided by the filesystem provider: $LiteralPath"
    }

    # PathInfo.Path can retain a prefix such as
    # Microsoft.PowerShell.Core\FileSystem:: for UNC paths. Native tools such
    # as tar.exe do not understand that PowerShell provider-qualified form.
    $providerPath = $resolvedItem.ProviderPath
    if ([string]::IsNullOrWhiteSpace($providerPath)) {
        throw "Filesystem provider returned an empty native path: $LiteralPath"
    }

    if ($PathType -ne 'Any' -and -not (Test-Path -LiteralPath $providerPath -PathType $PathType)) {
        throw "Resolved filesystem path is not a $($PathType.ToLowerInvariant()): $providerPath"
    }

    return $providerPath
}
