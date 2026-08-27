# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

[CmdletBinding()]
param(
    [switch] $KeepTemporary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testsRoot = $PSScriptRoot
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $testsRoot '..\..\..')).Path
$temporaryBase = [System.IO.Path]::GetTempPath()
$temporaryRoot = Join-Path $temporaryBase ('maer-clean-checkouts-' + [guid]::NewGuid().ToString('N'))
$seedRoot = Join-Path $temporaryRoot 'seed'

function Invoke-Git {
    param(
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    & git -C $WorkingDirectory @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git failed in '$WorkingDirectory': git $($Arguments -join ' ')"
    }
}

function Join-RepositoryPath {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $RelativePath
    )

    $result = $Root
    foreach ($segment in $RelativePath.Split('/')) {
        $result = Join-Path $result $segment
    }
    return $result
}

function Assert-LfCheckout {
    param([Parameter(Mandatory)] [string] $CheckoutRoot)

    $criticalPaths = @(
        '.gitattributes',
        'COPYING',
        'packaging/synology/LOCKS.json',
        'packaging/synology/tests/validate-source.ps1',
        'packaging/synology/dsm-publication-preflight.ps1',
        'packaging/synology/spksrc-overlay/spk/maerxmppserver/Makefile',
        'packaging/synology/spksrc-overlay/cross/maerxmppserver/patches/002-rebar-deterministic-beam.patch',
        'packaging/synology/spksrc-overlay/spk/maerxmppserver/src/COPYING',
        'packaging/synology/spksrc-overlay/spk/maerxmppserver/src/defaults/ejabberd.yml',
        'packaging/synology/spksrc-overlay/spk/maerxmppserver/src/upload-usage-check.sh',
        '.github/workflows/synology-package.yml'
    )

    $eolInventory = @(& git -C $CheckoutRoot ls-files --eol -- @criticalPaths)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect checkout EOLs: $CheckoutRoot"
    }
    foreach ($entry in $eolInventory) {
        if ($entry -notmatch '\bw/lf\b') {
            throw "Checkout contains a non-LF critical file: $entry"
        }
    }

    foreach ($relativePath in $criticalPaths) {
        $absolutePath = Join-RepositoryPath -Root $CheckoutRoot -RelativePath $relativePath
        $bytes = [System.IO.File]::ReadAllBytes($absolutePath)
        for ($index = 0; $index -lt ($bytes.Length - 1); $index++) {
            if ($bytes[$index] -eq 13 -and $bytes[$index + 1] -eq 10) {
                throw "Checkout contains CRLF bytes: $relativePath"
            }
        }
    }
}

New-Item -ItemType Directory -Path $seedRoot -Force | Out-Null
try {
    $paths = @(& git -C $repositoryRoot ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0 -or $paths.Count -eq 0) {
        throw 'Unable to enumerate the repository snapshot.'
    }

    foreach ($relativePath in $paths) {
        $sourcePath = Join-RepositoryPath -Root $repositoryRoot -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            continue
        }
        $destinationPath = Join-RepositoryPath -Root $seedRoot -RelativePath $relativePath
        $destinationDirectory = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
    }

    & git init --quiet --initial-branch snapshot $seedRoot
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize snapshot repository.' }
    Invoke-Git -WorkingDirectory $seedRoot -Arguments @('config', 'core.autocrlf', 'false')
    Invoke-Git -WorkingDirectory $seedRoot -Arguments @('config', 'core.safecrlf', 'false')
    Invoke-Git -WorkingDirectory $seedRoot -Arguments @('config', 'user.name', 'MAER reproducibility test')
    Invoke-Git -WorkingDirectory $seedRoot -Arguments @('config', 'user.email', 'reproducibility-test@invalid.example')
    Invoke-Git -WorkingDirectory $seedRoot -Arguments @('add', '--all')
    Invoke-Git -WorkingDirectory $seedRoot -Arguments @('commit', '--quiet', '-m', 'synthetic snapshot')

    foreach ($profile in @(
        [pscustomobject]@{ Name = 'windows-autocrlf'; AutoCrlf = 'true' },
        [pscustomobject]@{ Name = 'linux-lf'; AutoCrlf = 'false' }
    )) {
        $checkoutRoot = Join-Path $temporaryRoot $profile.Name
        & git -c "core.autocrlf=$($profile.AutoCrlf)" clone --quiet --no-local $seedRoot $checkoutRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to create clean clone profile '$($profile.Name)'."
        }
        Invoke-Git -WorkingDirectory $checkoutRoot -Arguments @('config', 'core.autocrlf', $profile.AutoCrlf)
        Assert-LfCheckout -CheckoutRoot $checkoutRoot
        & pwsh -NoProfile -File (Join-Path $checkoutRoot 'packaging\synology\tests\validate-source.ps1')
        if ($LASTEXITCODE -ne 0) {
            throw "Source validation failed in clean clone profile '$($profile.Name)'."
        }
        Write-Host "Clean clone profile passed: $($profile.Name)" -ForegroundColor Green
    }

    Write-Host 'Windows and Linux clean-checkout validation passed.' -ForegroundColor Green
}
finally {
    if (-not $KeepTemporary -and (Test-Path -LiteralPath $temporaryRoot)) {
        $resolvedTemporaryRoot = (Resolve-Path -LiteralPath $temporaryRoot).Path
        $resolvedTemporaryBase = (Resolve-Path -LiteralPath $temporaryBase).Path
        if (-not $resolvedTemporaryRoot.StartsWith($resolvedTemporaryBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove an unexpected path: $resolvedTemporaryRoot"
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
