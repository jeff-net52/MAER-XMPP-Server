# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failures = [System.Collections.Generic.List[string]]::new()
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path

function Read-Normalized([string]$RelativePath) {
    $path = Join-Path $repositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing portal file: $RelativePath")
        return ''
    }
    return [System.IO.File]::ReadAllText($path).Replace("`r`n", "`n").Replace("`r", "`n")
}

function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $failures.Add($Message) }
}

$portal = Read-Normalized 'src\mod_maer_portal.erl'
$smtp = Read-Normalized 'src\maer_portal_smtp.erl'
$javascript = Read-Normalized 'priv\maer_portal\portal.js'
$stylesheet = Read-Normalized 'priv\maer_portal\portal.css'
$uploadModule = Read-Normalized 'src\mod_http_upload.erl'
$config = Read-Normalized 'packaging\synology\spksrc-overlay\spk\maerxmppserver\src\defaults\ejabberd.yml'
$spkMakefile = Read-Normalized 'packaging\synology\spksrc-overlay\spk\maerxmppserver\Makefile'
$serverPatch = Read-Normalized 'packaging\synology\spksrc-overlay\cross\maerxmppserver\patches\003-maer-user-portal.patch'
$publication = Read-Normalized 'packaging\synology\PUBLICATION-PREFLIGHT.md'

Require ($portal.Contains('-define(HOST, <<"xmpp.maer.fr">>).')) 'Portal host is not fixed to xmpp.maer.fr.'
Require ($portal.Contains('^[a-z0-9][a-z0-9._-]{0,63}$')) 'Short-identifier validation is missing.'
Require ($portal.Contains('ejabberd_auth:check_password(User, <<>>, ?HOST, Password)')) 'Portal login does not use ejabberd authentication on the canonical host.'
Require ($portal.Contains('ejabberd_auth:set_password(User, ?HOST, Password)')) 'Confirmed password change does not use ejabberd authentication.'
Require (-not ($portal -match 'ejabberd_web_admin\s*:|-include\([^\n]*web_admin')) 'Portal is coupled to ejabberd_web_admin.'
Require ($portal.Contains('maer-portal.sqlite')) 'Dedicated portal SQLite database is missing.'
Require ($portal.Contains('token_hash BLOB PRIMARY KEY')) 'Persistent confirmation tokens are not stored as hashes.'
Require (-not ($portal -match '(?i)INSERT[^\n]+password|UPDATE[^\n]+password')) 'Portal attempts to persist a password.'
Require ($portal.Contains('; Secure; HttpOnly; SameSite=Strict')) 'Session/CSRF cookies are not hardened.'
Require ($portal.Contains('header(Headers, <<"origin">>) =:= <<"https://xmpp.maer.fr">>')) 'Canonical Origin enforcement is missing.'
Require ($portal.Contains('crypto:hash_equals')) 'Constant-time token comparison is missing.'
Require ($portal.Contains('allow_rate({login, IP, User}')) 'Per-IP/account login throttling is missing.'
Require ($portal.Contains('<<Base/binary, "/", Suffix/binary, "#", Token/binary>>')) 'Email bearer token is not kept in the URL fragment.'
Require (-not ($portal -match 'Suffix/binary, "\?')) 'Email bearer token may leak through a query string.'
Require ($javascript.Contains('history.replaceState(null, "", window.location.pathname)')) 'Browser does not erase the token fragment after reading it.'
Require ($portal.Contains("default-src 'none'; img-src 'self'; style-src 'self';")) 'Portal CSP is incomplete.'
Require (-not ($config.Contains('Content-Security-Policy:'))) 'A listener-wide CSP would override HTTP Upload sandboxing.'
$uploadSandboxCsp = '<<"Content-Security-Policy">>, <<"sandbox; default-src ''none''">>'
Require ($uploadModule.Contains($uploadSandboxCsp)) 'HTTP Upload must retain its route-specific sandbox CSP.'
Require ($portal.Contains('camera=(), microphone=(), display-capture=()')) 'Portal browser permissions policy is missing.'

foreach ($feature in @('Appels audio', 'Appels vidéo', "Partage d’écran", 'MAER Assistance', 'Gestionnaire de mots de passe')) {
    Require ($portal.Contains($feature)) "Portal preference is missing: $feature"
}
Require ($portal.Contains("Aucune facturation n’est activée")) 'No-billing status is not explicit in the portal.'
Require ($stylesheet.Contains('--maer: #49cbc1')) 'MAER visual theme is missing.'
Require ($portal.Contains('/account/assets/logo.png')) 'Existing MAER logo is not used by the portal.'

Require ($smtp.Contains('{verify, verify_peer}')) 'SMTP TLS peer verification is missing.'
Require ($smtp.Contains('pkix_verify_hostname_match_fun(https)')) 'SMTP hostname verification is missing.'
Require ($smtp.Contains("{versions, ['tlsv1.2', 'tlsv1.3']}")) 'SMTP permits an obsolete TLS protocol.'
Require ($smtp.Contains('(Mode band 8#7777) =:= 8#600')) 'SMTP password-file permissions are not restricted to exact POSIX mode 0600.'
Require (-not ($smtp.Contains('(Mode band 8#027) =:= 0'))) 'SMTP password-file validation still permits group-readable mode 0640.'
foreach ($permissionTest in @(
    'password_file_mode_0600_is_accepted_test',
    'password_file_mode_0640_is_rejected_test',
    'password_file_mode_0644_is_rejected_test',
    'password_file_symlink_is_rejected_test'
)) {
    Require ($smtp.Contains($permissionTest)) "SMTP password-file permission test is missing: $permissionTest"
}
Require (-not ($smtp -match '(?i)logger|error_logger|io:format')) 'SMTP transport may log credentials or message tokens.'

Require ($config -match '(?m)^\s+/account: mod_maer_portal$') 'Portal is not mounted on the public TLS listener.'
Require ($config -match '(?m)^\s+mod_maer_portal:$') 'Portal module is not enabled.'
Require ($config -match '(?m)^\s+smtp_host: smtp-zose\.yulpa\.io$') 'Reviewed Yulpa implicit-TLS SMTP host is missing.'
Require ($config -match '(?m)^\s+smtp_port: 465$') 'SMTP must use implicit TLS on port 465.'
Require ($config -match '(?m)^\s+smtp_username: no-reply@maer\.fr$') 'Reviewed non-secret SMTP username is missing.'
Require ($config -match '(?m)^\s+smtp_password_file: /var/packages/maerxmppserver/var/config/smtp-password$') 'SMTP password must come from the server-side file.'
Require ($config -match '(?m)^\s+smtp_from: no-reply@maer\.fr$') 'Reviewed SMTP envelope and message sender is missing.'
Require ($smtp.Contains('password_file_available(PasswordFile)')) 'SMTP readiness does not fail closed when the password file is absent.'
Require ($config -match '(?m)^websocket_origin:\n  - https://xmpp\.maer\.fr\n  - maer-chat://app$') 'WebSocket origins must allow only the web origin and privileged Electron scheme.'
Require (-not ($config.Contains('file://'))) 'The unsafe Electron file origin must never be allowed.'
Require ([regex]::Matches($config, '(?m)^\s+Access-Control-Allow-Origin: maer-chat://app$').Count -eq 2) 'BOSH/pairing listener and HTTP Upload must allow the privileged Electron origin.'
Require ($portal.Contains('header(Headers, <<"origin">>) =:= <<"https://xmpp.maer.fr">>')) 'Portal mutations must remain restricted to the same-origin web UI.'
Require ($config -match '(?ms)^  maer_fail2ban_exempt:\n    ip:\n      - 127\.0\.0\.0/8\n      - ::1/128\n      - 192\.168\.30\.0/24$') 'LAN/hairpin fail2ban exemption ACL is incomplete.'
Require ($config -match '(?ms)^  maer_fail2ban_whitelist:\n    allow: maer_fail2ban_exempt\n    deny: all$') 'Fail2ban whitelist rule has the wrong allow/deny direction.'
Require ($config -match '(?ms)^  mod_fail2ban:\n    access: maer_fail2ban_whitelist$') 'mod_fail2ban does not use the bounded whitelist.'
Require (-not ($config -match '(?ms)maer_fail2ban_exempt:.*?0\.0\.0\.0/0')) 'WAN addresses are accidentally exempt from fail2ban.'

foreach ($payload in @('mod_maer_portal.beam', 'maer_portal_smtp.beam', 'priv/maer_portal/portal.css', 'priv/maer_portal/portal.js')) {
    Require ($spkMakefile.Contains($payload)) "SPK payload assertion is missing: $payload"
}
foreach ($runtimeAssetInstall in @(
    'install -m 644 $(MAER_SERVER_SOURCE_DIR)/priv/maer_portal/portal.css $(MAER_PORTAL_RUNTIME_DIR)/portal.css',
    'install -m 644 $(MAER_SERVER_SOURCE_DIR)/priv/maer_portal/portal.js $(MAER_PORTAL_RUNTIME_DIR)/portal.js',
    'install -m 644 $(MAER_SERVER_SOURCE_DIR)/maer/assets/maer-mark.png $(MAER_WEBADMIN_IMAGE_RUNTIME_DIR)/admin-logo.png',
    'install -m 644 $(MAER_SERVER_SOURCE_DIR)/maer/assets/maer-mark.png $(MAER_WEBADMIN_IMAGE_RUNTIME_DIR)/favicon.png'
)) {
    Require ($spkMakefile.Contains($runtimeAssetInstall)) "SPK runtime asset install is missing or does not enforce mode 0644: $runtimeAssetInstall"
}
Require ($spkMakefile.Contains('cmp -s $(MAER_SERVER_SOURCE_DIR)/priv/maer_portal/portal.css $(MAER_PORTAL_RUNTIME_DIR)/portal.css')) 'SPK does not verify the installed portal stylesheet against its reviewed source.'
Require ($spkMakefile.Contains('cmp -s $(MAER_SERVER_SOURCE_DIR)/priv/maer_portal/portal.js $(MAER_PORTAL_RUNTIME_DIR)/portal.js')) 'SPK does not verify the installed portal script against its reviewed source.'
foreach ($patchedPath in @('src/mod_maer_portal.erl', 'src/maer_portal_smtp.erl', 'priv/maer_portal/portal.css', 'priv/maer_portal/portal.js')) {
    Require ($serverPatch.Contains("+++ $patchedPath")) "Locked source patch does not add $patchedPath with the spksrc patch -p0 path"
}
Require ($publication -match '(?m)^- `/account`\.$') 'DSM reverse-proxy allowlist does not publish /account.'
Require ($publication -match '(?s)ceux de\s+`/account` à 8 Kio') 'DSM proxy body limit for the portal is undocumented.'

if ($failures.Count -gt 0) {
    Write-Host "MAER portal contract failed ($($failures.Count) issue(s)):" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'MAER portal source and packaging contract passed.' -ForegroundColor Green
