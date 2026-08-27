[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SpkPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'path-utils.ps1')

$resolvedSpk = Resolve-MaerFileSystemPath -LiteralPath $SpkPath -PathType Leaf
$validator = Resolve-MaerFileSystemPath -LiteralPath (Join-Path $PSScriptRoot 'validate-source.ps1') -PathType Leaf

& pwsh -NoProfile -File $validator -SpkPath $resolvedSpk
if ($LASTEXITCODE -ne 0) {
    throw "MAER XMPP Server release gate rejected: $resolvedSpk"
}

$hash = Get-FileHash -LiteralPath $resolvedSpk -Algorithm SHA256
Write-Host "MAER XMPP Server release gate passed."
Write-Host "SPK: $resolvedSpk"
Write-Host "SHA256: $($hash.Hash)"
