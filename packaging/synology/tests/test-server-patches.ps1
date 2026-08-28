# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testsRoot = $PSScriptRoot
$synologyRoot = (Resolve-Path -LiteralPath (Join-Path $testsRoot '..')).Path
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $synologyRoot '..\..')).Path
$patchRoot = Join-Path $synologyRoot 'spksrc-overlay\cross\maerxmppserver\patches'
$serverMakefilePath = Join-Path $synologyRoot 'spksrc-overlay\cross\maerxmppserver\Makefile'

$patches = @(
    (Join-Path $patchRoot '002-rebar-deterministic-beam.patch'),
    (Join-Path $patchRoot '003-maer-user-portal.patch'),
    (Join-Path $patchRoot '004-maer-webadmin.patch'),
    (Join-Path $patchRoot '005-maer-native-websocket-origin.patch')
)
$targetPaths = @(
    'rebar.config',
    'src/maer_portal_smtp.erl',
    'src/mod_maer_portal.erl',
    'priv/maer_portal/portal.css',
    'priv/maer_portal/portal.js',
    'priv/css/admin.css',
    'src/ejabberd_web_admin.erl',
    'src/ejabberd_options.erl'
)
$portalPaths = @(
    'src/maer_portal_smtp.erl',
    'src/mod_maer_portal.erl',
    'priv/maer_portal/portal.css',
    'priv/maer_portal/portal.js'
)

function Resolve-RequiredTool {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string[]] $Fallbacks = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in $Fallbacks) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw "Required patch-contract tool is unavailable: $Name"
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

function Copy-TargetSnapshot {
    param(
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $DestinationRoot
    )

    foreach ($relativePath in $targetPaths) {
        $sourcePath = Join-RepositoryPath -Root $SourceRoot -RelativePath $relativePath
        $destinationPath = Join-RepositoryPath -Root $DestinationRoot -RelativePath $relativePath
        $destinationDirectory = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
    }
}

function Invoke-SpksrcPatch {
    param(
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $PatchPath,
        [switch] $Reverse
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-p0')
    $arguments.Add('--batch')
    $arguments.Add('--forward')
    $arguments.Add('--reject-file=-')
    if ($Reverse) { $arguments.Add('--reverse') }
    $arguments.Add("--input=$PatchPath")

    Push-Location $SourceRoot
    try {
        $output = @(& $script:PatchExecutable @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($exitCode -ne 0) {
        $direction = if ($Reverse) { 'reverse' } else { 'forward' }
        throw "spksrc patch -p0 $direction application failed for '$PatchPath':`n$($output -join "`n")"
    }
}

function Assert-NoGitPrefixDirectories {
    param([Parameter(Mandatory)] [string] $SourceRoot)

    foreach ($prefix in @('a', 'b')) {
        $unexpected = Join-Path $SourceRoot $prefix
        if (Test-Path -LiteralPath $unexpected -PathType Container) {
            throw "patch -p0 created an unexpected Git-prefix directory: $unexpected"
        }
    }
}

function Assert-TargetsMatch {
    param(
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $ExpectedRoot
    )

    foreach ($relativePath in $targetPaths) {
        $expectedPath = Join-RepositoryPath -Root $ExpectedRoot -RelativePath $relativePath
        $actualPath = Join-RepositoryPath -Root $SourceRoot -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $actualPath -PathType Leaf)) {
            throw "Patched source is missing expected target: $relativePath"
        }
        $expectedText = [System.IO.File]::ReadAllText($expectedPath).Replace("`r`n", "`n").Replace("`r", "`n")
        $actualText = [System.IO.File]::ReadAllText($actualPath).Replace("`r`n", "`n").Replace("`r", "`n")
        if ($expectedText -cne $actualText) {
            throw "Patched target differs from the reviewed expected file: $relativePath"
        }
    }
}

$script:PatchExecutable = Resolve-RequiredTool -Name 'patch' -Fallbacks @(
    'C:\Program Files\Git\usr\bin\patch.exe'
)
$gitExecutable = Resolve-RequiredTool -Name 'git'
$tarExecutable = Resolve-RequiredTool -Name 'tar'

$serverMakefile = [System.IO.File]::ReadAllText($serverMakefilePath)
$commitMatch = [regex]::Match($serverMakefile, '(?m)^PKG_COMMIT\s*=\s*([0-9a-f]{40})\s*$')
if (-not $commitMatch.Success) { throw 'Unable to read the locked MAER source commit.' }
$lockedCommit = $commitMatch.Groups[1].Value

foreach ($patchPath in $patches) {
    if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
        throw "Required server patch is missing: $patchPath"
    }
    $patchText = [System.IO.File]::ReadAllText($patchPath)
    if ($patchText -match '(?m)^(?:---|\+\+\+) [ab]/') {
        throw "Server patch contains a Git a/ or b/ prefix incompatible with spksrc patch -p0: $patchPath"
    }
}

$temporaryBase = [System.IO.Path]::GetTempPath()
$temporaryRoot = Join-Path $temporaryBase ('maer-server-patches-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    # This round trip also works in the synthetic single-commit repositories
    # created by test-clean-checkouts.ps1. It proves the exact -p0 path
    # semantics without requiring network access or hidden source fixtures.
    $roundTripRoot = Join-Path $temporaryRoot 'roundtrip'
    $expectedRoot = Join-Path $temporaryRoot 'expected'
    New-Item -ItemType Directory -Path $roundTripRoot | Out-Null
    New-Item -ItemType Directory -Path $expectedRoot | Out-Null
    Copy-TargetSnapshot -SourceRoot $repositoryRoot -DestinationRoot $roundTripRoot
    # rebar.config deliberately remains unmodified in the public source tree;
    # only the package build enables deterministic BEAM output. Construct the
    # reviewed post-patch shape before exercising the reverse/forward round trip.
    Invoke-SpksrcPatch -SourceRoot $roundTripRoot -PatchPath $patches[0]
    Copy-TargetSnapshot -SourceRoot $roundTripRoot -DestinationRoot $expectedRoot
    for ($index = $patches.Count - 1; $index -ge 0; $index--) {
        Invoke-SpksrcPatch -SourceRoot $roundTripRoot -PatchPath $patches[$index] -Reverse
    }
    foreach ($relativePath in $portalPaths) {
        $reversedPath = Join-RepositoryPath -Root $roundTripRoot -RelativePath $relativePath
        if (Test-Path -LiteralPath $reversedPath) {
            throw "Reverse patch did not restore the locked source shape: $relativePath"
        }
    }
    foreach ($patchPath in $patches) {
        Invoke-SpksrcPatch -SourceRoot $roundTripRoot -PatchPath $patchPath
    }
    Assert-NoGitPrefixDirectories -SourceRoot $roundTripRoot
    Assert-TargetsMatch -SourceRoot $roundTripRoot -ExpectedRoot $expectedRoot

    # In a real checkout, additionally apply the same ordered patch -p0 calls
    # to the immutable source commit used by spksrc. Synthetic clean-checkout
    # tests intentionally contain only one snapshot commit and use the round
    # trip above instead.
    & $gitExecutable -C $repositoryRoot cat-file -e "$lockedCommit`^{commit}" 2>$null
    $lockedCommitIsAvailable = $LASTEXITCODE -eq 0
    if ($lockedCommitIsAvailable) {
        $archivePath = Join-Path $temporaryRoot 'locked-source.tar'
        $lockedSourceRoot = Join-Path $temporaryRoot 'locked-source'
        New-Item -ItemType Directory -Path $lockedSourceRoot | Out-Null
        & $gitExecutable -C $repositoryRoot archive --format=tar "--output=$archivePath" $lockedCommit
        if ($LASTEXITCODE -ne 0) { throw 'Unable to archive the locked MAER source commit.' }
        & $tarExecutable -xf $archivePath -C $lockedSourceRoot
        if ($LASTEXITCODE -ne 0) { throw 'Unable to extract the locked MAER source commit.' }
        foreach ($patchPath in $patches) {
            Invoke-SpksrcPatch -SourceRoot $lockedSourceRoot -PatchPath $patchPath
        }
        Assert-NoGitPrefixDirectories -SourceRoot $lockedSourceRoot
        Assert-TargetsMatch -SourceRoot $lockedSourceRoot -ExpectedRoot $expectedRoot
        Write-Host "Locked commit patch -p0 application passed: $lockedCommit" -ForegroundColor Green
    }
    else {
        Write-Host 'Locked commit object unavailable in synthetic checkout; deterministic -p0 round trip passed.' -ForegroundColor Yellow
    }

    Write-Host 'MAER server spksrc patch -p0 contract passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporaryRoot = (Resolve-Path -LiteralPath $temporaryRoot).Path
        $resolvedTemporaryBase = (Resolve-Path -LiteralPath $temporaryBase).Path
        if (-not $resolvedTemporaryRoot.StartsWith($resolvedTemporaryBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove an unexpected path: $resolvedTemporaryRoot"
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
