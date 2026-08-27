[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SpkPath
)

$ErrorActionPreference = 'Stop'
$resolvedSpk = (Resolve-Path -LiteralPath $SpkPath).Path
$validator = Join-Path $PSScriptRoot 'validate-source.ps1'

& pwsh -NoProfile -File $validator -SpkPath $resolvedSpk
if ($LASTEXITCODE -ne 0) {
    throw "MAER XMPP Server release gate rejected: $resolvedSpk"
}

$hash = Get-FileHash -LiteralPath $resolvedSpk -Algorithm SHA256
Write-Host "MAER XMPP Server release gate passed."
Write-Host "SPK: $resolvedSpk"
Write-Host "SHA256: $($hash.Hash)"
