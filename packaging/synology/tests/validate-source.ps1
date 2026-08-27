# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

[CmdletBinding()]
param(
    [string] $SpkPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = [System.Collections.Generic.List[string]]::new()
$testsRoot = $PSScriptRoot
. (Join-Path $testsRoot 'path-utils.ps1')

$synologyRoot = Resolve-MaerFileSystemPath -LiteralPath (Join-Path $testsRoot '..') -PathType Container
$repositoryRoot = Resolve-MaerFileSystemPath -LiteralPath (Join-Path $synologyRoot '..\..') -PathType Container
$overlayRoot = Join-Path $synologyRoot 'spksrc-overlay'

function Add-Failure {
    param([string] $Message)
    $script:Failures.Add($Message)
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        Add-Failure $Message
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string] $Message)
    if ([string]$Actual -cne [string]$Expected) {
        Add-Failure "$Message (actual='$Actual', expected='$Expected')"
    }
}

function Read-TextNormalized {
    param([string] $Path)

    $text = [System.IO.File]::ReadAllText($Path)
    return $text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-MakeValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '\s*=\s*(.+?)\s*$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) {
        Add-Failure "Make variable '$Name' is missing."
        return $null
    }
    return $match.Groups[1].Value.Trim()
}

function Assert-LfShellFile {
    param([string] $Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    for ($index = 0; $index -lt ($bytes.Length - 1); $index++) {
        if ($bytes[$index] -eq 13 -and $bytes[$index + 1] -eq 10) {
            Add-Failure "Shell file uses CRLF instead of LF: $Path"
            return
        }
    }
}

function Read-InfoFile {
    param([string] $Path)
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^([^=]+)="(.*)"$') {
            $values[$matches[1]] = $matches[2]
        }
    }
    return $values
}

function Find-BinaryMarker {
    param(
        [string] $Root,
        [string[]] $Markers
    )

    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $content = [System.Text.Encoding]::Latin1.GetString($bytes)
            foreach ($marker in $Markers) {
                if ($content.Contains($marker, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return [pscustomobject]@{ Path = $file.FullName; Marker = $marker }
                }
            }
        }
        catch {
            Add-Failure "Unable to inspect payload file '$($file.FullName)': $($_.Exception.Message)"
            return $null
        }
    }
    return $null
}

function Validate-BuiltSpk {
    param([string] $PackagePath, $Expected)

    $resolvedPackage = Resolve-MaerFileSystemPath -LiteralPath $PackagePath -PathType Leaf
    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("maer-spk-validation-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    try {
        & tar -xf $resolvedPackage -C $temporaryRoot
        if ($LASTEXITCODE -ne 0) {
            Add-Failure "Unable to extract SPK: $resolvedPackage"
            return
        }

        $infoPath = Join-Path $temporaryRoot 'INFO'
        $privilegePath = Join-Path $temporaryRoot 'conf\privilege'
        $installWizardPath = Join-Path $temporaryRoot 'WIZARD_UIFILES\install_uifile'
        $upgradeWizardPath = Join-Path $temporaryRoot 'WIZARD_UIFILES\upgrade_uifile'
        Assert-True (Test-Path -LiteralPath $infoPath -PathType Leaf) 'Built SPK has no INFO file.'
        Assert-True (Test-Path -LiteralPath $privilegePath -PathType Leaf) 'Built SPK has no conf/privilege file.'
        Assert-True (Test-Path -LiteralPath $installWizardPath -PathType Leaf) 'Built SPK has no SMTP install wizard.'
        Assert-True (Test-Path -LiteralPath $upgradeWizardPath -PathType Leaf) 'Built SPK has no SMTP upgrade wizard.'

        if (Test-Path -LiteralPath $infoPath -PathType Leaf) {
            $info = Read-InfoFile $infoPath
            foreach ($key in @('package', 'version', 'displayname', 'distributor', 'distributor_url', 'arch', 'os_min_ver')) {
                Assert-True $info.ContainsKey($key) "Built INFO is missing '$key'."
                if ($info.ContainsKey($key)) {
                    Assert-Equal $info[$key] $Expected.$key "Built INFO '$key' mismatch."
                }
            }
            Assert-True (-not $info.ContainsKey('install_replace_packages')) 'Built INFO must not replace another package.'
            Assert-True (-not $info.ContainsKey('install_conflict_packages')) 'Built INFO must not conflict with the legacy ejabberd package.'
            Assert-True (-not ($info.ContainsKey('ctl_stop') -and $info['ctl_stop'] -eq 'no')) 'Built SPK must be startable.'
        }

        if (Test-Path -LiteralPath $privilegePath -PathType Leaf) {
            try {
                $privilege = Get-Content -LiteralPath $privilegePath -Raw | ConvertFrom-Json
                Assert-Equal $privilege.defaults.'run-as' $Expected.run_as 'DSM privilege run-as mismatch.'
                Assert-Equal $privilege.username $Expected.username 'DSM privilege username mismatch.'
                Assert-Equal $privilege.groupname $Expected.groupname 'DSM privilege group mismatch.'
                Assert-True ($privilege.defaults.'run-as' -ne 'root') 'DSM service must not run as root.'
            }
            catch {
                Add-Failure "Built conf/privilege is not valid JSON: $($_.Exception.Message)"
            }
        }

        $listing = @(& tar -tvf $resolvedPackage)
        if ($LASTEXITCODE -ne 0) {
            Add-Failure 'Unable to list SPK permissions.'
        }
        else {
            $startStopLine = $listing | Where-Object { $_ -match '(?:^|\s)(?:\./)?scripts/start-stop-status$' } | Select-Object -First 1
            $setupLine = $listing | Where-Object { $_ -match '(?:^|\s)(?:\./)?scripts/service-setup$' } | Select-Object -First 1
            $privilegeLine = $listing | Where-Object { $_ -match '(?:^|\s)(?:\./)?conf/privilege$' } | Select-Object -First 1
            $installWizardLine = $listing | Where-Object { $_ -match '(?:^|\s)(?:\./)?WIZARD_UIFILES/install_uifile$' } | Select-Object -First 1
            $upgradeWizardLine = $listing | Where-Object { $_ -match '(?:^|\s)(?:\./)?WIZARD_UIFILES/upgrade_uifile$' } | Select-Object -First 1
            Assert-True ([bool]$startStopLine) 'SPK listing has no start-stop-status script.'
            Assert-True ([bool]$setupLine) 'SPK listing has no service-setup script.'
            Assert-True ([bool]$privilegeLine) 'SPK listing has no privilege file.'
            Assert-True ([bool]$installWizardLine) 'SPK listing has no install wizard.'
            Assert-True ([bool]$upgradeWizardLine) 'SPK listing has no upgrade wizard.'
            if ($startStopLine) { Assert-True ($startStopLine -match '^-rwxr-xr-x\s') 'start-stop-status mode must be 0755.' }
            if ($setupLine) { Assert-True ($setupLine -match '^-rwxr-xr-x\s') 'service-setup mode must be 0755.' }
            if ($privilegeLine) { Assert-True ($privilegeLine -match '^-rw-r--r--\s') 'conf/privilege mode must be 0644.' }
            if ($installWizardLine) { Assert-True ($installWizardLine -match '^-rw-r--r--\s') 'Install wizard mode must be 0644.' }
            if ($upgradeWizardLine) { Assert-True ($upgradeWizardLine -match '^-rw-r--r--\s') 'Upgrade wizard mode must be 0644.' }
        }
        $numericOuterListing = @(& tar --numeric-owner -tvf $resolvedPackage)
        if ($LASTEXITCODE -ne 0) {
            Add-Failure 'Unable to inspect numeric ownership of the SPK.'
        }
        else {
            $outerOwnershipMismatch = $numericOuterListing | Where-Object { $_ -notmatch '^\S+\s+\d+\s+0\s+0\s+' } | Select-Object -First 1
            Assert-True (-not $outerOwnershipMismatch) $(if ($outerOwnershipMismatch) { "SPK entry is not owned by numeric 0:0: $outerOwnershipMismatch" } else { 'SPK ownership is not numeric root.' })
        }

        $packageArchive = Join-Path $temporaryRoot 'package.tgz'
        if (Test-Path -LiteralPath $packageArchive -PathType Leaf) {
            $payloadListing = @(& tar -tzf $packageArchive)
            if ($LASTEXITCODE -ne 0) {
                Add-Failure 'Unable to list package.tgz payload.'
                return
            }
            $normalizedPayloadListing = @($payloadListing | ForEach-Object { $_ -replace '^\./', '' })
            foreach ($payloadFile in @(
                'bin/ejabberdctl',
                'bin/erl',
                'bin/maer-upload-usage-check',
                'lib/libcrypto.so.3',
                'lib/libssl.so.3',
                'lib/libsqlite3.so.0.8.6',
                'lib/libncursesw.so.6.6',
                'lib/libatomic.so.1.2.0',
                'lib/ejabberd-26.07/ebin/mod_maer_pairing.beam',
                'lib/ejabberd-26.07/ebin/mod_maer_portal.beam',
                'lib/ejabberd-26.07/ebin/maer_portal_smtp.beam',
                'lib/ejabberd-26.07/ebin/mod_maer_redirect.beam',
                'lib/ejabberd-26.07/priv/maer_portal/portal.css',
                'lib/ejabberd-26.07/priv/maer_portal/portal.js',
                'lib/ejabberd-26.07/priv/img/admin-logo.png',
                'lib/ejabberd-26.07/priv/img/favicon.png',
                'share/maerxmppserver/defaults/ejabberd.yml',
                'share/maerxmppserver/defaults/ejabberdctl.cfg',
                'share/maerxmppserver/defaults/inetrc',
                'share/maerxmppserver/licenses/Erlang-OTP-27.3.4.16.txt',
                'share/maerxmppserver/licenses/OpenSSL-3.5.7.txt',
                'share/maerxmppserver/licenses/ncurses-6.6.txt',
                'share/maerxmppserver/licenses/zlib-1.3.2.txt',
                'share/maerxmppserver/licenses/Expat-2.8.3.txt',
                'share/maerxmppserver/licenses/libyaml-0.2.5.txt',
                'share/maerxmppserver/licenses/GPL-3.0.txt',
                'share/maerxmppserver/licenses/GCC-Runtime-Library-Exception.txt',
                'share/maerxmppserver/licenses/libatomic-GCC-8.5.0-SOURCE.txt',
                'share/maerxmppserver/licenses/idna-7.1.0-NOTICE.txt'
            )) {
                Assert-True ($normalizedPayloadListing -contains $payloadFile) "SPK payload is missing $payloadFile"
            }

            $forbiddenPayloadPaths = @($normalizedPayloadListing | Where-Object {
                $_ -match '(?:^|/)(?:src|c_src|examples|doc|man|include|proper_ext|emacs)(?:/|$)' -or
                $_ -match '\.orig$' -or
                $_ -match '\.(?:a|la|key)$' -or
                $_ -match '\.(?:erl|hrl|c|h|o|src)$' -or
                $_ -match '(?:^|/)(?:README|HOWTO)[^/]*$' -or
                ($_ -match '\.pem$' -and $_ -notmatch '^lib/pkix-[^/]+/priv/cacert\.pem$') -or
                $_ -match '^etc(?:/|$)' -or
                $_ -match '^share/(?:terminfo|tabset)(?:/|$)' -or
                $_ -match '^lib/erlang/lib/(?:common_test|dialyzer|edoc|erl_interface|eunit)-[^/]+(?:/|$)' -or
                $_ -match '^lib/erlang/(?:Install|bin/(?:start|start_erl)|releases/start_erl\.data)$' -or
                $_ -match '^lib/erlang/erts-[^/]+/bin/start$' -or
                $_ -match '^lib/lib(?:formw|menuw|panelw)\.so' -or
                $_ -match '^bin/(?:clear|infocmp|tabs|tic|toe|tput|tset|reset|captoinfo|infotocap|openssl|sqlite3|ct_run|dialyzer|erlc|escript|run_erl|to_erl|typer)$' -or
                $_ -match '^lib/erlang/lib/(?:diameter|snmp)-[^/]+/bin/(?:diameterc|snmpc)$' -or
                $_ -match '(?:^|/)otp_test_engine\.so$'
            })
            Assert-True ($forbiddenPayloadPaths.Count -eq 0) ('SPK payload contains runtime-inutile or secret-bearing paths: ' + (($forbiddenPayloadPaths | Select-Object -First 8) -join ', '))
            $cryptoCallbacks = @($normalizedPayloadListing | Where-Object { $_ -match '^lib/erlang/lib/crypto-[^/]+/priv/lib/crypto_callback\.so$' })
            Assert-True ($cryptoCallbacks.Count -eq 1) 'SPK payload must contain exactly one OTP dynamic OpenSSL crypto_callback.so loader.'
            $httpdRuntimeModules = @($normalizedPayloadListing | Where-Object { $_ -match '^lib/erlang/lib/inets-[^/]+/ebin/httpd_example\.beam$' })
            Assert-True ($httpdRuntimeModules.Count -eq 1) 'SPK payload must retain the inets httpd_example.beam runtime module required by ejabberd.'
            $publicPemPaths = @($normalizedPayloadListing | Where-Object { $_ -match '\.pem$' })
            Assert-True ($publicPemPaths.Count -eq 1 -and $publicPemPaths[0] -match '^lib/pkix-[^/]+/priv/cacert\.pem$') 'SPK payload must contain exactly the allowlisted PKIX public CA PEM.'

            $payloadModeListing = @(& tar -tvzf $packageArchive)
            if ($LASTEXITCODE -ne 0) {
                Add-Failure 'Unable to inspect package.tgz modes.'
            }
            else {
                $uploadMonitorLine = $payloadModeListing | Where-Object { $_ -match '(?:^|\s)(?:\./)?bin/maer-upload-usage-check$' } | Select-Object -First 1
                Assert-True ([bool]$uploadMonitorLine) 'SPK payload listing has no upload usage monitor.'
                if ($uploadMonitorLine) { Assert-True ($uploadMonitorLine -match '^-rwxr-xr-x\s') 'Upload usage monitor mode must be 0755.' }
                foreach ($runtimeWebAsset in @(
                    'lib/ejabberd-26.07/priv/maer_portal/portal.css',
                    'lib/ejabberd-26.07/priv/maer_portal/portal.js',
                    'lib/ejabberd-26.07/priv/img/admin-logo.png',
                    'lib/ejabberd-26.07/priv/img/favicon.png'
                )) {
                    $runtimeWebAssetLine = $payloadModeListing |
                        Where-Object { $_ -match ('(?:^|\s)(?:\./)?' + [regex]::Escape($runtimeWebAsset) + '$') } |
                        Select-Object -First 1
                    Assert-True ([bool]$runtimeWebAssetLine) "SPK payload listing has no MAER runtime web asset: $runtimeWebAsset"
                    if ($runtimeWebAssetLine) {
                        Assert-True ($runtimeWebAssetLine -match '^-rw-r--r--\s') "MAER runtime web asset must have mode 0644: $runtimeWebAsset"
                    }
                }
                foreach ($entry in $payloadModeListing) {
                    if ($entry -notmatch '^(?<mode>\S{10})\s') {
                        continue
                    }
                    $mode = $matches.mode
                    Assert-True ($mode[0] -in @('-', 'd', 'l')) "Payload contains a special filesystem entry: $entry"
                    Assert-True ($mode[3] -notin @('s', 'S') -and $mode[6] -notin @('s', 'S')) "Payload contains a setuid/setgid entry: $entry"
                    if ($mode[0] -in @('-', 'd')) {
                        Assert-True ($mode[8] -ne 'w') "Payload contains a world-writable regular file or directory: $entry"
                    }
                }
            }
            $numericPayloadListing = @(& tar --numeric-owner -tvzf $packageArchive)
            if ($LASTEXITCODE -ne 0) {
                Add-Failure 'Unable to inspect numeric ownership of package.tgz.'
            }
            else {
                $payloadOwnershipMismatch = $numericPayloadListing | Where-Object { $_ -notmatch '^\S+\s+\d+\s+0\s+0\s+' } | Select-Object -First 1
                Assert-True (-not $payloadOwnershipMismatch) $(if ($payloadOwnershipMismatch) { "Payload entry is not owned by numeric 0:0: $payloadOwnershipMismatch" } else { 'Payload ownership is not numeric root.' })
            }

            $payloadRoot = Join-Path $temporaryRoot 'payload'
            New-Item -ItemType Directory -Path $payloadRoot | Out-Null
            & tar -xzf $packageArchive -C $payloadRoot
            if ($LASTEXITCODE -ne 0) {
                Add-Failure 'Unable to extract package.tgz for content inspection.'
            }
            else {
                $markerHit = Find-BinaryMarker -Root $payloadRoot -Markers @(
                    '/home/',
                    '/mnt/c/',
                    'C:\Users\',
                    'maer-spksrc',
                    'work-armada38x',
                    '-----BEGIN PRIVATE KEY-----',
                    '-----BEGIN RSA PRIVATE KEY-----',
                    '-----BEGIN EC PRIVATE KEY-----',
                    '-----BEGIN DSA PRIVATE KEY-----',
                    '-----BEGIN ENCRYPTED PRIVATE KEY-----',
                    '-----BEGIN OPENSSH PRIVATE KEY-----'
                )
                Assert-True ($null -eq $markerHit) $(if ($markerHit) { "Payload contains forbidden marker '$($markerHit.Marker)' in '$($markerHit.Path)'." } else { 'Payload contains a forbidden build path, secret, or legacy-domain marker.' })

                $embeddedConfigPath = Join-Path $payloadRoot 'share\maerxmppserver\defaults\ejabberd.yml'
                $sourceConfigPath = Join-Path $overlayRoot 'spk\maerxmppserver\src\defaults\ejabberd.yml'
                Assert-True (Test-Path -LiteralPath $embeddedConfigPath -PathType Leaf) 'SPK payload has no embedded default configuration.'
                if ((Test-Path -LiteralPath $embeddedConfigPath -PathType Leaf) -and
                    (Test-Path -LiteralPath $sourceConfigPath -PathType Leaf)) {
                    $embeddedConfigHash = (Get-FileHash -LiteralPath $embeddedConfigPath -Algorithm SHA256).Hash
                    $sourceConfigHash = (Get-FileHash -LiteralPath $sourceConfigPath -Algorithm SHA256).Hash
                    Assert-Equal $embeddedConfigHash $sourceConfigHash 'SPK embedded configuration differs from the validated source profile.'
                }

                foreach ($runtimeWebAsset in @(
                    [pscustomobject]@{
                        Payload = 'lib\ejabberd-26.07\priv\maer_portal\portal.css'
                        Source = 'priv\maer_portal\portal.css'
                    },
                    [pscustomobject]@{
                        Payload = 'lib\ejabberd-26.07\priv\maer_portal\portal.js'
                        Source = 'priv\maer_portal\portal.js'
                    },
                    [pscustomobject]@{
                        Payload = 'lib\ejabberd-26.07\priv\img\admin-logo.png'
                        Source = 'maer\assets\maer-mark.png'
                    },
                    [pscustomobject]@{
                        Payload = 'lib\ejabberd-26.07\priv\img\favicon.png'
                        Source = 'maer\assets\maer-mark.png'
                    }
                )) {
                    $embeddedAssetPath = Join-Path $payloadRoot $runtimeWebAsset.Payload
                    $reviewedAssetPath = Join-Path $repositoryRoot $runtimeWebAsset.Source
                    Assert-True (Test-Path -LiteralPath $embeddedAssetPath -PathType Leaf) "SPK payload has no reviewed MAER web asset: $($runtimeWebAsset.Payload)"
                    Assert-True (Test-Path -LiteralPath $reviewedAssetPath -PathType Leaf) "Reviewed MAER web asset source is missing: $($runtimeWebAsset.Source)"
                    if ((Test-Path -LiteralPath $embeddedAssetPath -PathType Leaf) -and
                        (Test-Path -LiteralPath $reviewedAssetPath -PathType Leaf)) {
                        $embeddedAssetHash = (Get-FileHash -LiteralPath $embeddedAssetPath -Algorithm SHA256).Hash
                        $reviewedAssetHash = (Get-FileHash -LiteralPath $reviewedAssetPath -Algorithm SHA256).Hash
                        Assert-Equal $embeddedAssetHash $reviewedAssetHash "SPK MAER web asset differs from its reviewed source: $($runtimeWebAsset.Payload)"
                    }
                }

                $installedApplicationsPath = Join-Path $payloadRoot 'lib\erlang\releases\27\installed_application_versions'
                Assert-True (Test-Path -LiteralPath $installedApplicationsPath -PathType Leaf) 'OTP installed-application inventory is missing.'
                if (Test-Path -LiteralPath $installedApplicationsPath -PathType Leaf) {
                    $installedApplications = Get-Content -LiteralPath $installedApplicationsPath -Raw
                    Assert-True (-not ($installedApplications -match '(?m)^(?:common_test|dialyzer|edoc|erl_interface|eunit)-')) 'OTP installed-application inventory still names a pruned development application.'
                }

                $gpl3Path = Join-Path $payloadRoot 'share\maerxmppserver\licenses\GPL-3.0.txt'
                $runtimeExceptionPath = Join-Path $payloadRoot 'share\maerxmppserver\licenses\GCC-Runtime-Library-Exception.txt'
                $libatomicSourcePath = Join-Path $payloadRoot 'share\maerxmppserver\licenses\libatomic-GCC-8.5.0-SOURCE.txt'
                if (Test-Path -LiteralPath $gpl3Path -PathType Leaf) {
                    $gpl3Text = Get-Content -LiteralPath $gpl3Path -Raw
                    Assert-True ($gpl3Text -match 'GNU GENERAL PUBLIC LICENSE' -and $gpl3Text -match 'Version 3, 29 June 2007') 'Bundled libatomic GPLv3 text is invalid.'
                }
                if (Test-Path -LiteralPath $runtimeExceptionPath -PathType Leaf) {
                    $runtimeExceptionText = Get-Content -LiteralPath $runtimeExceptionPath -Raw
                    Assert-True ($runtimeExceptionText -match 'GCC RUNTIME LIBRARY EXCEPTION' -and $runtimeExceptionText -match 'Version 3\.1') 'Bundled GCC Runtime Library Exception is invalid.'
                }
                if (Test-Path -LiteralPath $libatomicSourcePath -PathType Leaf) {
                    $libatomicSourceText = Get-Content -LiteralPath $libatomicSourcePath -Raw
                    Assert-True ($libatomicSourceText.Contains('https://ftp.gnu.org/gnu/gcc/gcc-8.5.0/gcc-8.5.0.tar.xz')) 'libatomic source notice has no canonical GCC 8.5.0 source URL.'
                    Assert-True ($libatomicSourceText.Contains('d308841a511bb830a6100397b0042db24ce11f642dab6ea6ee44842e5325ed50')) 'libatomic source notice has no verified GCC 8.5.0 source hash.'
                    Assert-True ($libatomicSourceText.Contains('armada38x-gcc850_glibc226_hard-GPL.txz')) 'libatomic source notice has no exact Synology binary provenance.'
                }
            }
        }
        else {
            Add-Failure 'Built SPK has no package.tgz payload.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }
}

$requiredFiles = @(
    'LOCKS.json',
    'LICENSES\BSD-3-Clause.txt',
    'README.md',
    'prepare-overlay.ps1',
    'prepare-overlay.sh',
    'spksrc-overlay\native\erlang-maer\Makefile',
    'spksrc-overlay\native\erlang-maer\digests',
    'spksrc-overlay\cross\erlang-maer\Makefile',
    'spksrc-overlay\cross\erlang-maer\digests',
    'spksrc-overlay\cross\erlang-maer\PLIST.auto',
    'spksrc-overlay\cross\erlang-maer\patches\000-configure-add-ncursesw-to-termcap-libraries.patch',
    'spksrc-overlay\cross\erlang-maer\patches\001-fix-openssl-include-order.patch',
    'spksrc-overlay\cross\erlang-maer\patches\002-sanitize-erts-build-flags.patch',
    'spksrc-overlay\cross\openssl3-maer\Makefile',
    'spksrc-overlay\cross\openssl3-maer\digests',
    'spksrc-overlay\cross\openssl3-maer\PLIST',
    'spksrc-overlay\cross\openssl3-maer\patches\001-sanitize-build-information.patch',
    'spksrc-overlay\cross\maerxmppserver\Makefile',
    'spksrc-overlay\cross\maerxmppserver\digests',
    'spksrc-overlay\cross\maerxmppserver\PLIST.auto',
    'spksrc-overlay\cross\maerxmppserver\patches\002-rebar-deterministic-beam.patch',
    'spksrc-overlay\cross\maerxmppserver\patches\003-maer-user-portal.patch',
    'spksrc-overlay\cross\maerxmppserver\patches\004-maer-webadmin.patch',
    'tests\inspect-pairing-beam.escript',
    'spksrc-overlay\spk\maerxmppserver\Makefile',
    'spksrc-overlay\spk\maerxmppserver\src\COPYING',
    'spksrc-overlay\spk\maerxmppserver\src\libatomic-GCC-8.5.0-SOURCE.txt',
    'spksrc-overlay\spk\maerxmppserver\src\maerxmppserver.png',
    'spksrc-overlay\spk\maerxmppserver\src\service-setup.sh',
    'spksrc-overlay\spk\maerxmppserver\src\service-start-stop.sh',
    'spksrc-overlay\spk\maerxmppserver\src\upload-usage-check.sh',
    'operator\maer-certificate-sync',
    'operator\install-certificate-sync-root',
    'operator\maer-bootstrap-admin',
    'operator\install-bootstrap-admin-root',
    'spksrc-overlay\spk\maerxmppserver\src\maerxmppserver.sc',
    'spksrc-overlay\spk\maerxmppserver\src\defaults\ejabberd.yml',
    'spksrc-overlay\spk\maerxmppserver\src\defaults\ejabberdctl.cfg',
    'spksrc-overlay\spk\maerxmppserver\src\defaults\inetrc',
    'spksrc-overlay\spk\maerxmppserver\src\wizard\install_uifile',
    'spksrc-overlay\spk\maerxmppserver\src\wizard\upgrade_uifile',
    'PUBLICATION-PREFLIGHT.md',
    'dsm-publication-preflight.ps1',
    'tests\expected-info.json',
    'tests\path-utils.ps1',
    'tests\release-gate.ps1',
    'tests\test-spk-path-resolution.ps1',
    'tests\test-clean-checkouts.ps1',
    'tests\test-service-contract.sh',
    'tests\test-upload-monitor.sh',
    'tests\test-certificate-sync.sh',
    'tests\test-bootstrap-admin.sh',
    'tests\test-maer-portal.ps1',
    'tests\test-server-patches.ps1'
)
foreach ($relativeFile in $requiredFiles) {
    Assert-True (Test-Path -LiteralPath (Join-Path $synologyRoot $relativeFile) -PathType Leaf) "Required file is missing: $relativeFile"
}

$expected = Get-Content -LiteralPath (Join-Path $testsRoot 'expected-info.json') -Raw | ConvertFrom-Json
$locks = Get-Content -LiteralPath (Join-Path $synologyRoot 'LOCKS.json') -Raw | ConvertFrom-Json

$spkMakefilePath = Join-Path $overlayRoot 'spk\maerxmppserver\Makefile'
$spkMakefile = Read-TextNormalized $spkMakefilePath
Assert-Equal (Get-MakeValue $spkMakefile 'SPK_NAME') $expected.package 'SPK package identifier mismatch.'
Assert-Equal ((Get-MakeValue $spkMakefile 'SPK_VERS') + '-' + (Get-MakeValue $spkMakefile 'SPK_REV')) $expected.version 'SPK version mismatch.'
Assert-Equal (Get-MakeValue $spkMakefile 'DISPLAY_NAME') $expected.displayname 'SPK display name mismatch.'
Assert-True ($spkMakefile -match '(?m)^override DISTRIBUTOR = MAER$') 'SPK distributor must override an empty repository-wide local.mk value.'
Assert-True ($spkMakefile -match '(?m)^override DISTRIBUTOR_URL = https://github\.com/jeff-net52/MAER-XMPP-Server$') 'SPK distributor URL must override an empty repository-wide local.mk value.'
Assert-Equal (Get-MakeValue $spkMakefile 'OS_MIN_VER') $expected.os_min_ver 'SPK minimum DSM mismatch.'
Assert-Equal (Get-MakeValue $spkMakefile 'REQUIRED_MIN_DSM') '7.1' 'Armada38x must build with the latest available DSM 7.1 SDK.'
Assert-Equal (Get-MakeValue $spkMakefile 'SERVICE_USER') 'auto' 'DSM service user must be generated by spksrc.'
Assert-Equal (Get-MakeValue $spkMakefile 'STARTABLE') 'yes' 'SPK must remain startable.'
Assert-Equal (Get-MakeValue $spkMakefile 'WIZARDS_DIR') 'src/wizard' 'spksrc must copy the reviewed install and upgrade wizards into WIZARD_UIFILES.'
Assert-Equal (Get-MakeValue $spkMakefile 'UNSUPPORTED_ARCHS') '$(filter-out armada38x,$(ALL_ARCHS))' 'SPK architecture gate mismatch.'
Assert-True ($spkMakefile -match '(?m)^\s*chmod 755 \$\(STAGING_DIR\)/bin/ejabberdctl$') 'Packaged ejabberdctl must be executable by the DSM service user.'
Assert-Equal (Get-MakeValue $spkMakefile 'POST_STRIP_TARGET') 'maerxmppserver_runtime_finalize' 'Runtime hardening must run after the standard strip phase.'
Assert-Equal (Get-MakeValue $spkMakefile 'POST_SERVICE_TARGET') 'maerxmppserver_service_finalize' 'DSM service script modes must be finalized before outer packaging.'
Assert-Equal (Get-MakeValue $spkMakefile 'RUNTIME_RPATH') '/var/packages/maerxmppserver/target/lib' 'Runtime RPATH must use only the canonical package library path.'
Assert-Equal (Get-MakeValue $spkMakefile 'MAER_SERVER_COMMIT') $locks.maer_xmpp_server.commit 'SPK runtime asset source must use the immutable MAER server commit.'
Assert-Equal (Get-MakeValue $spkMakefile 'MAER_SERVER_SOURCE_DIR') '$(WORK_DIR)/MAER-XMPP-Server-$(MAER_SERVER_COMMIT)' 'SPK runtime assets must come from the patched source tree in the active SPK work directory.'
Assert-Equal (Get-MakeValue $spkMakefile 'MAER_EJABBERD_RUNTIME_DIR') '$(STAGING_DIR)/lib/ejabberd-26.07' 'MAER web assets must target the exact ejabberd runtime directory.'
Assert-Equal (Get-MakeValue $spkMakefile 'MAER_PORTAL_RUNTIME_DIR') '$(MAER_EJABBERD_RUNTIME_DIR)/priv/maer_portal' 'Portal assets must target the exact runtime priv directory.'
Assert-Equal (Get-MakeValue $spkMakefile 'MAER_WEBADMIN_IMAGE_RUNTIME_DIR') '$(MAER_EJABBERD_RUNTIME_DIR)/priv/img' 'MAER image assets must target the exact runtime image directory.'
Assert-Equal (Get-MakeValue $spkMakefile 'MAER_SOURCE_DATE_EPOCH') '1785110400' 'SPK archive timestamp must be pinned to the package release date.'
Assert-Equal (Get-MakeValue $spkMakefile 'MAER_REPRODUCIBLE_TAR_OPTIONS') '--sort=name --mtime=@$(MAER_SOURCE_DATE_EPOCH) --owner=0 --group=0 --numeric-owner' 'SPK archives must use stable ordering, mtimes, and numeric ownership.'
Assert-True ($spkMakefile -match '(?m)^\$\(SPK_FILE_NAME\): export TAR_OPTIONS = \$\(MAER_REPRODUCIBLE_TAR_OPTIONS\)$') 'Reproducible tar options must be scoped to both SPK archive layers.'
Assert-True ($spkMakefile -match '(?m)^\$\(SPK_FILE_NAME\): export GZIP = -n$') 'The package.tgz gzip header must omit build-time metadata.'
Assert-True ($spkMakefile -match '(?m)^\s*install -m 755 src/upload-usage-check\.sh \$\(STAGING_DIR\)/bin/maer-upload-usage-check$') 'Global upload usage monitor must be installed as an executable.'
Assert-True ($spkMakefile.Contains('install -m 755 -d $(MAER_PORTAL_RUNTIME_DIR) $(MAER_WEBADMIN_IMAGE_RUNTIME_DIR)')) 'SPK copy target must create only the reviewed MAER runtime asset directories with mode 0755.'
foreach ($runtimeAssetInstall in @(
    'install -m 644 $(MAER_SERVER_SOURCE_DIR)/priv/maer_portal/portal.css $(MAER_PORTAL_RUNTIME_DIR)/portal.css',
    'install -m 644 $(MAER_SERVER_SOURCE_DIR)/priv/maer_portal/portal.js $(MAER_PORTAL_RUNTIME_DIR)/portal.js',
    'install -m 644 $(MAER_SERVER_SOURCE_DIR)/maer/assets/maer-mark.png $(MAER_WEBADMIN_IMAGE_RUNTIME_DIR)/admin-logo.png',
    'install -m 644 $(MAER_SERVER_SOURCE_DIR)/maer/assets/maer-mark.png $(MAER_WEBADMIN_IMAGE_RUNTIME_DIR)/favicon.png'
)) {
    Assert-True ($spkMakefile.Contains($runtimeAssetInstall)) "SPK copy target is missing an explicit mode-0644 runtime asset install: $runtimeAssetInstall"
}
Assert-True (-not ($spkMakefile -match '(?m)^\s*(?:cp|install).*\b(?:src|priv)/?\s+\$\(STAGING_DIR\)')) 'SPK copy target must never copy an entire source or priv directory into the runtime.'
Assert-Equal (Get-MakeValue $spkMakefile 'GROUP') 'sc-maerxmppserver' 'Package must use its isolated service group.'
Assert-True ($spkMakefile -match 'beam_lib:strip_files\(Files\)') 'Runtime finalization must strip reproducibility metadata from every BEAM file.'
Assert-True ($spkMakefile -match 'patchelf --force-rpath --set-rpath "\$\(RUNTIME_RPATH\)"') 'Runtime finalization must canonicalize every dynamic ELF RPATH.'
Assert-Equal (Get-MakeValue $spkMakefile 'OTP_DEVELOPMENT_APPLICATIONS') 'common_test dialyzer edoc erl_interface eunit' 'Runtime pruning must remove the deterministic OTP development-application allowlist.'
Assert-True ($spkMakefile -match "find \$\(STAGING_DIR\) -type f -name '\*\.orig' -delete") 'Runtime finalization must delete backup .orig files.'
Assert-True (-not ($spkMakefile -match "-iname '\*example\*'")) 'Runtime finalization must not prune OTP runtime modules merely because their filename contains example.'
Assert-True ($spkMakefile -match "-name '\*\.key'") 'Runtime finalization must reject private-key files.'
Assert-True ($spkMakefile -match [regex]::Escape('lib/pkix-*/priv/cacert.pem')) 'Runtime finalization must allowlist only the PKIX public CA PEM.'
Assert-True ($spkMakefile -match [regex]::Escape('-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----')) 'Runtime finalization must reject embedded private-key PEM blocks.'
Assert-True ($spkMakefile -match 'share/maerxmppserver/licenses') 'Runtime finalization must install third-party license notices.'
Assert-True ($spkMakefile -match [regex]::Escape('share/licenses/gcc/COPYING3')) 'Runtime finalization must install the GPLv3 text for libatomic.'
Assert-True ($spkMakefile -match [regex]::Escape('libatomic-GCC-8.5.0-SOURCE.txt')) 'Runtime finalization must install the libatomic source notice.'
Assert-True ($spkMakefile -match [regex]::Escape('idna-7.1.0-NOTICE.txt')) 'Runtime finalization must install the idna Apache attribution notice.'
Assert-True ($spkMakefile -match "sed -i -E '/\^\(common_test\|dialyzer\|edoc\|erl_interface\|eunit\)-/d'") 'Runtime finalization must remove pruned applications from the OTP inventory.'
Assert-True ($spkMakefile -match [regex]::Escape('$(STAGING_DIR)/lib/erlang/Install')) 'Runtime finalization must remove the stale OTP installer.'
Assert-True ($spkMakefile -match [regex]::Escape('$(STAGING_DIR)/lib/erlang/bin/start')) 'Runtime finalization must remove stale embedded launchers.'
Assert-True ($spkMakefile -match [regex]::Escape("! grep -R -a -F -l -- 'run_erl'")) 'Runtime finalization must reject dangling run_erl references.'
Assert-True ($spkMakefile -match '(?m)^\s*chmod 755 \$\(DSM_SCRIPTS_DIR\)/service-setup$') 'Generated DSM service-setup must be executable in the SPK.'
Assert-True ($spkMakefile -match 'find \$\(STAGING_DIR\) -xtype l -print -quit') 'Runtime finalization must reject dangling symbolic links.'
Assert-True ($spkMakefile -match '\$\(TC_PATH\)\$\(TC_PREFIX\)readelf.*-dW') 'Runtime finalization must inspect target ELF NEEDED dependencies.'
Assert-True ($spkMakefile -match 'unresolved NEEDED library') 'Runtime finalization must fail closed on an unresolved non-system ELF dependency.'
Assert-True (-not ($spkMakefile -match '(?m)^\s*(SPK_COMMANDS|INSTALL_REPLACE_PACKAGES|SPK_CONFLICT)\s*=')) 'SPK must not create global commands, replace, or conflict with another package.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $overlayRoot 'spk\maerxmppserver\src\conf\privilege'))) 'A manual privilege file would race with the DSM 7 generator.'
Assert-Equal ('sc-' + $expected.package) $expected.username 'Expected DSM username is inconsistent.'
Assert-Equal $expected.run_as 'package' 'Expected DSM run-as must be package.'
Assert-Equal $expected.groupname 'sc-maerxmppserver' 'Expected DSM group must remain isolated to this service.'

Assert-Equal $locks.package.name $expected.package 'LOCKS package name mismatch.'
Assert-Equal $locks.package.display_name $expected.displayname 'LOCKS display name mismatch.'
Assert-Equal $locks.package.version $expected.version 'LOCKS package version mismatch.'
Assert-Equal $locks.package.arch $expected.arch 'LOCKS architecture mismatch.'
Assert-Equal $locks.package.os_min_ver $expected.os_min_ver 'LOCKS DSM version mismatch.'
Assert-Equal $locks.spksrc.commit '954871e356f7f990c179eb58af11c20d82872d8f' 'spksrc commit lock mismatch.'
Assert-Equal $locks.toolchain.target 'armada38x-7.1' 'Toolchain target lock mismatch.'
Assert-Equal $locks.toolchain.triplet 'arm-unknown-linux-gnueabi' 'Toolchain triplet lock mismatch.'
Assert-True ([bool]$locks.toolchain.hard_float) 'Toolchain must remain hard-float.'
Assert-Equal $locks.maer_xmpp_server.commit 'fea59faa0224c7a8f52751eed0bd4d21f55c8d93' 'MAER public source commit lock mismatch.'
Assert-Equal $locks.maer_xmpp_server.archive 'https://github.com/jeff-net52/MAER-XMPP-Server/archive/fea59faa0224c7a8f52751eed0bd4d21f55c8d93.tar.gz' 'MAER public source archive URL mismatch.'
Assert-Equal $locks.maer_xmpp_server.bytes 3272795 'MAER public source archive size mismatch.'
Assert-True (-not ($locks.maer_xmpp_server.PSObject.Properties.Name -contains 'tag')) 'MAER source lock must not depend on a tag.'

$nativeOtpMakefile = Read-TextNormalized (Join-Path $overlayRoot 'native\erlang-maer\Makefile')
$crossOtpMakefile = Read-TextNormalized (Join-Path $overlayRoot 'cross\erlang-maer\Makefile')
$crossOtpNcursesPatch = Read-TextNormalized (Join-Path $overlayRoot 'cross\erlang-maer\patches\000-configure-add-ncursesw-to-termcap-libraries.patch')
$crossOtpOpenSslPatch = Read-TextNormalized (Join-Path $overlayRoot 'cross\erlang-maer\patches\001-fix-openssl-include-order.patch')
$crossOtpBuildFlagsPatch = Read-TextNormalized (Join-Path $overlayRoot 'cross\erlang-maer\patches\002-sanitize-erts-build-flags.patch')
$opensslMakefile = Read-TextNormalized (Join-Path $overlayRoot 'cross\openssl3-maer\Makefile')
$opensslBuildInfoPatch = Read-TextNormalized (Join-Path $overlayRoot 'cross\openssl3-maer\patches\001-sanitize-build-information.patch')
$serverMakefile = Read-TextNormalized (Join-Path $overlayRoot 'cross\maerxmppserver\Makefile')
$rebarDeterministicPatch = Read-TextNormalized (Join-Path $overlayRoot 'cross\maerxmppserver\patches\002-rebar-deterministic-beam.patch')
$portalSourcePatch = Read-TextNormalized (Join-Path $overlayRoot 'cross\maerxmppserver\patches\003-maer-user-portal.patch')
$webAdminSourcePatch = Read-TextNormalized (Join-Path $overlayRoot 'cross\maerxmppserver\patches\004-maer-webadmin.patch')
$serverPatchNames = @(Get-ChildItem -LiteralPath (Join-Path $overlayRoot 'cross\maerxmppserver\patches') -File | Sort-Object Name | ForEach-Object Name)
Assert-Equal ($serverPatchNames -join ',') '002-rebar-deterministic-beam.patch,003-maer-user-portal.patch,004-maer-webadmin.patch' 'Server patch inventory must contain only deterministic compilation and the reviewed MAER additions.'
Assert-Equal (Get-MakeValue $nativeOtpMakefile 'PKG_VERS') $locks.erlang_otp.version 'Native OTP version mismatch.'
Assert-Equal (Get-MakeValue $crossOtpMakefile 'PKG_VERS') $locks.erlang_otp.version 'Cross OTP version mismatch.'
Assert-Equal (Get-MakeValue $serverMakefile 'PKG_COMMIT') $locks.maer_xmpp_server.commit 'MAER source commit mismatch.'
Assert-Equal (Get-MakeValue $serverMakefile 'PKG_DIST_NAME') '$(PKG_COMMIT).$(PKG_EXT)' 'MAER source archive name must derive from the immutable commit.'
Assert-Equal (Get-MakeValue $serverMakefile 'PKG_DIST_SITE') 'https://github.com/jeff-net52/MAER-XMPP-Server/archive' 'MAER source archive site mismatch.'
Assert-Equal (Get-MakeValue $serverMakefile 'PKG_DIST_FILE') '$(PKG_NAME)-$(PKG_COMMIT).$(PKG_EXT)' 'MAER cached archive name mismatch.'
Assert-Equal (Get-MakeValue $serverMakefile 'PKG_DIR') 'MAER-XMPP-Server-$(PKG_COMMIT)' 'MAER extracted directory mismatch.'
Assert-True (-not ($serverMakefile -match '(?m)^PKG_TAG\s*=')) 'MAER build must not depend on a tag.'
Assert-True ($crossOtpMakefile -match '(?m)^CONFIGURE_ARGS \+= --disable-year2038$') 'ARMv7 OTP recipe must explicitly declare the time32 compatibility choice.'
Assert-True ($nativeOtpMakefile -match '(?m)^CONFIGURE_ARGS \+= --disable-pgo$') 'Native OTP build tools must disable profile-guided optimization.'
Assert-True ($nativeOtpMakefile -match '(?m)^CONFIGURE_ARGS \+= --enable-deterministic-build$') 'Native OTP must use its official deterministic-build mode.'
Assert-True ($crossOtpMakefile -match '(?m)^CONFIGURE_ARGS \+= --enable-deterministic-build$') 'Cross OTP must use its official deterministic-build mode.'
Assert-Equal (Get-MakeValue $crossOtpMakefile 'NATIVE_ERLANG_BIN_DIR') '$(abspath $(WORK_DIR)/../../../native/erlang-maer/work-native/install/usr/local/bin)' 'Cross OTP native Erlang path must not depend on prior filesystem existence.'
Assert-Equal (Get-MakeValue $crossOtpMakefile 'ENV') 'PATH=$(NATIVE_ERLANG_BIN_DIR):$$PATH' 'Pinned native OTP must take precedence over the system Erlang runtime.'
Assert-True (-not ($serverMakefile.Contains('ERL_COMPILER_OPTIONS'))) 'Deterministic compiler options must not leak from spksrc into OTP dependency builds.'
Assert-True ($rebarDeterministicPatch.Contains('{erl_opts, [deterministic,')) 'Root ejabberd rebar options must enable deterministic BEAM output.'
foreach ($portalPatchPath in @('src/maer_portal_smtp.erl', 'src/mod_maer_portal.erl', 'priv/maer_portal/portal.css', 'priv/maer_portal/portal.js')) {
    Assert-True ($portalSourcePatch.Contains("+++ $portalPatchPath")) "Locked server patch must add the portal file with a patch -p0 path: $portalPatchPath"
}
Assert-True ($webAdminSourcePatch.Contains('+++ src/ejabberd_web_admin.erl')) 'Locked server patch must contain the reviewed WebAdmin users-page fix with a patch -p0 path.'
Assert-True ($webAdminSourcePatch.Contains('+++ priv/css/admin.css')) 'Locked server patch must contain the MAER WebAdmin theme with a patch -p0 path.'
foreach ($serverPatch in @($rebarDeterministicPatch, $portalSourcePatch, $webAdminSourcePatch)) {
    Assert-True (-not ($serverPatch -match '(?m)^(?:---|\+\+\+) [ab]/')) 'Server patches must not use Git a/ or b/ prefixes because spksrc applies them with patch -p0.'
}
Assert-True ($serverMakefile.Contains('cp maer/assets/maer-mark.png priv/img/admin-logo.png')) 'WebAdmin build must install the reviewed MAER logo.'
Assert-True ($serverMakefile.Contains('cp maer/assets/maer-mark.png priv/img/favicon.png')) 'WebAdmin build must install the reviewed MAER favicon.'
Assert-True ($rebarDeterministicPatch.Contains('{add, [{erl_opts, [deterministic]}]}')) 'All locked rebar dependencies must enable deterministic BEAM output.'
Assert-True ($crossOtpNcursesPatch -match 'termcap_libs="tinfo ncursesw ncurses curses termcap termlib"') 'Cross OTP must probe the ncursesw library that spksrc actually stages.'
Assert-True ($crossOtpOpenSslPatch -match 'CFLAGS = -Iopenssl/include @LIB_CFLAGS@') 'Cross OTP erl_interface must prefer its staged OpenSSL 3 headers.'
Assert-True ($crossOtpOpenSslPatch -match 'TYPE_FLAGS = -Iopenssl/include @CFLAGS@') 'Cross OTP must prefer its staged OpenSSL 3 headers.'
Assert-True ($crossOtpMakefile -match '(?m)^DEPENDS\s*=.*\bcross/openssl3-maer\b') 'Cross OTP must use the reproducible MAER OpenSSL runtime.'
Assert-True ($serverMakefile -match '(?m)^DEPENDS\s*\+=.*\bcross/openssl3-maer\b') 'MAER server must use the reproducible MAER OpenSSL runtime.'
Assert-Equal (Get-MakeValue $opensslMakefile 'PKG_VERS') $locks.openssl.version 'OpenSSL version mismatch.'
Assert-True ($opensslMakefile -match '(?m)^ENV \+= SOURCE_DATE_EPOCH=1780963200$') 'OpenSSL build time must be pinned to the public 3.5.7 release date.'
Assert-True ($crossOtpBuildFlagsPatch -match [regex]::Escape('-v CFLAGS "MAER reproducible ARMv7 runtime"')) 'OTP emulator build metadata must be sanitized at compile time.'
Assert-True ($crossOtpBuildFlagsPatch -match [regex]::Escape('-v LDFLAGS "/var/packages/maerxmppserver/target/lib"')) 'OTP emulator metadata must contain only the canonical runtime library path.'
Assert-True ($opensslBuildInfoPatch -match [regex]::Escape('mkbuildinf.pl "MAER reproducible ARMv7 runtime"')) 'OpenSSL build metadata must be sanitized at compile time.'
Assert-True (-not ($serverMakefile -match 'sed -i\.orig')) 'Server recipe must not create .orig files.'
foreach ($otpMakefile in @($nativeOtpMakefile, $crossOtpMakefile)) {
    foreach ($guiApplication in @('wx', 'debugger', 'et', 'observer', 'reltool')) {
        Assert-True ($otpMakefile -match "(?m)^CONFIGURE_ARGS \+= --without-$guiApplication$") "OTP recipe must explicitly disable $guiApplication."
    }
    Assert-True (-not ($otpMakefile -match '(?m)^POST_CONFIGURE_TARGET\s*=')) 'OTP GUI exclusions must be expressed through configure arguments.'
}
Assert-True ($serverMakefile -match '(?m)^CONFIGURE_ARGS \+= --enable-sqlite$') 'MAER server recipe must compile SQLite support.'
Assert-True ($serverMakefile -match '(?m)^\s*-e ''s#\^INSTALLUSER=.*sc-maerxmppserver') 'Generated ejabberdctl must be restricted to the DSM package user.'

$otpDigestFiles = @(
    (Join-Path $overlayRoot 'native\erlang-maer\digests'),
    (Join-Path $overlayRoot 'cross\erlang-maer\digests')
)
foreach ($digestPath in $otpDigestFiles) {
    $digestText = Read-TextNormalized $digestPath
    Assert-True ($digestText -match [regex]::Escape("SHA256 $($locks.erlang_otp.sha256)")) "OTP SHA256 missing from $digestPath"
    Assert-True ($digestText -match [regex]::Escape("SHA1 $($locks.erlang_otp.sha1)")) "OTP SHA1 missing from $digestPath"
    Assert-True ($digestText -match [regex]::Escape("MD5 $($locks.erlang_otp.md5)")) "OTP MD5 missing from $digestPath"
}
$serverDigestText = Read-TextNormalized (Join-Path $overlayRoot 'cross\maerxmppserver\digests')
$serverDigestName = "maer-xmpp-server-$($locks.maer_xmpp_server.commit).tar.gz"
Assert-True ($serverDigestText -match ('(?m)^' + [regex]::Escape($serverDigestName) + '\s+SHA256\s+')) 'MAER digest filename does not derive from the locked commit.'
Assert-True ($serverDigestText -match [regex]::Escape("SHA256 $($locks.maer_xmpp_server.sha256)")) 'MAER source SHA256 missing from digests.'
Assert-True ($serverDigestText -match [regex]::Escape("SHA1 $($locks.maer_xmpp_server.sha1)")) 'MAER source SHA1 missing from digests.'
Assert-True ($serverDigestText -match [regex]::Escape("MD5 $($locks.maer_xmpp_server.md5)")) 'MAER source MD5 missing from digests.'
$opensslDigestText = Read-TextNormalized (Join-Path $overlayRoot 'cross\openssl3-maer\digests')
Assert-True ($opensslDigestText -match [regex]::Escape("SHA256 $($locks.openssl.sha256)")) 'OpenSSL source SHA256 missing from digests.'
Assert-True ($opensslDigestText -match [regex]::Escape("SHA1 $($locks.openssl.sha1)")) 'OpenSSL source SHA1 missing from digests.'
Assert-True ($opensslDigestText -match [regex]::Escape("MD5 $($locks.openssl.md5)")) 'OpenSSL source MD5 missing from digests.'

$iconPath = Join-Path $repositoryRoot 'maer\assets\maer-mark.png'
Assert-True (Test-Path -LiteralPath $iconPath -PathType Leaf) 'MAER package icon source is missing.'
if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
    $iconHash = (Get-FileHash -LiteralPath $iconPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $iconHash $locks.assets.maer_mark_sha256 'MAER icon hash mismatch.'
}
$packagedIconPath = Join-Path $overlayRoot 'spk\maerxmppserver\src\maerxmppserver.png'
$canonicalCopyingPath = Join-Path $repositoryRoot 'COPYING'
$packagedCopyingPath = Join-Path $overlayRoot 'spk\maerxmppserver\src\COPYING'
$libatomicSourceNoticePath = Join-Path $overlayRoot 'spk\maerxmppserver\src\libatomic-GCC-8.5.0-SOURCE.txt'
if (Test-Path -LiteralPath $packagedIconPath -PathType Leaf) {
    $packagedIconHash = (Get-FileHash -LiteralPath $packagedIconPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $packagedIconHash $locks.assets.maer_mark_sha256 'Packaged MAER icon hash mismatch.'
}
if ((Test-Path -LiteralPath $canonicalCopyingPath -PathType Leaf) -and (Test-Path -LiteralPath $packagedCopyingPath -PathType Leaf)) {
    $canonicalCopyingHash = (Get-FileHash -LiteralPath $canonicalCopyingPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $packagedCopyingHash = (Get-FileHash -LiteralPath $packagedCopyingPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $canonicalCopyingHash $locks.assets.copying_sha256 'Canonical COPYING hash mismatch.'
    Assert-Equal $packagedCopyingHash $locks.assets.copying_sha256 'Packaged COPYING hash mismatch.'
}
if (Test-Path -LiteralPath $libatomicSourceNoticePath -PathType Leaf) {
    $libatomicSourceNotice = Get-Content -LiteralPath $libatomicSourceNoticePath -Raw
    Assert-True ($libatomicSourceNotice.Contains('https://ftp.gnu.org/gnu/gcc/gcc-8.5.0/gcc-8.5.0.tar.xz')) 'libatomic source notice has no canonical GCC 8.5.0 source URL.'
    Assert-True ($libatomicSourceNotice.Contains('d308841a511bb830a6100397b0042db24ce11f642dab6ea6ee44842e5325ed50')) 'libatomic source notice has no verified GCC 8.5.0 source hash.'
    Assert-True ($libatomicSourceNotice.Contains('armada38x-gcc850_glibc226_hard-GPL.txz')) 'libatomic source notice has no exact Synology binary provenance.'
}

$prepareScript = Read-TextNormalized (Join-Path $synologyRoot 'prepare-overlay.ps1')
Assert-True ($prepareScript.Contains($locks.spksrc.commit)) 'Overlay preparation does not enforce the locked spksrc commit.'
Assert-True ($prepareScript -match 'status --porcelain') 'Overlay preparation must reject a dirty spksrc checkout.'
Assert-True ($prepareScript -match 'Refusing to overwrite') 'Overlay preparation must refuse existing target recipes.'
Assert-True ($prepareScript -match [regex]::Escape("'cross\openssl3-maer'")) 'PowerShell overlay preparation must install the reproducible OpenSSL recipe.'

$prepareShellPath = Join-Path $synologyRoot 'prepare-overlay.sh'
$prepareShellScript = Read-TextNormalized $prepareShellPath
Assert-True ($prepareShellScript.StartsWith("#!/usr/bin/env bash`n")) 'WSL overlay preparation must use Bash with LF endings.'
Assert-True ($prepareShellScript -match '(?m)^set -Eeuo pipefail$') 'WSL overlay preparation must enable strict Bash behavior.'
Assert-True ($prepareShellScript.Contains($locks.spksrc.commit)) 'WSL overlay preparation does not enforce the locked spksrc commit.'
Assert-True ($prepareShellScript -match 'GIT_OPTIONAL_LOCKS=0 git -C "\$SPKSRC_ROOT"') 'WSL overlay preparation must use native Git without optional index writes.'
Assert-True ($prepareShellScript -match 'status --porcelain=v1 --untracked-files=all') 'WSL overlay preparation must reject tracked and untracked changes.'
Assert-True ($prepareShellScript -match '(?m)^\s*--check\)$') 'WSL overlay preparation has no non-mutating --check mode.'
Assert-True ($prepareShellScript -match 'mktemp -d -- "\$SPKSRC_ROOT/\.maer-overlay-stage\.XXXXXXXX"') 'WSL staging must be created on the spksrc filesystem.'
Assert-True ($prepareShellScript -match '(?m)^trap cleanup EXIT$') 'WSL overlay preparation must install its rollback cleanup trap.'
Assert-True ($prepareShellScript -match 'MOVED_PATHS=\(\)') 'WSL overlay preparation must track only paths moved by the current run.'
Assert-True ($prepareShellScript -match 'find "\$STAGING_ROOT" -mindepth 1 -type d -exec chmod 0755') 'WSL overlay directory modes must be normalized to 0755.'
Assert-True ($prepareShellScript -match 'find "\$STAGING_ROOT" -type f -exec chmod 0644') 'WSL overlay file modes must be normalized to 0644.'
Assert-True ($prepareShellScript -match 'cross/openssl3-maer') 'WSL overlay preparation must install the reproducible OpenSSL recipe.'
Assert-True ($prepareShellScript -match 'chmod 0755 "\$STAGING_ROOT/spk/maerxmppserver/src/service-setup\.sh"') 'WSL overlay preparation must preserve executable mode for service-setup.'
Assert-True ($prepareShellScript -match 'chmod 0755 "\$STAGING_ROOT/spk/maerxmppserver/src/service-start-stop\.sh"') 'WSL overlay preparation must preserve executable mode for start-stop-status.'
Assert-True ($prepareShellScript -match 'RENAME_NOREPLACE = 1') 'WSL overlay installation must use an atomic no-replace rename.'
Assert-True ($prepareShellScript -match 'SPKSRC_DEVICE=\$\(stat -c') 'WSL overlay preparation must verify the staging filesystem device.'
Assert-True ($prepareShellScript -match 'MOVED_IDENTITIES=\(\)') 'WSL rollback must record identities created by the current run.'
Assert-True ($prepareShellScript -match 'STAGED_TREE_DIGEST=\$\(tree_digest') 'WSL overlay preparation must compare the complete staged tree with its validated source.'
Assert-True (-not ($prepareShellScript -match 'readonly\s+[A-Za-z_][A-Za-z0-9_]*=\$\(')) 'WSL overlay preparation must not mask command failures with readonly assignment.'
Assert-True (-not ($prepareShellScript -match '\[\[\s+-z\s+\$\(find')) 'WSL overlay preparation must not mask find failures inside a conditional substitution.'
Assert-True (-not ($prepareShellScript -match '(?m)^\s*git\s+config\b')) 'WSL overlay preparation must not change Git configuration.'
Assert-True (-not ($prepareShellScript -match '(?m)^\s*(export\s+)?HOME=')) 'WSL overlay preparation must not reassign HOME.'

$configPath = Join-Path $overlayRoot 'spk\maerxmppserver\src\defaults\ejabberd.yml'
$controlConfigPath = Join-Path $overlayRoot 'spk\maerxmppserver\src\defaults\ejabberdctl.cfg'
$serviceSetupPath = Join-Path $overlayRoot 'spk\maerxmppserver\src\service-setup.sh'
$serviceScriptPath = Join-Path $overlayRoot 'spk\maerxmppserver\src\service-start-stop.sh'
$installWizardPath = Join-Path $overlayRoot 'spk\maerxmppserver\src\wizard\install_uifile'
$upgradeWizardPath = Join-Path $overlayRoot 'spk\maerxmppserver\src\wizard\upgrade_uifile'
$uploadMonitorPath = Join-Path $overlayRoot 'spk\maerxmppserver\src\upload-usage-check.sh'
$certificateSyncPath = Join-Path $synologyRoot 'operator\maer-certificate-sync'
$certificateInstallerPath = Join-Path $synologyRoot 'operator\install-certificate-sync-root'
$bootstrapAdminPath = Join-Path $synologyRoot 'operator\maer-bootstrap-admin'
$bootstrapInstallerPath = Join-Path $synologyRoot 'operator\install-bootstrap-admin-root'
$firewallPath = Join-Path $overlayRoot 'spk\maerxmppserver\src\maerxmppserver.sc'
$attributesPath = Join-Path $repositoryRoot '.gitattributes'
$publicationGuidePath = Join-Path $synologyRoot 'PUBLICATION-PREFLIGHT.md'
$publicationPreflightPath = Join-Path $synologyRoot 'dsm-publication-preflight.ps1'
$workflowPath = Join-Path $repositoryRoot '.github\workflows\synology-package.yml'
$configText = Read-TextNormalized $configPath
$controlConfigText = Read-TextNormalized $controlConfigPath
$serviceSetupText = Read-TextNormalized $serviceSetupPath
$serviceScriptText = Read-TextNormalized $serviceScriptPath
$installWizardText = Read-TextNormalized $installWizardPath
$upgradeWizardText = Read-TextNormalized $upgradeWizardPath
$uploadMonitorText = Read-TextNormalized $uploadMonitorPath
$firewallText = Read-TextNormalized $firewallPath
$attributesText = Read-TextNormalized $attributesPath
$publicationGuideText = Read-TextNormalized $publicationGuidePath
$publicationPreflightText = Read-TextNormalized $publicationPreflightPath
$workflowText = Read-TextNormalized $workflowPath

Assert-True ($configText -match '(?m)^hosts:\s*\n\s+- xmpp\.maer\.fr$') 'Canonical XMPP host is missing.'
Assert-True ($configText -match '(?m)^\s+starttls_required: true$') 'Client TCP listener must require STARTTLS.'
Assert-True ($configText -match '(?m)^auth_stored_password_types:\s*\n\s+- scram_sha256$') 'Profile must store only SCRAM-SHA-256 credentials.'
Assert-Equal ([regex]::Matches($configText, '(?m)^  "webadmin commands":$').Count) 1 'Web-admin command ACL must be declared exactly once.'
foreach ($disabledMechanism in @('ANONYMOUS', 'CRAM-MD5', 'DIGEST-MD5', 'LOGIN', 'PLAIN', 'SCRAM-SHA-1', 'SCRAM-SHA-1-PLUS', 'SCRAM-SHA-512', 'SCRAM-SHA-512-PLUS')) {
    Assert-True ($configText -match "(?m)^  - $([regex]::Escape($disabledMechanism))$") "Legacy or unsupported SASL mechanism must be disabled: $disabledMechanism"
}
Assert-True (-not ($configText -match '(?m)^  - X-OAUTH2$')) 'X-OAUTH2 must remain available for MAER pairing tokens.'
foreach ($protocolOption in @('no_sslv3', 'no_tlsv1', 'no_tlsv1_1', 'cipher_server_preference', 'no_compression')) {
    Assert-True ($configText -match "(?m)^      - $([regex]::Escape($protocolOption))$" -or
        $configText -match "(?m)^  - $([regex]::Escape($protocolOption))$") "TLS protocol option is missing: $protocolOption"
}
Assert-True ($configText -match '(?m)^sql_type: sqlite$') 'Profile must use SQLite.'
Assert-True ($configText -match '(?m)^\s+mod_mam:$') 'MAM module is missing.'
Assert-True ($configText -match '(?m)^\s+mod_muc:$') 'MUC module is missing.'
Assert-True ($configText -match '(?m)^\s+/maer-pairing: mod_maer_pairing$') 'MAER pairing must be exposed only by the configured HTTPS listener.'
Assert-True ($configText -match '(?m)^\s+mod_maer_pairing: \{\}$') 'MAER pairing module is missing.'
Assert-True ($configText -match '(?m)^\s+/account: mod_maer_portal$') 'MAER account portal must be exposed by the configured HTTPS listener.'
Assert-True ($configText -match '(?m)^\s+mod_maer_portal:$') 'MAER account portal module is missing.'
Assert-True ($configText -match '(?m)^\s+database_path: /var/packages/maerxmppserver/var/data/maer-portal\.sqlite$') 'Portal must use its dedicated SQLite database.'
Assert-True ($configText -match '(?m)^\s+smtp_host: smtp-zose\.yulpa\.io$') 'Portal must use the reviewed Yulpa implicit-TLS SMTP endpoint.'
Assert-True ($configText -match '(?m)^\s+smtp_port: 465$') 'Portal SMTP must use implicit TLS on the reviewed port 465.'
Assert-True ($configText -match '(?m)^\s+smtp_username: no-reply@maer\.fr$') 'Portal SMTP must authenticate as the reviewed no-reply@maer.fr account.'
Assert-True ($configText -match '(?m)^\s+smtp_password_file: /var/packages/maerxmppserver/var/config/smtp-password$') 'Portal SMTP password must remain outside YAML in the server-side credential file.'
Assert-True ($configText -match '(?m)^\s+smtp_from: no-reply@maer\.fr$') 'Portal SMTP envelope and message sender must remain no-reply@maer.fr.'
Assert-True ($configText -match '(?m)^\s+mod_pubsub:$') 'PubSub/PEP module is missing.'
Assert-True ($configText -match '(?m)^\s+mod_push:$') 'Push module is missing.'
Assert-True (-not ($configText -match '(?m)^\s+mod_register:')) 'Public in-band registration must remain disabled.'
Assert-True (-not ($configText -match '(?m)^\s+mod_http_api:')) 'HTTP administration API must remain disabled.'
Assert-True (-not ($configText -match '(?m)^\s+mod_stun_disco:')) 'TURN discovery must remain disabled until secret provisioning exists.'
Assert-True ($configText -match '(?ms)^\s+port: 5280\n\s+ip: 127\.0\.0\.1\n\s+module: ejabberd_http\n\s+request_handlers:\n\s+/admin: ejabberd_web_admin$') 'Administration listener must remain loopback-only.'
Assert-True ($configText -match '(?ms)^\s+port: 5080\n\s+ip: 127\.0\.0\.1\n\s+module: ejabberd_http\n\s+request_handlers:\n\s+/: mod_maer_redirect$') 'HTTP redirect listener must remain dedicated and loopback-only.'
Assert-True ($configText -match '(?ms)^\s+port: 5443\n\s+ip: 127\.0\.0\.1\n\s+module: ejabberd_http\n\s+tls: true$') 'HTTPS protocol backend must remain TLS and loopback-only.'
Assert-True ($configText -match '(?m)^\s+ciphers: "HIGH:!aNULL:!eNULL:!3DES:!RC4:!MD5:!PSK:!SRP:@STRENGTH"$') 'HTTPS protocol backend must use the hardened cipher profile.'
Assert-True ($configText -match '(?m)^\s+tls_compression: false$') 'HTTPS protocol backend must disable TLS compression.'
Assert-True (-not ($configText -match '(?m)^\s+port: 5269$')) 'Private MAER profile must not listen on the S2S port 5269.'
Assert-True ($configText -match '(?ms)^\s+s2s:\n\s+deny: all$') 'Private MAER profile must deny all S2S routing.'
Assert-True ($configText.Contains('bosh_service_url: https://xmpp.maer.fr/http-bind')) 'Host-meta BOSH URL must use canonical public HTTPS 443.'
Assert-True ($configText.Contains('websocket_url: wss://xmpp.maer.fr/xmpp-websocket')) 'Host-meta WebSocket URL must use canonical public HTTPS 443.'
Assert-True ($configText.Contains('put_url: https://xmpp.maer.fr/upload')) 'HTTP Upload URL must use canonical public HTTPS 443.'
Assert-True (-not ($configText.Contains('xmpp.maer.fr:5443'))) 'Public protocol URLs must never expose the loopback backend port 5443.'
foreach ($header in @('Access-Control-Allow-Origin', 'Referrer-Policy', 'Strict-Transport-Security', 'X-Content-Type-Options', 'X-Frame-Options')) {
    Assert-True ($configText -match "(?m)^      $([regex]::Escape($header)):") "HTTPS listener security header is missing: $header"
}
Assert-True (-not ($configText.Contains('Content-Security-Policy:'))) 'Listener-wide CSP must not override the route-specific portal and HTTP Upload policies.'
Assert-Equal ([regex]::Matches($configText, '(?m)^\s+Access-Control-Allow-Origin: maer-chat://app$').Count) 2 'CORS must be restricted to the privileged Electron origin on the listener and upload module.'
Assert-True ($configText -match '(?m)^websocket_origin:\n  - https://xmpp\.maer\.fr\n  - maer-chat://app$') 'WebSocket browser origins must be restricted to the web UI and privileged Electron scheme.'
Assert-True (-not ($configText.Contains('file://'))) 'The unsafe Electron file origin must never be trusted.'
Assert-True ($configText -match '(?m)^trusted_proxies:\n  - 127\.0\.0\.0/8\n  - ::1/128$') 'Only IPv4 and IPv6 loopback proxies may be trusted globally.'
Assert-True (-not ($configText -match '(?m)^trusted_proxies:\s*all$|(?ms)^trusted_proxies:\s*\n\s+- all\s*$')) 'trusted_proxies must never accept all sources.'
Assert-True ($configText -match '(?ms)^  maer_fail2ban_exempt:\n    ip:\n      - 127\.0\.0\.0/8\n      - ::1/128\n      - 192\.168\.30\.0/24$') 'Fail2ban exemption must contain only loopback and the trusted LAN/hairpin subnet.'
Assert-True ($configText -match '(?ms)^  maer_fail2ban_whitelist:\n    allow: maer_fail2ban_exempt\n    deny: all$') 'Fail2ban whitelist must allow only the bounded exemption ACL and deny WAN sources.'
Assert-True ($configText -match '(?ms)^  mod_fail2ban:\n    access: maer_fail2ban_whitelist$') 'mod_fail2ban must use the bounded LAN whitelist.'
Assert-True ($configText -match '(?ms)^  soft_upload_quota:\n    500: all\n  hard_upload_quota:\n    600: all$') 'HTTP Upload soft/hard quotas must be exactly 500/600 MiB.'
Assert-True ($configText -match '(?ms)^  mod_http_upload_quota:\n    access_soft_quota: soft_upload_quota\n    access_hard_quota: hard_upload_quota\n    max_days: 30$') 'HTTP Upload quota module must enforce the declared rules and 30-day retention.'
Assert-True ($configText.Contains('/usr/local/etc/certificate/maerxmppserver/maerxmppserver_client/xmpp.pem')) 'Canonical root-managed certificate path is missing.'
Assert-True ($configText.Contains('/var/packages/maerxmppserver/var/data/ejabberd.sqlite')) 'Canonical SQLite path is missing.'
Assert-True ($firewallText -match '(?m)^dst\.ports="5222/tcp"$') 'DSM firewall profile must publish XMPP client port 5222.'
Assert-True (-not ($firewallText -match '(?m)^dst\.ports="[^"]*(?:5080|5269|5280|5443)')) 'DSM firewall profile must not publish redirect, S2S, administration, or HTTPS backend ports.'
Assert-True ($attributesText -match '(?m)^\* text=auto eol=lf$') 'Git must default detected text files to LF.'
Assert-True ($attributesText -match '(?m)^COPYING text eol=lf$') 'Canonical COPYING must have an explicit LF contract.'
Assert-True ($publicationGuideText.Contains('xmpp.maer.fr:443')) 'DSM publication guide must document the public 443 topology.'
Assert-True ($publicationGuideText.Contains('127.0.0.1:5443')) 'DSM publication guide must document the loopback HTTPS backend.'
Assert-True ($publicationGuideText.Contains('127.0.0.1:5080')) 'DSM publication guide must document the loopback HTTP redirect backend.'
Assert-True ($publicationGuideText -match '(?m)^- `/account`\.$') 'DSM publication guide must expose the user portal prefix.'
Assert-True ($publicationGuideText.Contains('_xmpp-client._tcp.xmpp.maer.fr')) 'DSM publication guide must document the client SRV record.'
Assert-True ($publicationPreflightText.Contains('"_xmpp-client._tcp.$Domain"')) 'DSM preflight must verify the client SRV record.'
Assert-True ($publicationPreflightText -match 'privatePort in @\(4369, 5080, 5211, 5269, 5280, 5443\)') 'DSM preflight must verify all private redirect, Erlang, S2S, admin, and backend ports remain closed.'
Assert-True ($publicationPreflightText.Contains("@('/admin/', '/api')")) 'DSM preflight must prove the administration and API routes are absent.'
Assert-True ($publicationPreflightText.Contains('Test-XmppStartTls')) 'DSM preflight must verify XMPP STARTTLS and SASL at runtime.'
Assert-True ($publicationPreflightText.Contains('Test-ObsoleteTlsRejection')) 'DSM preflight must reject TLS 1.0 and TLS 1.1 explicitly.'
Assert-True ($publicationPreflightText.Contains('$RetiredDomain')) 'DSM preflight must verify the retired domain supplied by the operator.'
Assert-True ($publicationPreflightText.Contains('https://untrusted.invalid')) 'DSM preflight must reject a hostile WebSocket origin.'
Assert-True ($publicationPreflightText.Contains("Path = '/account/'")) 'DSM preflight must verify the public user portal.'
Assert-True ($workflowText -match 'uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683') 'GitHub checkout action must be pinned to the immutable v4.2.2 commit.'
Assert-Equal ([regex]::Matches($workflowText, '(?m)^\s+- src/mod_maer_pairing\.erl$').Count) 2 'Pairing source changes must trigger both push and pull-request package validation.'
Assert-Equal ([regex]::Matches($workflowText, '(?m)^\s+- src/mod_maer_redirect\.erl$').Count) 2 'Redirect source changes must trigger both push and pull-request package validation.'
Assert-Equal ([regex]::Matches($workflowText, '(?m)^\s+- src/mod_maer_portal\.erl$').Count) 2 'Portal source changes must trigger both push and pull-request package validation.'
Assert-Equal ([regex]::Matches($workflowText, '(?m)^\s+- src/maer_portal_smtp\.erl$').Count) 2 'Portal SMTP source changes must trigger both push and pull-request package validation.'
Assert-True ($controlConfigText -match '(?m)^ERL_DIST_PORT=5211$') 'Fixed Erlang distribution port is missing.'
Assert-True ($controlConfigText -match '(?m)^INET_DIST_INTERFACE=127\.0\.0\.1$') 'Erlang distribution must bind to loopback.'

$runtimeFiles = @($configPath, $controlConfigPath, $serviceSetupPath, $serviceScriptPath, $uploadMonitorPath)
$runtimePayload = ($runtimeFiles | ForEach-Object { Read-TextNormalized $_ }) -join "`n"
$forbiddenMarkers = '(?i)CHANGE[_-]?ME|TODO|@@[^@]+@@|\{\{[^}]+\}\}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
Assert-True (-not ($runtimePayload -match $forbiddenMarkers)) 'Runtime payload contains a placeholder or private key marker.'
Assert-True (-not ($runtimePayload -match '(?im)^\s*(password|secret|external_secret)\s*:')) 'Runtime profile contains a secret-bearing YAML key.'
Assert-True ($serviceScriptText.StartsWith("#!/bin/sh`n")) 'start-stop-status must use /bin/sh with LF endings.'
Assert-True ($serviceScriptText -match '(?m)^set -eu$') 'start-stop-status must enable fail-fast shell behavior.'
Assert-True ($serviceScriptText -match 'for service_port in 5080 5211 5222 5280 5443') 'Port collision gate is incomplete.'
Assert-True ($serviceScriptText -match 'cannot inspect TCP listeners; refusing to start') 'Port inspection must fail closed.'
Assert-True ($serviceScriptText -match '^check_config\(\)' -or $serviceScriptText -match '(?m)^check_config\(\)$') 'Configuration check function is missing.'
Assert-True ($serviceScriptText -match 'application:ensure_all_started\(xmpp\)') 'Configuration validation must start xmpp so the JID NIF is loaded.'
$serviceSetupText = [System.IO.File]::ReadAllText((Join-Path $overlayRoot 'spk\maerxmppserver\src\service-setup.sh'))
Assert-True ($serviceSetupText -match '(?m)^HOME="\$\{MAER_PACKAGE_ROOT\}/home"$') 'Service setup must provide the DSM package home for Erlang auth.'
Assert-True ($serviceSetupText -match '(?m)^export HOME$') 'Service setup must export HOME for Erlang child processes.'
Assert-True ($serviceScriptText -match 'ejabberd_config:load\(\)') 'Configuration check must parse the real ejabberd profile.'
Assert-True ($serviceScriptText -match 'TLS certificate permissions must be 0640') 'TLS key permission gate must require exactly 0640.'
Assert-True ($serviceScriptText -match 'MAER_CERTIFICATE_OWNER:-root:sc-maerxmppserver') 'TLS key ownership gate must require root and the isolated service group.'
Assert-True (-not ($serviceScriptText -match 'kill\s+-9|rm\s+-r[fF]|(?m)^\s*(synopkg|sudo)\b')) 'Service script contains a destructive or privileged fallback.'
Assert-True ($serviceScriptText -match 'kill -0') 'Service status must verify the PID without signaling it.'
Assert-True ($serviceSetupText -match 'chmod 700') 'Runtime directories are not restricted to mode 0700.'
Assert-True ($serviceSetupText -match 'chmod 600') 'Runtime configuration files are not restricted to mode 0600.'
Assert-True ($serviceSetupText -match '(?m)^validate_preupgrade\(\)$') 'Package must define an upgrade validation hook.'
Assert-True ($serviceSetupText -match 'only supports an in-place upgrade from 26\.07\.0-8') 'Upgrade must be restricted to the validated revision-8 source.'
Assert-True ($serviceSetupText -match 'requires an empty package data directory') 'Clean install must reject retained package state.'
Assert-True (-not ($serviceSetupText -match '(?ms)^service_postupgrade\(\).*?install_runtime_defaults')) 'Upgrade hook must never preserve an older runtime profile.'
Assert-True ($serviceSetupText -match '(?ms)^service_postupgrade\(\).*?backup_upgrade_configuration.*?replace_default_file ejabberd\.yml') 'Revision-8 configuration must be backed up before the canonical revision-9 profile is installed.'
Assert-True (-not ($serviceSetupText -match '(?m)^\s*rm\s+-r')) 'Installer setup must not recursively remove existing state.'
Assert-True ($serviceSetupText -match 'temporary_file="\$\{target_file\}\.maer-upgrade\.\$\$"') 'Upgrade replacement must use a bounded temporary configuration path.'
Assert-True ($serviceSetupText -match 'mv "\$\{temporary_file\}" "\$\{target_file\}"') 'Upgrade replacement must atomically install the canonical profile.'
Assert-True ($serviceSetupText -match '(?m)^install_smtp_password\(\)$') 'Installer must provision the SMTP secret through a dedicated routine.'
Assert-True ($serviceSetupText -match '(?m)^validate_smtp_password_input\(\)$') 'Installer must validate SMTP input before changing package state.'
Assert-True ($serviceSetupText -match '(?ms)^validate_preinst\(\).*?validate_smtp_password_input \|\| exit 1') 'Clean-install preflight must reject missing or invalid SMTP input.'
Assert-True ($serviceSetupText -match '(?ms)^validate_preupgrade\(\).*?validate_smtp_password_input \|\| exit 1') 'Upgrade preflight must reject missing or invalid SMTP input before migration.'
Assert-True ($serviceSetupText -match 'secret_file="\$\{CONFIG_DIR\}/smtp-password"') 'SMTP secret must be written only below the package configuration directory.'
Assert-True ($serviceSetupText -match 'chmod 600 "\$\{temporary_file\}"') 'SMTP secret must be staged with mode 0600.'
Assert-True (-not ($serviceSetupText -match '(?m)^\s*(echo|printf).*wizard_smtp_password')) 'Installer must never print the SMTP password.'
Assert-True ($serviceSetupText -match '(?ms)^service_postinst\(\).*?install_runtime_defaults \|\| exit 1.*?install_smtp_password \|\| exit 1') 'DSM post-install hook must fail closed when runtime or SMTP provisioning fails.'
Assert-True ($serviceSetupText -match '(?ms)^service_postupgrade\(\).*?replace_default_file ejabberd\.yml \|\| exit 1.*?install_smtp_password \|\| exit 1') 'DSM post-upgrade hook must fail closed when migration or SMTP provisioning fails.'
$null = $installWizardText | ConvertFrom-Json
$null = $upgradeWizardText | ConvertFrom-Json
foreach ($wizardText in @($installWizardText, $upgradeWizardText)) {
    Assert-True ($wizardText.Contains('"key": "wizard_smtp_password"')) 'DSM wizard must use the service-setup SMTP password variable.'
    Assert-True ($wizardText.Contains('"allowBlank": false')) 'DSM wizard must refuse an empty SMTP password.'
    Assert-True ($wizardText.Contains('"minLength": 12')) 'DSM wizard must enforce the reviewed minimum SMTP password length.'
    Assert-True ($wizardText.Contains('"maxLength": 4094')) 'DSM wizard must enforce the SMTP transport maximum password length.'
    Assert-True ($wizardText.Contains('no-reply@maer.fr')) 'DSM wizard must identify the exact portal sender account.'
    Assert-True ($wizardText.Contains('mode 0600')) 'DSM wizard must explain how the SMTP secret is protected.'
}
Assert-True (-not ($serviceSetupText -match '(?m)^\s*HOME=(?!"\$\{MAER_PACKAGE_ROOT\}/home"$)')) 'Service setup must not direct Erlang HOME outside the DSM package home.'

Assert-True ($uploadMonitorText -match 'MAER_UPLOAD_FS_WARN_PERCENT:-80') 'Global upload monitor warning threshold must default to 80 percent.'
Assert-True ($uploadMonitorText -match 'MAER_UPLOAD_FS_CRITICAL_PERCENT:-90') 'Global upload monitor critical threshold must default to 90 percent.'
Assert-True (-not ($uploadMonitorText -match '(?m)^\s*(rm|mv)\s')) 'Global upload monitor must remain read-only.'
$certificateSyncText = Read-TextNormalized $certificateSyncPath
Assert-True ($certificateSyncText.Contains('-checkend 604800')) 'Certificate sync must require at least seven days of validity.'
Assert-True ($certificateSyncText.Contains('selected_expiry')) 'Certificate sync must deterministically select the latest valid candidate.'
Assert-True ($certificateSyncText.Contains('cmp -s')) 'Certificate sync must avoid needless service restarts.'
Assert-True ($certificateSyncText.Contains('root:sc-maerxmppserver')) 'Certificate directory must use the isolated service group.'
Assert-True ($certificateSyncText.Contains('certificate root permissions must be exactly 0755')) 'Shared certificate root must be exactly root:root 0755.'
Assert-True ($certificateSyncText.Contains('previous PEM restored')) 'Certificate sync must restore and verify recovery after a failed restart.'
$certificateInstallerText = Read-TextNormalized $certificateInstallerPath
Assert-True ($certificateInstallerText.Contains('50fa7ef143e4b97f7ec528fec03a33b5f690a522c0b49f0c46e2c7540b7afc93')) 'Root helper installer must pin the exact reviewed helper SHA-256.'
Assert-True ($certificateInstallerText.Contains('/usr/local/libexec/maerxmppserver')) 'Root helper must install outside package-owned FHS paths.'
Assert-True ($certificateInstallerText.Contains('trap cleanup EXIT') -and $certificateInstallerText.Contains('exit 129') -and $certificateInstallerText.Contains('exit 130') -and $certificateInstallerText.Contains('exit 143')) 'Certificate installer signal traps must terminate explicitly.'
$bootstrapAdminText = Read-TextNormalized $bootstrapAdminPath
$pairingSourceText = Read-TextNormalized (Join-Path $repositoryRoot 'src\mod_maer_pairing.erl')
$redirectSourceText = Read-TextNormalized (Join-Path $repositoryRoot 'src\mod_maer_redirect.erl')
$portalSourceText = Read-TextNormalized (Join-Path $repositoryRoot 'src\mod_maer_portal.erl')
$portalSmtpSourceText = Read-TextNormalized (Join-Path $repositoryRoot 'src\maer_portal_smtp.erl')
Assert-True ($redirectSourceText.Contains('{301,')) 'HTTP redirect handler must use an ejabberd-compatible permanent 301 response.'
Assert-True (-not $redirectSourceText.Contains('{308,')) 'HTTP redirect handler must not use unsupported status 308 with ejabberd 26.07.'
Assert-True ($redirectSourceText.Contains('https://xmpp.maer.fr/')) 'HTTP redirect handler must use the canonical HTTPS origin.'
Assert-True ($portalSourceText.Contains('-define(HOST, <<"xmpp.maer.fr">>).')) 'Portal authentication must remain fixed to the canonical XMPP host.'
Assert-True ($portalSourceText.Contains('; Secure; HttpOnly; SameSite=Strict')) 'Portal session and CSRF cookies must remain hardened.'
Assert-True ($portalSourceText.Contains('<<Base/binary, "/", Suffix/binary, "#", Token/binary>>')) 'Portal email tokens must remain outside HTTP request logs in URL fragments.'
Assert-True ($portalSmtpSourceText.Contains('{verify, verify_peer}')) 'Portal SMTP transport must verify its TLS peer.'
Assert-True ($portalSmtpSourceText.Contains('pkix_verify_hostname_match_fun(https)')) 'Portal SMTP transport must verify the server hostname.'
Assert-True ($portalSmtpSourceText.Contains('(Mode band 8#7777) =:= 8#600')) 'Portal SMTP secret must require exact POSIX mode 0600 while ignoring file-type bits.'
Assert-True (-not ($portalSmtpSourceText.Contains('(Mode band 8#027) =:= 0'))) 'Portal SMTP secret validation must reject group-readable mode 0640.'
foreach ($permissionTest in @(
    'password_file_mode_0600_is_accepted_test',
    'password_file_mode_0640_is_rejected_test',
    'password_file_mode_0644_is_rejected_test',
    'password_file_symlink_is_rejected_test'
)) {
    Assert-True ($portalSmtpSourceText.Contains($permissionTest)) "Portal SMTP permission test is missing: $permissionTest"
}
Assert-True (-not ($portalSourceText -match 'ejabberd_web_admin\s*:|-include\([^\n]*web_admin')) 'Portal must remain independent from the WebAdmin implementation.'
Assert-True ($pairingSourceText.Contains('xmpp:err_policy_violation()')) 'Pairing throttling must use policy-violation in the locked source.'
Assert-True ($pairingSourceText.Contains('xmpp:err_resource_constraint()')) 'The device cap must retain resource-constraint in the locked source.'
Assert-True ($pairingSourceText.Contains('iq_rate_limit_condition_test()')) 'The locked source must test the pairing throttling stanza condition.'
Assert-True ($pairingSourceText.Contains('iq_device_limit_condition_test()')) 'The locked source must test the device-cap stanza condition.'
Assert-True ($pairingSourceText.Contains('User = <<"admin">>')) 'Bootstrap transaction must create only the ACL-authorized admin localpart.'
Assert-True ($pairingSourceText.Contains('verify_existing_admin(User, Host, Password)')) 'Bootstrap transaction must safely reconcile an existing admin with the same password.'
Assert-True ($bootstrapAdminText.Contains('pong = net_adm:ping(N)')) 'Bootstrap must prove distribution connectivity before authentication RPCs.'
Assert-True ($bootstrapAdminText.Contains('ERL_EPMD_ADDRESS=127.0.0.1')) 'Bootstrap distribution must remain loopback-only.'
Assert-True ($bootstrapAdminText.Contains('-erl_epmd_port 5211 -start_epmd false -dist_listen false')) 'Bootstrap must use the fixed private distribution port without opening a listener.'
Assert-True ($bootstrapAdminText.Contains('ERL_CRASH_DUMP=/dev/null')) 'Bootstrap must suppress secret-bearing crash dumps.'
Assert-True ($bootstrapAdminText.Contains('R(mod_maer_pairing,operator_bootstrap_admin,[P])')) 'Bootstrap must use one remote server-side transaction.'
Assert-True (-not $bootstrapAdminText.Contains('false = R(ejabberd_auth,user_exists')) 'Bootstrap must remain idempotent after an ambiguous RPC result.'
Assert-True (-not $bootstrapAdminText.Contains('maer-cutover-')) 'Production bootstrap must not create disposable test accounts.'
Assert-True ($pairingSourceText.Contains('ejabberd_auth:remove_user(User, Host)')) 'Server-side bootstrap transaction must roll back failed validation.'
Assert-True ($pairingSourceText.Contains('element(5, T) =:= sha256')) 'Server-side bootstrap transaction must prove SCRAM-SHA-256 storage.'
$bootstrapInstallerText = Read-TextNormalized $bootstrapInstallerPath
Assert-True ($bootstrapInstallerText.Contains('8c4123bc819a998ec767ce80d449708ccbe486ce4a5822c028e2596ab4a5ee62')) 'Bootstrap installer must pin the exact reviewed helper SHA-256.'
Assert-True ($bootstrapInstallerText.Contains('/usr/local/libexec/maerxmppserver')) 'Bootstrap installer must place the reviewed tool outside package-owned FHS paths.'
Assert-True ($bootstrapInstallerText.Contains('trap cleanup EXIT') -and $bootstrapInstallerText.Contains('exit 129') -and $bootstrapInstallerText.Contains('exit 130') -and $bootstrapInstallerText.Contains('exit 143')) 'Bootstrap installer signal traps must terminate explicitly.'

foreach ($shellPath in @($serviceSetupPath, $serviceScriptPath, $uploadMonitorPath, $certificateSyncPath, $certificateInstallerPath, $bootstrapAdminPath, $bootstrapInstallerPath, $prepareShellPath, (Join-Path $testsRoot 'test-service-contract.sh'), (Join-Path $testsRoot 'test-upload-monitor.sh'), (Join-Path $testsRoot 'test-certificate-sync.sh'), (Join-Path $testsRoot 'test-bootstrap-admin.sh'))) {
    Assert-LfShellFile $shellPath
}

$shellCommand = Get-Command bash -ErrorAction SilentlyContinue
$shellExecutable = if ($shellCommand) { $shellCommand.Source } else { $null }
if (-not $shellExecutable) {
    foreach ($candidate in @(
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files\Git\usr\bin\bash.exe'
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $shellExecutable = $candidate
            break
        }
    }
}
if ($shellExecutable) {
    Push-Location $synologyRoot
    try {
        foreach ($relativeShellPath in @(
            'spksrc-overlay/spk/maerxmppserver/src/service-setup.sh',
            'spksrc-overlay/spk/maerxmppserver/src/service-start-stop.sh',
            'spksrc-overlay/spk/maerxmppserver/src/upload-usage-check.sh',
            'operator/maer-certificate-sync',
            'operator/install-certificate-sync-root',
            'operator/maer-bootstrap-admin',
            'operator/install-bootstrap-admin-root',
            'tests/test-service-contract.sh',
            'tests/test-upload-monitor.sh',
            'tests/test-certificate-sync.sh',
            'tests/test-bootstrap-admin.sh'
        )) {
            & $shellExecutable -n $relativeShellPath
            if ($LASTEXITCODE -ne 0) {
                Add-Failure "Shell syntax check failed: $relativeShellPath"
            }
        }
        & $shellExecutable 'tests/test-service-contract.sh'
        if ($LASTEXITCODE -ne 0) {
            Add-Failure 'Service behavior contract test failed.'
        }
        & $shellExecutable 'tests/test-upload-monitor.sh'
        if ($LASTEXITCODE -ne 0) {
            Add-Failure 'Global upload monitor behavior test failed.'
        }
        & $shellExecutable 'tests/test-certificate-sync.sh'
        if ($LASTEXITCODE -ne 0) {
            Add-Failure 'DSM certificate synchronization behavior test failed.'
        }
        & $shellExecutable 'tests/test-bootstrap-admin.sh'
        if ($LASTEXITCODE -ne 0) {
            Add-Failure 'Bootstrap admin contract test failed.'
        }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Warning 'bash is unavailable; shell syntax and behavior tests were skipped.'
}

& pwsh -NoProfile -File (Join-Path $testsRoot 'test-spk-path-resolution.ps1')
if ($LASTEXITCODE -ne 0) {
    Add-Failure 'SPK filesystem path normalization test failed.'
}

& pwsh -NoProfile -File (Join-Path $testsRoot 'test-server-patches.ps1')
if ($LASTEXITCODE -ne 0) {
    Add-Failure 'Server spksrc patch -p0 contract test failed.'
}

$isWindowsHost = ($env:OS -eq 'Windows_NT')
$wslCommand = if ($isWindowsHost) { Get-Command wsl.exe -ErrorAction SilentlyContinue } else { $null }
if ($isWindowsHost -and $wslCommand) {
    $wslDistributions = @(& $wslCommand.Source --list --quiet 2>$null) | ForEach-Object { $_.Trim([char]0).Trim() } | Where-Object { $_ }
    $hasRequiredWsl = $LASTEXITCODE -eq 0 -and $wslDistributions -contains 'Ubuntu-26.04'
    if ($hasRequiredWsl) {
        Push-Location $repositoryRoot
        try {
            foreach ($linuxTest in @('packaging/synology/tests/test-certificate-sync.sh', 'packaging/synology/tests/test-bootstrap-admin.sh')) {
                & $wslCommand.Source -d Ubuntu-26.04 -- /usr/bin/bash $linuxTest
                if ($LASTEXITCODE -ne 0) { Add-Failure "Required WSL release test failed: $linuxTest" }
            }
        }
        finally { Pop-Location }
    }
    elseif ($env:CI) {
        Write-Warning 'WSL Ubuntu-26.04 is unavailable on this Windows CI runner; native Linux matrix tests provide the required release coverage.'
    }
    else {
        Add-Failure 'WSL Ubuntu-26.04 is required for certificate/bootstrap release tests.'
    }
}
elseif ($isWindowsHost) {
    Add-Failure 'WSL Ubuntu-26.04 is required for certificate/bootstrap release tests.'
}
else {
    $uname = & uname -s 2>$null
    if ($LASTEXITCODE -ne 0 -or $uname -ne 'Linux') { Add-Failure 'Linux is required for native certificate/bootstrap release tests.' }
    else {
        foreach ($linuxTest in @('packaging/synology/tests/test-certificate-sync.sh', 'packaging/synology/tests/test-bootstrap-admin.sh')) {
            & /usr/bin/bash $linuxTest
            if ($LASTEXITCODE -ne 0) { Add-Failure "Required native Linux release test failed: $linuxTest" }
        }
    }
}
$bashCommand = Get-Command bash -ErrorAction SilentlyContinue
$bashExecutable = if ($bashCommand) { $bashCommand.Source } else { $null }
if (-not $bashExecutable) {
    foreach ($candidate in @(
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files\Git\usr\bin\bash.exe'
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $bashExecutable = $candidate
            break
        }
    }
}
if ($bashExecutable) {
    Push-Location $synologyRoot
    try {
        & $bashExecutable -n 'prepare-overlay.sh'
        if ($LASTEXITCODE -ne 0) {
            Add-Failure 'Bash syntax check failed: prepare-overlay.sh'
        }
        & $bashExecutable 'prepare-overlay.sh' --help | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Add-Failure 'prepare-overlay.sh --help failed.'
        }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Warning 'bash is unavailable; prepare-overlay.sh syntax check was skipped.'
}

if ($SpkPath) {
    Validate-BuiltSpk -PackagePath $SpkPath -Expected $expected
}

if ($script:Failures.Count -ne 0) {
    Write-Host "Synology packaging validation failed ($($script:Failures.Count) issue(s)):" -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host 'Synology packaging source validation passed.' -ForegroundColor Green
if (-not $SpkPath) {
    Write-Host 'No SPK was built or inspected; pass -SpkPath after the separate build phase.'
}
