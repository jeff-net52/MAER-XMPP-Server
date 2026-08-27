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
$synologyRoot = (Resolve-Path -LiteralPath (Join-Path $testsRoot '..')).Path
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $synologyRoot '..\..')).Path
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

    $resolvedPackage = (Resolve-Path -LiteralPath $PackagePath).Path
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
        Assert-True (Test-Path -LiteralPath $infoPath -PathType Leaf) 'Built SPK has no INFO file.'
        Assert-True (Test-Path -LiteralPath $privilegePath -PathType Leaf) 'Built SPK has no conf/privilege file.'

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
            Assert-True ([bool]$startStopLine) 'SPK listing has no start-stop-status script.'
            Assert-True ([bool]$setupLine) 'SPK listing has no service-setup script.'
            Assert-True ([bool]$privilegeLine) 'SPK listing has no privilege file.'
            if ($startStopLine) { Assert-True ($startStopLine -match '^-rwxr-xr-x\s') 'start-stop-status mode must be 0755.' }
            if ($setupLine) { Assert-True ($setupLine -match '^-rwxr-xr-x\s') 'service-setup mode must be 0755.' }
            if ($privilegeLine) { Assert-True ($privilegeLine -match '^-rw-r--r--\s') 'conf/privilege mode must be 0644.' }
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
                'lib/libcrypto.so.3',
                'lib/libssl.so.3',
                'lib/libsqlite3.so.0.8.6',
                'lib/libncursesw.so.6.6',
                'lib/libatomic.so.1.2.0',
                'lib/ejabberd-26.07/ebin/mod_maer_pairing.beam',
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
                'share/maerxmppserver/licenses/libatomic-GCC-8.5.0-SOURCE.txt'
            )) {
                Assert-True ($normalizedPayloadListing -contains $payloadFile) "SPK payload is missing $payloadFile"
            }

            $forbiddenPayloadPaths = @($normalizedPayloadListing | Where-Object {
                $_ -match '(?:^|/)(?:src|c_src|examples|doc|man|include|proper_ext|emacs)(?:/|$)' -or
                $_ -match '\.orig$' -or
                $_ -match '\.(?:a|la|key)$' -or
                $_ -match '\.(?:erl|hrl|c|h|o|src)$' -or
                $_ -match '(?:^|/)(?:README|HOWTO)[^/]*$' -or
                $_ -match '(?i)(?:^|/)[^/]*example[^/]*$' -or
                ($_ -match '\.pem$' -and $_ -notmatch '^lib/pkix-[^/]+/priv/cacert\.pem$') -or
                $_ -match '^etc(?:/|$)' -or
                $_ -match '^share/(?:terminfo|tabset)(?:/|$)' -or
                $_ -match '^lib/erlang/lib/(?:common_test|dialyzer|edoc|erl_interface|eunit)-[^/]+(?:/|$)' -or
                $_ -match '^lib/erlang/(?:Install|bin/(?:start|start_erl)|releases/start_erl\.data)$' -or
                $_ -match '^lib/erlang/erts-[^/]+/bin/start$' -or
                $_ -match '^lib/lib(?:formw|menuw|panelw)\.so' -or
                $_ -match '^bin/(?:clear|infocmp|tabs|tic|toe|tput|tset|reset|captoinfo|infotocap|openssl|sqlite3|ct_run|dialyzer|erlc|escript|run_erl|to_erl|typer)$' -or
                $_ -match '^lib/erlang/lib/(?:diameter|snmp)-[^/]+/bin/(?:diameterc|snmpc)$' -or
                $_ -match '(?:^|/)otp_test_engine\.so$' -or
                $_ -match '(?:^|/)crypto_callback\.so$'
            })
            Assert-True ($forbiddenPayloadPaths.Count -eq 0) ('SPK payload contains runtime-inutile or secret-bearing paths: ' + (($forbiddenPayloadPaths | Select-Object -First 8) -join ', '))
            $publicPemPaths = @($normalizedPayloadListing | Where-Object { $_ -match '\.pem$' })
            Assert-True ($publicPemPaths.Count -eq 1 -and $publicPemPaths[0] -match '^lib/pkix-[^/]+/priv/cacert\.pem$') 'SPK payload must contain exactly the allowlisted PKIX public CA PEM.'

            $payloadModeListing = @(& tar -tvzf $packageArchive)
            if ($LASTEXITCODE -ne 0) {
                Add-Failure 'Unable to inspect package.tgz modes.'
            }
            else {
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
    'spksrc-overlay\spk\maerxmppserver\Makefile',
    'spksrc-overlay\spk\maerxmppserver\src\COPYING',
    'spksrc-overlay\spk\maerxmppserver\src\libatomic-GCC-8.5.0-SOURCE.txt',
    'spksrc-overlay\spk\maerxmppserver\src\maerxmppserver.png',
    'spksrc-overlay\spk\maerxmppserver\src\service-setup.sh',
    'spksrc-overlay\spk\maerxmppserver\src\service-start-stop.sh',
    'spksrc-overlay\spk\maerxmppserver\src\maerxmppserver.sc',
    'spksrc-overlay\spk\maerxmppserver\src\defaults\ejabberd.yml',
    'spksrc-overlay\spk\maerxmppserver\src\defaults\ejabberdctl.cfg',
    'spksrc-overlay\spk\maerxmppserver\src\defaults\inetrc',
    'tests\expected-info.json',
    'tests\test-service-contract.sh'
)
foreach ($relativeFile in $requiredFiles) {
    Assert-True (Test-Path -LiteralPath (Join-Path $synologyRoot $relativeFile) -PathType Leaf) "Required file is missing: $relativeFile"
}

$expected = Get-Content -LiteralPath (Join-Path $testsRoot 'expected-info.json') -Raw | ConvertFrom-Json
$locks = Get-Content -LiteralPath (Join-Path $synologyRoot 'LOCKS.json') -Raw | ConvertFrom-Json

$spkMakefilePath = Join-Path $overlayRoot 'spk\maerxmppserver\Makefile'
$spkMakefile = Get-Content -LiteralPath $spkMakefilePath -Raw
Assert-Equal (Get-MakeValue $spkMakefile 'SPK_NAME') $expected.package 'SPK package identifier mismatch.'
Assert-Equal ((Get-MakeValue $spkMakefile 'SPK_VERS') + '-' + (Get-MakeValue $spkMakefile 'SPK_REV')) $expected.version 'SPK version mismatch.'
Assert-Equal (Get-MakeValue $spkMakefile 'DISPLAY_NAME') $expected.displayname 'SPK display name mismatch.'
Assert-True ($spkMakefile -match '(?m)^override DISTRIBUTOR = MAER$') 'SPK distributor must override an empty repository-wide local.mk value.'
Assert-True ($spkMakefile -match '(?m)^override DISTRIBUTOR_URL = https://github\.com/jeff-net52/MAER-XMPP-Server$') 'SPK distributor URL must override an empty repository-wide local.mk value.'
Assert-Equal (Get-MakeValue $spkMakefile 'OS_MIN_VER') $expected.os_min_ver 'SPK minimum DSM mismatch.'
Assert-Equal (Get-MakeValue $spkMakefile 'REQUIRED_MIN_DSM') '7.1' 'Armada38x must build with the latest available DSM 7.1 SDK.'
Assert-Equal (Get-MakeValue $spkMakefile 'SERVICE_USER') 'auto' 'DSM service user must be generated by spksrc.'
Assert-Equal (Get-MakeValue $spkMakefile 'STARTABLE') 'yes' 'SPK must remain startable.'
Assert-Equal (Get-MakeValue $spkMakefile 'UNSUPPORTED_ARCHS') '$(filter-out armada38x,$(ALL_ARCHS))' 'SPK architecture gate mismatch.'
Assert-True ($spkMakefile -match '(?m)^\s*chmod 755 \$\(STAGING_DIR\)/bin/ejabberdctl$') 'Packaged ejabberdctl must be executable by the DSM service user.'
Assert-Equal (Get-MakeValue $spkMakefile 'POST_STRIP_TARGET') 'maerxmppserver_runtime_finalize' 'Runtime hardening must run after the standard strip phase.'
Assert-Equal (Get-MakeValue $spkMakefile 'POST_SERVICE_TARGET') 'maerxmppserver_service_finalize' 'DSM service script modes must be finalized before outer packaging.'
Assert-Equal (Get-MakeValue $spkMakefile 'RUNTIME_RPATH') '/var/packages/maerxmppserver/target/lib' 'Runtime RPATH must use only the canonical package library path.'
Assert-True ($spkMakefile -match 'beam_lib:strip_files\(Files\)') 'Runtime finalization must strip reproducibility metadata from every BEAM file.'
Assert-True ($spkMakefile -match 'patchelf --force-rpath --set-rpath "\$\(RUNTIME_RPATH\)"') 'Runtime finalization must canonicalize every dynamic ELF RPATH.'
Assert-Equal (Get-MakeValue $spkMakefile 'OTP_DEVELOPMENT_APPLICATIONS') 'common_test dialyzer edoc erl_interface eunit' 'Runtime pruning must remove the deterministic OTP development-application allowlist.'
Assert-True ($spkMakefile -match "find \$\(STAGING_DIR\) -type f -name '\*\.orig' -delete") 'Runtime finalization must delete backup .orig files.'
Assert-True ($spkMakefile -match "-name '\*\.key'") 'Runtime finalization must reject private-key files.'
Assert-True ($spkMakefile -match [regex]::Escape('lib/pkix-*/priv/cacert.pem')) 'Runtime finalization must allowlist only the PKIX public CA PEM.'
Assert-True ($spkMakefile -match [regex]::Escape('-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----')) 'Runtime finalization must reject embedded private-key PEM blocks.'
Assert-True ($spkMakefile -match 'share/maerxmppserver/licenses') 'Runtime finalization must install third-party license notices.'
Assert-True ($spkMakefile -match [regex]::Escape('share/licenses/gcc/COPYING3')) 'Runtime finalization must install the GPLv3 text for libatomic.'
Assert-True ($spkMakefile -match [regex]::Escape('libatomic-GCC-8.5.0-SOURCE.txt')) 'Runtime finalization must install the libatomic source notice.'
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
Assert-Equal $expected.groupname 'synocommunity' 'Expected DSM group must match spksrc DSM 7 defaults.'

Assert-Equal $locks.package.name $expected.package 'LOCKS package name mismatch.'
Assert-Equal $locks.package.display_name $expected.displayname 'LOCKS display name mismatch.'
Assert-Equal $locks.package.version $expected.version 'LOCKS package version mismatch.'
Assert-Equal $locks.package.arch $expected.arch 'LOCKS architecture mismatch.'
Assert-Equal $locks.package.os_min_ver $expected.os_min_ver 'LOCKS DSM version mismatch.'
Assert-Equal $locks.spksrc.commit '954871e356f7f990c179eb58af11c20d82872d8f' 'spksrc commit lock mismatch.'
Assert-Equal $locks.toolchain.target 'armada38x-7.1' 'Toolchain target lock mismatch.'
Assert-Equal $locks.toolchain.triplet 'arm-unknown-linux-gnueabi' 'Toolchain triplet lock mismatch.'
Assert-True ([bool]$locks.toolchain.hard_float) 'Toolchain must remain hard-float.'
Assert-Equal $locks.maer_xmpp_server.commit '444c56576df676b37437c3de490cd904d7bca840' 'MAER public source commit lock mismatch.'
Assert-Equal $locks.maer_xmpp_server.archive 'https://github.com/jeff-net52/MAER-XMPP-Server/archive/444c56576df676b37437c3de490cd904d7bca840.tar.gz' 'MAER public source archive URL mismatch.'
Assert-Equal $locks.maer_xmpp_server.bytes 3113176 'MAER public source archive size mismatch.'
Assert-True (-not ($locks.maer_xmpp_server.PSObject.Properties.Name -contains 'tag')) 'MAER source lock must not depend on a tag.'

$nativeOtpMakefile = Get-Content -LiteralPath (Join-Path $overlayRoot 'native\erlang-maer\Makefile') -Raw
$crossOtpMakefile = Get-Content -LiteralPath (Join-Path $overlayRoot 'cross\erlang-maer\Makefile') -Raw
$crossOtpNcursesPatch = Get-Content -LiteralPath (Join-Path $overlayRoot 'cross\erlang-maer\patches\000-configure-add-ncursesw-to-termcap-libraries.patch') -Raw
$crossOtpOpenSslPatch = Get-Content -LiteralPath (Join-Path $overlayRoot 'cross\erlang-maer\patches\001-fix-openssl-include-order.patch') -Raw
$crossOtpBuildFlagsPatch = Get-Content -LiteralPath (Join-Path $overlayRoot 'cross\erlang-maer\patches\002-sanitize-erts-build-flags.patch') -Raw
$opensslMakefile = Get-Content -LiteralPath (Join-Path $overlayRoot 'cross\openssl3-maer\Makefile') -Raw
$opensslBuildInfoPatch = Get-Content -LiteralPath (Join-Path $overlayRoot 'cross\openssl3-maer\patches\001-sanitize-build-information.patch') -Raw
$serverMakefile = Get-Content -LiteralPath (Join-Path $overlayRoot 'cross\maerxmppserver\Makefile') -Raw
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
Assert-Equal (Get-MakeValue $crossOtpMakefile 'NATIVE_ERLANG_BIN_DIR') '$(abspath $(WORK_DIR)/../../../native/erlang-maer/work-native/install/usr/local/bin)' 'Cross OTP native Erlang path must not depend on prior filesystem existence.'
Assert-Equal (Get-MakeValue $crossOtpMakefile 'ENV') 'PATH=$(NATIVE_ERLANG_BIN_DIR):$$PATH' 'Pinned native OTP must take precedence over the system Erlang runtime.'
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
    $digestText = Get-Content -LiteralPath $digestPath -Raw
    Assert-True ($digestText -match [regex]::Escape("SHA256 $($locks.erlang_otp.sha256)")) "OTP SHA256 missing from $digestPath"
    Assert-True ($digestText -match [regex]::Escape("SHA1 $($locks.erlang_otp.sha1)")) "OTP SHA1 missing from $digestPath"
    Assert-True ($digestText -match [regex]::Escape("MD5 $($locks.erlang_otp.md5)")) "OTP MD5 missing from $digestPath"
}
$serverDigestText = Get-Content -LiteralPath (Join-Path $overlayRoot 'cross\maerxmppserver\digests') -Raw
$serverDigestName = "maer-xmpp-server-$($locks.maer_xmpp_server.commit).tar.gz"
Assert-True ($serverDigestText -match ('(?m)^' + [regex]::Escape($serverDigestName) + '\s+SHA256\s+')) 'MAER digest filename does not derive from the locked commit.'
Assert-True ($serverDigestText -match [regex]::Escape("SHA256 $($locks.maer_xmpp_server.sha256)")) 'MAER source SHA256 missing from digests.'
Assert-True ($serverDigestText -match [regex]::Escape("SHA1 $($locks.maer_xmpp_server.sha1)")) 'MAER source SHA1 missing from digests.'
Assert-True ($serverDigestText -match [regex]::Escape("MD5 $($locks.maer_xmpp_server.md5)")) 'MAER source MD5 missing from digests.'
$opensslDigestText = Get-Content -LiteralPath (Join-Path $overlayRoot 'cross\openssl3-maer\digests') -Raw
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

$prepareScript = Get-Content -LiteralPath (Join-Path $synologyRoot 'prepare-overlay.ps1') -Raw
Assert-True ($prepareScript.Contains($locks.spksrc.commit)) 'Overlay preparation does not enforce the locked spksrc commit.'
Assert-True ($prepareScript -match 'status --porcelain') 'Overlay preparation must reject a dirty spksrc checkout.'
Assert-True ($prepareScript -match 'Refusing to overwrite') 'Overlay preparation must refuse existing target recipes.'
Assert-True ($prepareScript -match [regex]::Escape("'cross\openssl3-maer'")) 'PowerShell overlay preparation must install the reproducible OpenSSL recipe.'

$prepareShellPath = Join-Path $synologyRoot 'prepare-overlay.sh'
$prepareShellScript = Get-Content -LiteralPath $prepareShellPath -Raw
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
$configText = Get-Content -LiteralPath $configPath -Raw
$controlConfigText = Get-Content -LiteralPath $controlConfigPath -Raw
$serviceSetupText = Get-Content -LiteralPath $serviceSetupPath -Raw
$serviceScriptText = Get-Content -LiteralPath $serviceScriptPath -Raw

Assert-True ($configText -match '(?m)^hosts:\s*\r?\n\s+- xmpp\.maer\.fr$') 'Canonical XMPP host is missing.'
Assert-True ($configText -match '(?m)^\s+starttls_required: true$') 'Client TCP listener must require STARTTLS.'
Assert-True ($configText -match '(?m)^auth_stored_password_types:\s*\r?\n\s+- scram_sha256$') 'Profile must store only SCRAM-SHA-256 credentials.'
Assert-True ($configText -match '(?m)^sql_type: sqlite$') 'Profile must use SQLite.'
Assert-True ($configText -match '(?m)^\s+mod_mam:$') 'MAM module is missing.'
Assert-True ($configText -match '(?m)^\s+mod_muc:$') 'MUC module is missing.'
Assert-True ($configText -match '(?m)^\s+/maer-pairing: mod_maer_pairing$') 'MAER pairing must be exposed only by the configured HTTPS listener.'
Assert-True ($configText -match '(?m)^\s+mod_maer_pairing: \{\}$') 'MAER pairing module is missing.'
Assert-True ($configText -match '(?m)^\s+mod_pubsub:$') 'PubSub/PEP module is missing.'
Assert-True ($configText -match '(?m)^\s+mod_push:$') 'Push module is missing.'
Assert-True (-not ($configText -match '(?m)^\s+mod_register:')) 'Public in-band registration must remain disabled.'
Assert-True (-not ($configText -match '(?m)^\s+mod_http_api:')) 'HTTP administration API must remain disabled.'
Assert-True (-not ($configText -match '(?m)^\s+mod_stun_disco:')) 'TURN discovery must remain disabled until secret provisioning exists.'
Assert-True ($configText.Contains('/var/packages/maerxmppserver/var/certs/xmpp.pem')) 'Canonical certificate path is missing.'
Assert-True ($configText.Contains('/var/packages/maerxmppserver/var/data/ejabberd.sqlite')) 'Canonical SQLite path is missing.'
Assert-True ($controlConfigText -match '(?m)^ERL_DIST_PORT=5211$') 'Fixed Erlang distribution port is missing.'
Assert-True ($controlConfigText -match '(?m)^INET_DIST_INTERFACE=127\.0\.0\.1$') 'Erlang distribution must bind to loopback.'

$runtimeFiles = @($configPath, $controlConfigPath, $serviceSetupPath, $serviceScriptPath)
$runtimePayload = ($runtimeFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
$forbiddenMarkers = '(?i)CHANGE[_-]?ME|TODO|@@[^@]+@@|\{\{[^}]+\}\}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
Assert-True (-not ($runtimePayload -match $forbiddenMarkers)) 'Runtime payload contains a placeholder or private key marker.'
Assert-True (-not ($runtimePayload -match '(?im)^\s*(password|secret|external_secret)\s*:')) 'Runtime profile contains a secret-bearing YAML key.'
Assert-True ($serviceScriptText.StartsWith("#!/bin/sh`n")) 'start-stop-status must use /bin/sh with LF endings.'
Assert-True ($serviceScriptText -match '(?m)^set -eu$') 'start-stop-status must enable fail-fast shell behavior.'
Assert-True ($serviceScriptText -match 'for service_port in 5211 5222 5280 5443') 'Port collision gate is incomplete.'
Assert-True ($serviceScriptText -match 'cannot inspect TCP listeners; refusing to start') 'Port inspection must fail closed.'
Assert-True ($serviceScriptText -match '^check_config\(\)' -or $serviceScriptText -match '(?m)^check_config\(\)$') 'Configuration check function is missing.'
Assert-True ($serviceScriptText -match 'ejabberd_config:load\(\)') 'Configuration check must parse the real ejabberd profile.'
Assert-True ($serviceScriptText -match 'TLS certificate permissions must be 0400 or 0600') 'TLS key permission gate is missing.'
Assert-True (-not ($serviceScriptText -match 'kill\s+-9|rm\s+-r[fF]|(?m)^\s*(synopkg|sudo)\b')) 'Service script contains a destructive or privileged fallback.'
Assert-True ($serviceScriptText -match 'kill -0') 'Service status must verify the PID without signaling it.'
Assert-True ($serviceSetupText -match 'chmod 700') 'Runtime directories are not restricted to mode 0700.'
Assert-True ($serviceSetupText -match 'chmod 600') 'Runtime configuration files are not restricted to mode 0600.'
Assert-True (-not ($serviceSetupText -match '(?m)^\s*(rm|mv)\s')) 'Installer setup must not remove or replace existing state.'
Assert-True (-not ($serviceSetupText -match '(?m)^\s*(export\s+)?HOME=')) 'Service setup must leave HOME under DSM control.'

foreach ($shellPath in @($serviceSetupPath, $serviceScriptPath, $prepareShellPath, (Join-Path $testsRoot 'test-service-contract.sh'))) {
    Assert-LfShellFile $shellPath
}

$shellCommand = Get-Command sh -ErrorAction SilentlyContinue
$shellExecutable = if ($shellCommand) { $shellCommand.Source } else { $null }
if (-not $shellExecutable) {
    foreach ($candidate in @(
        'C:\Program Files\Git\bin\sh.exe',
        'C:\Program Files\Git\usr\bin\sh.exe'
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
            'tests/test-service-contract.sh'
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
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Warning 'sh is unavailable; shell syntax and behavior tests were skipped.'
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
