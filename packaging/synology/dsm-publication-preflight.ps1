# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string] $Domain = 'xmpp.maer.fr',

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string] $RetiredDomain,

    [ValidateRange(2, 60)]
    [int] $TimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([string] $Message)
    $script:Failures.Add($Message)
}

function Test-TcpPort {
    param([string] $HostName, [int] $Port)

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $client.ConnectAsync($HostName, $Port)
        if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            return $false
        }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Send-HttpRequest {
    param(
        [string] $Method,
        [string] $Url,
        [string] $Origin = "https://$Domain",
        [AllowNull()] [string] $Body = $null,
        [string] $ContentType = 'application/octet-stream'
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::new($Method), $Url)
        if ($Origin) {
            $request.Headers.TryAddWithoutValidation('Origin', $Origin) | Out-Null
        }
        if ($null -ne $Body) {
            $request.Content = [System.Net.Http.StringContent]::new(
                $Body,
                [System.Text.Encoding]::UTF8,
                $ContentType)
        }
        return $client.Send($request)
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-HeaderValue {
    param($Response, [string] $Name)

    $values = [System.Collections.Generic.IEnumerable[string]] $null
    if ($Response.Headers.TryGetValues($Name, [ref] $values) -or
        $Response.Content.Headers.TryGetValues($Name, [ref] $values)) {
        return ($values -join ', ')
    }
    return $null
}

function Write-StreamText {
    param(
        [Parameter(Mandatory)] [System.IO.Stream] $Stream,
        [Parameter(Mandatory)] [string] $Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Read-StreamUntil {
    param(
        [Parameter(Mandatory)] [System.IO.Stream] $Stream,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Description
    )

    $matcher = [regex]::new(
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $buffer = [byte[]]::new(4096)
    $response = [System.Text.StringBuilder]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = $deadline - [DateTime]::UtcNow
        $Stream.ReadTimeout = [Math]::Max(1, [int]$remaining.TotalMilliseconds)
        try {
            $read = $Stream.Read($buffer, 0, $buffer.Length)
        }
        catch {
            throw "Timed out while reading $Description."
        }
        if ($read -eq 0) {
            throw "The server closed the connection while reading $Description."
        }
        $response.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)) | Out-Null
        $text = $response.ToString()
        if ($matcher.IsMatch($text)) {
            return $text
        }
        if ($response.Length -gt 1048576) {
            throw "The response exceeded 1 MiB while reading $Description."
        }
    }
    throw "Timed out while reading $Description."
}

function Test-XmppStartTls {
    $client = [System.Net.Sockets.TcpClient]::new()
    $network = $null
    $tls = $null
    try {
        $connectTask = $client.ConnectAsync($Domain, 5222)
        if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            throw 'TCP 5222 connection timed out.'
        }
        $network = $client.GetStream()
        $network.WriteTimeout = $TimeoutSeconds * 1000

        $streamOpen = "<stream:stream to='$Domain' version='1.0' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
        Write-StreamText -Stream $network -Text $streamOpen
        $plainFeatures = Read-StreamUntil -Stream $network -Pattern '</stream:features>' -Description 'pre-TLS XMPP features'
        if ($plainFeatures -notmatch '<starttls\b[^>]*>.*?<required\s*/?>.*?</starttls>' -or
            -not $plainFeatures.Contains('urn:ietf:params:xml:ns:xmpp-tls')) {
            Add-Failure 'XMPP 5222 does not advertise STARTTLS as required.'
            return
        }

        Write-StreamText -Stream $network -Text "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"
        Read-StreamUntil -Stream $network -Pattern '<proceed\b[^>]*(?:/>|>.*?</proceed>)' -Description 'STARTTLS proceed' | Out-Null

        $tls = [System.Net.Security.SslStream]::new($network, $false)
        $tls.ReadTimeout = $TimeoutSeconds * 1000
        $tls.WriteTimeout = $TimeoutSeconds * 1000
        # The default callback validates both the public trust chain and $Domain.
        $tls.AuthenticateAsClient($Domain)
        $negotiatedProtocol = $tls.SslProtocol.ToString()
        if ($negotiatedProtocol -notin @('Tls12', 'Tls13')) {
            Add-Failure "XMPP STARTTLS negotiated an obsolete protocol: $negotiatedProtocol"
        }

        Write-StreamText -Stream $tls -Text $streamOpen
        $tlsFeatures = Read-StreamUntil -Stream $tls -Pattern '</stream:features>' -Description 'post-TLS XMPP features'
        $mechanisms = @([regex]::Matches(
                $tlsFeatures,
                '<mechanism\b[^>]*>\s*([^<]+?)\s*</mechanism>',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) |
            ForEach-Object { $_.Groups[1].Value.Trim().ToUpperInvariant() } |
            Sort-Object -Unique)
        foreach ($requiredMechanism in @('SCRAM-SHA-256', 'X-OAUTH2')) {
            if ($requiredMechanism -notin $mechanisms) {
                Add-Failure "Required SASL mechanism is not advertised: $requiredMechanism"
            }
        }
        foreach ($forbiddenMechanism in @(
            'ANONYMOUS',
            'CRAM-MD5',
            'DIGEST-MD5',
            'LOGIN',
            'PLAIN',
            'SCRAM-SHA-1',
            'SCRAM-SHA-1-PLUS',
            'SCRAM-SHA-512',
            'SCRAM-SHA-512-PLUS'
        )) {
            if ($forbiddenMechanism -in $mechanisms) {
                Add-Failure "Forbidden SASL mechanism is advertised: $forbiddenMechanism"
            }
        }
        if ($tlsFeatures.Contains('http://jabber.org/features/iq-register')) {
            Add-Failure 'Public XEP-0077 registration is still advertised.'
        }

        # An unauthenticated client is not allowed to send arbitrary IQ stanzas after
        # STARTTLS. Depending on the ejabberd release, probing XEP-0077 here either
        # returns an IQ error or closes the stream as a protocol violation. The
        # authoritative publication check is therefore the absence of the register
        # feature above; accepting a stream close avoids treating strict enforcement
        # as a deployment failure.
        $registrationProbe = "<iq type='get' id='maer-preflight-register'><query xmlns='jabber:iq:register'/></iq>"
        Write-StreamText -Stream $tls -Text $registrationProbe
        try {
            $registrationResponse = Read-StreamUntil -Stream $tls `
                -Pattern '<iq\b[^>]*\bid=[''"]maer-preflight-register[''"][^>]*>.*?</iq>' `
                -Description 'XEP-0077 refusal'
            if ($registrationResponse -notmatch '<iq\b[^>]*\btype=[''"]error[''"]' -or
                $registrationResponse -notmatch '<(?:service-unavailable|forbidden|not-allowed)\b') {
                Add-Failure 'Public XEP-0077 registration was not refused with a protocol error.'
            }
        }
        catch {
            if ($_.Exception.Message -notmatch '(?i)(closed|end of stream|EOF)') {
                throw
            }
        }
    }
    catch {
        Add-Failure "XMPP STARTTLS/SASL preflight failed: $($_.Exception.Message)"
    }
    finally {
        if ($tls) {
            $tls.Dispose()
        }
        elseif ($network) {
            $network.Dispose()
        }
        $client.Dispose()
    }
}

function Test-DirectObsoleteTlsProtocol {
    param([System.Security.Authentication.SslProtocols] $Protocol)

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $client.ConnectAsync($Domain, 443)
        if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            throw 'TCP connect timed out.'
        }
        $network = $client.GetStream()
        $network.ReadTimeout = $TimeoutSeconds * 1000
        $network.WriteTimeout = $TimeoutSeconds * 1000
        $tls = [System.Net.Security.SslStream]::new($network, $false)
        try {
            $tls.AuthenticateAsClient($Domain, $null, $Protocol, $false)
            Add-Failure "HTTPS 443 accepted obsolete protocol $Protocol."
        }
        catch {
            # Expected: either the remote endpoint or the local crypto policy
            # rejects the obsolete protocol before a session is established.
        }
        finally {
            $tls.Dispose()
        }
    }
    catch {
        Add-Failure "Could not probe obsolete HTTPS protocol ${Protocol}: $($_.Exception.Message)"
    }
    finally {
        $client.Dispose()
    }
}

function Test-XmppObsoleteTlsProtocol {
    param([System.Security.Authentication.SslProtocols] $Protocol)

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $client.ConnectAsync($Domain, 5222)
        if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            throw 'TCP connect timed out.'
        }
        $network = $client.GetStream()
        $network.ReadTimeout = $TimeoutSeconds * 1000
        $network.WriteTimeout = $TimeoutSeconds * 1000
        $streamOpen = "<stream:stream to='$Domain' version='1.0' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
        Write-StreamText -Stream $network -Text $streamOpen
        Read-StreamUntil -Stream $network -Pattern '</stream:features>' -Description "pre-${Protocol} XMPP features" | Out-Null
        Write-StreamText -Stream $network -Text "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"
        Read-StreamUntil -Stream $network -Pattern '<proceed\b[^>]*(?:/>|>.*?</proceed>)' -Description "${Protocol} STARTTLS proceed" | Out-Null
        $tls = [System.Net.Security.SslStream]::new($network, $false)
        try {
            $tls.AuthenticateAsClient($Domain, $null, $Protocol, $false)
            Add-Failure "XMPP 5222 accepted obsolete protocol $Protocol."
        }
        catch {
            # Expected rejection; no obsolete TLS session may be established.
        }
        finally {
            $tls.Dispose()
        }
    }
    catch {
        Add-Failure "Could not probe obsolete XMPP protocol ${Protocol}: $($_.Exception.Message)"
    }
    finally {
        $client.Dispose()
    }
}

function Test-ObsoleteTlsRejection {
    foreach ($protocol in @(
        [System.Security.Authentication.SslProtocols]::Tls,
        [System.Security.Authentication.SslProtocols]::Tls11
    )) {
        Test-DirectObsoleteTlsProtocol -Protocol $protocol
        Test-XmppObsoleteTlsProtocol -Protocol $protocol
    }
}

function Test-RetiredDomainAbsent {
    if ($RetiredDomain.Equals($Domain, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Failure 'Retired domain must differ from the active XMPP domain.'
        return
    }

    $publicRetiredAddresses = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        # Query independent public resolvers directly. The system resolver (often
        # the NAS/router) can legitimately retain the removed record until its TTL
        # expires and must not turn successful public retirement into a false alarm.
        foreach ($resolver in @('1.1.1.1', '8.8.8.8')) {
            foreach ($retiredName in @($RetiredDomain, "_xmpp-client._tcp.$RetiredDomain", "_xmpp-server._tcp.$RetiredDomain")) {
                try {
                    $records = @(Resolve-DnsName -Name $retiredName -Server $resolver -DnsOnly -ErrorAction Stop)
                    if ($records.Count -gt 0) {
                        Add-Failure "Retired DNS name still has public records through ${resolver}: $retiredName"
                        if ($retiredName -eq $RetiredDomain) {
                            foreach ($record in $records) {
                                if ($record.IPAddress) {
                                    $publicRetiredAddresses.Add([string]$record.IPAddress) | Out-Null
                                }
                            }
                        }
                    }
                }
                catch {
                    # NXDOMAIN/no records is expected.
                }
            }
        }
    }

    foreach ($retiredAddress in $publicRetiredAddresses) {
        foreach ($retiredPort in @(80, 443, 5222, 5269)) {
            if (Test-TcpPort -HostName $retiredAddress -Port $retiredPort) {
                Add-Failure "Retired domain still exposes TCP port $retiredPort through $retiredAddress."
            }
        }
    }
}

try {
    $addresses = [System.Net.Dns]::GetHostAddresses($Domain)
    if ($addresses.Count -eq 0) {
        Add-Failure "DNS A/AAAA does not resolve: $Domain"
    }
}
catch {
    Add-Failure "DNS A/AAAA resolution failed: $Domain"
}

$resolveDnsName = Get-Command Resolve-DnsName -ErrorAction SilentlyContinue
if ($resolveDnsName) {
    foreach ($resolver in @($null, '1.1.1.1', '8.8.8.8')) {
        $resolverLabel = if ($resolver) { $resolver } else { 'system resolver' }
        $commonArguments = @{
            DnsOnly = $true
            ErrorAction = 'Stop'
        }
        if ($resolver) {
            $commonArguments.Server = $resolver
        }
        try {
            $addressRecords = @(Resolve-DnsName -Name $Domain -Type A @commonArguments |
                Where-Object { $_.Type -eq 'A' -and $_.IPAddress })
            if ($addressRecords.Count -eq 0) {
                Add-Failure "DNS A record is missing through $resolverLabel."
            }
        }
        catch {
            Add-Failure "DNS A resolution failed through $resolverLabel."
        }

        try {
            $srvName = "_xmpp-client._tcp.$Domain"
            $srv = @(Resolve-DnsName -Name $srvName -Type SRV @commonArguments |
                Where-Object { $_.Type -eq 'SRV' })
            $matchingSrv = @($srv | Where-Object {
                $_.Port -eq 5222 -and $_.NameTarget.TrimEnd('.').Equals(
                    $Domain, [System.StringComparison]::OrdinalIgnoreCase)
            })
            if ($matchingSrv.Count -eq 0) {
                Add-Failure "SRV must publish $srvName -> ${Domain}:5222 through $resolverLabel."
            }
        }
        catch {
            Add-Failure "SRV record is missing through ${resolverLabel}: _xmpp-client._tcp.$Domain"
        }
    }
}
else {
    Add-Failure 'Resolve-DnsName is unavailable; SRV could not be verified.'
}

foreach ($requiredPort in @(443, 5222)) {
    if (-not (Test-TcpPort -HostName $Domain -Port $requiredPort)) {
        Add-Failure "Required public TCP port is closed: $requiredPort"
    }
}
foreach ($privatePort in @(4369, 5211, 5269, 5280, 5443)) {
    if (Test-TcpPort -HostName $Domain -Port $privatePort) {
        Add-Failure "Private TCP port must not be public: $privatePort"
    }
}

Test-XmppStartTls
Test-ObsoleteTlsRejection
Test-RetiredDomainAbsent

$httpsChecks = @(
    [pscustomobject]@{ Method = 'GET'; Path = '/.well-known/host-meta'; Status = 200 },
    [pscustomobject]@{ Method = 'GET'; Path = '/.well-known/host-meta.json'; Status = 200 },
    [pscustomobject]@{ Method = 'OPTIONS'; Path = '/http-bind'; Status = 200 },
    [pscustomobject]@{ Method = 'OPTIONS'; Path = '/maer-pairing/v1/sessions'; Status = 204 },
    # mod_http_upload only serves tokenized slot URLs. The bare route must not
    # expose a directory or accept uploads without a slot negotiated over XMPP.
    [pscustomobject]@{ Method = 'OPTIONS'; Path = '/upload'; Status = 404 }
)

foreach ($check in $httpsChecks) {
    $url = "https://$Domain$($check.Path)"
    try {
        $response = Send-HttpRequest -Method $check.Method -Url $url
        try {
            if ([int]$response.StatusCode -ne $check.Status) {
                Add-Failure "$($check.Method) $($check.Path) returned $([int]$response.StatusCode), expected $($check.Status)."
            }
            if ($check.Path -in @('/.well-known/host-meta', '/.well-known/host-meta.json') -and
                [int]$response.StatusCode -eq 200) {
                $metadata = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                foreach ($canonicalUrl in @(
                    "https://$Domain/http-bind",
                    "wss://$Domain/xmpp-websocket"
                )) {
                    if (-not $metadata.Contains($canonicalUrl)) {
                        Add-Failure "$($check.Path) does not advertise $canonicalUrl"
                    }
                }
                if ($metadata.Contains("${Domain}:5443")) {
                    Add-Failure "$($check.Path) leaks the private backend port 5443."
                }
            }
            $origin = Get-HeaderValue -Response $response -Name 'Access-Control-Allow-Origin'
            if ($origin -ne "https://$Domain") {
                Add-Failure "$($check.Path) has an unexpected CORS origin: '$origin'"
            }
            $expectedHeaders = [ordered]@{
                'Content-Security-Policy' = "default-src 'none'; frame-ancestors 'none'"
                'Referrer-Policy' = 'no-referrer'
                'Strict-Transport-Security' = 'max-age=31536000'
                'Vary' = 'Origin'
                'X-Content-Type-Options' = 'nosniff'
                'X-Frame-Options' = 'DENY'
            }
            foreach ($requiredHeader in $expectedHeaders.Keys) {
                $actualHeader = Get-HeaderValue -Response $response -Name $requiredHeader
                if ($actualHeader -cne $expectedHeaders[$requiredHeader]) {
                    Add-Failure "$($check.Path) has unexpected '$requiredHeader': '$actualHeader' (expected '$($expectedHeaders[$requiredHeader])')."
                }
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch {
        Add-Failure "$($check.Method) $($check.Path) failed: $($_.Exception.Message)"
    }
}

try {
    $rid = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(100000000, 2000000000)
    $boshPayload = "<body content='text/xml; charset=utf-8' hold='1' rid='$rid' to='$Domain' ver='1.6' wait='5' xmlns='http://jabber.org/protocol/httpbind' xmlns:xmpp='urn:xmpp:xbosh' xmpp:version='1.0'/>"
    $boshResponse = Send-HttpRequest -Method 'POST' -Url "https://$Domain/http-bind" `
        -Body $boshPayload -ContentType 'text/xml'
    try {
        $boshBody = $boshResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ([int]$boshResponse.StatusCode -ne 200 -or
            $boshBody -notmatch '<body\b[^>]*\bsid=[''"][^''"]+[''"]') {
            Add-Failure 'BOSH did not create a real unauthenticated XMPP session.'
        }
    }
    finally {
        $boshResponse.Dispose()
    }
}
catch {
    Add-Failure "BOSH session opening failed: $($_.Exception.Message)"
}

try {
    $pairingResponse = Send-HttpRequest -Method 'POST' `
        -Url "https://$Domain/maer-pairing/v1/sessions" `
        -Body '{}' -ContentType 'application/json'
    try {
        $pairingBody = $pairingResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $pairingContentType = Get-HeaderValue -Response $pairingResponse -Name 'Content-Type'
        if ([int]$pairingResponse.StatusCode -ne 400 -or
            $pairingContentType -notmatch '^application/json' -or
            $pairingBody -notmatch '"error"') {
            Add-Failure 'Pairing did not reject an invalid request with a structured JSON 400 response.'
        }
    }
    finally {
        $pairingResponse.Dispose()
    }
}
catch {
    Add-Failure "Pairing invalid-request probe failed: $($_.Exception.Message)"
}

foreach ($privatePath in @('/admin/', '/api')) {
    try {
        $privateResponse = Send-HttpRequest -Method 'GET' -Url "https://$Domain$privatePath"
        try {
            if ([int]$privateResponse.StatusCode -notin @(404, 410)) {
                Add-Failure "Private HTTP surface is externally reachable at $privatePath (HTTP $([int]$privateResponse.StatusCode))."
            }
        }
        finally {
            $privateResponse.Dispose()
        }
    }
    catch {
        Add-Failure "Unable to prove that $privatePath is absent: $($_.Exception.Message)"
    }
}

try {
    $hostileOrigin = 'https://untrusted.invalid'
    $hostileCorsResponse = Send-HttpRequest -Method 'OPTIONS' -Url "https://$Domain/http-bind" -Origin $hostileOrigin
    try {
        $hostileAllowOrigin = Get-HeaderValue -Response $hostileCorsResponse -Name 'Access-Control-Allow-Origin'
        if ($hostileAllowOrigin -in @('*', $hostileOrigin)) {
            Add-Failure "BOSH accepts an untrusted browser origin: $hostileAllowOrigin"
        }
    }
    finally {
        $hostileCorsResponse.Dispose()
    }
}
catch {
    Add-Failure "Unable to test BOSH with an untrusted origin: $($_.Exception.Message)"
}

if (Test-TcpPort -HostName $Domain -Port 80) {
    try {
        $httpResponse = Send-HttpRequest -Method 'GET' -Url "http://$Domain/"
        try {
            $location = Get-HeaderValue -Response $httpResponse -Name 'Location'
            if ([int]$httpResponse.StatusCode -notin @(301, 308) -or
                -not $location -or -not $location.StartsWith("https://$Domain", [System.StringComparison]::OrdinalIgnoreCase)) {
                Add-Failure 'Public HTTP 80 must redirect to the canonical HTTPS origin.'
            }
        }
        finally {
            $httpResponse.Dispose()
        }
    }
    catch {
        Add-Failure "HTTP redirect check failed: $($_.Exception.Message)"
    }
}

try {
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.Options.AddSubProtocol('xmpp')
    $socket.Options.SetRequestHeader('Origin', "https://$Domain")
    $cancellation = [System.Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        $socket.ConnectAsync([Uri]"wss://$Domain/xmpp-websocket", $cancellation.Token).GetAwaiter().GetResult() | Out-Null
        if ($socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Add-Failure 'WebSocket endpoint did not reach the Open state.'
        }
        if ($socket.SubProtocol -ne 'xmpp') {
            Add-Failure "WebSocket endpoint did not negotiate the xmpp subprotocol: '$($socket.SubProtocol)'"
        }
        if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $xmppCancellation = [System.Threading.CancellationTokenSource]::new(
                [TimeSpan]::FromSeconds($TimeoutSeconds))
            try {
                $openingFrame = [System.Text.Encoding]::UTF8.GetBytes(
                    "<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' to='$Domain' version='1.0'/>")
                $socket.SendAsync(
                    [ArraySegment[byte]]::new($openingFrame),
                    [System.Net.WebSockets.WebSocketMessageType]::Text,
                    $true,
                    $xmppCancellation.Token).GetAwaiter().GetResult() | Out-Null

                $receiveBytes = [byte[]]::new(8192)
                $receiveSegment = [ArraySegment[byte]]::new($receiveBytes)
                $xmppResponse = [System.Text.StringBuilder]::new()
                while (-not $xmppResponse.ToString().Contains('</stream:features>')) {
                    $receiveResult = $socket.ReceiveAsync(
                        $receiveSegment,
                        $xmppCancellation.Token).GetAwaiter().GetResult()
                    if ($receiveResult.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                        throw 'WebSocket closed before returning XMPP features.'
                    }
                    $xmppResponse.Append([System.Text.Encoding]::UTF8.GetString(
                            $receiveBytes, 0, $receiveResult.Count)) | Out-Null
                    if ($xmppResponse.Length -gt 65536) {
                        throw 'WebSocket XMPP features exceeded 64 KiB.'
                    }
                }
                if ($xmppResponse.ToString() -notmatch '<open\b' -or
                    $xmppResponse.ToString() -notmatch '<stream:features\b') {
                    Add-Failure 'WebSocket upgrade succeeded but XMPP framing/features did not.'
                }
            }
            finally {
                $xmppCancellation.Dispose()
            }
        }
    }
    finally {
        $socket.Abort()
        $socket.Dispose()
        $cancellation.Dispose()
    }
}
catch {
    Add-Failure "WebSocket upgrade failed: $($_.Exception.Message)"
}

$hostileSocket = [System.Net.WebSockets.ClientWebSocket]::new()
$hostileCancellation = [System.Threading.CancellationTokenSource]::new(
    [TimeSpan]::FromSeconds($TimeoutSeconds))
try {
    $hostileSocket.Options.AddSubProtocol('xmpp')
    $hostileSocket.Options.SetRequestHeader('Origin', 'https://untrusted.invalid')
    try {
        $hostileSocket.ConnectAsync(
            [Uri]"wss://$Domain/xmpp-websocket",
            $hostileCancellation.Token).GetAwaiter().GetResult() | Out-Null
        Add-Failure 'WebSocket accepted an untrusted browser origin.'
    }
    catch {
        if ($_.Exception.Message -notmatch '\b403\b') {
            Add-Failure "WebSocket did not reject an untrusted origin cleanly with HTTP 403: $($_.Exception.Message)"
        }
    }
}
finally {
    $hostileSocket.Abort()
    $hostileSocket.Dispose()
    $hostileCancellation.Dispose()
}

if ($script:Failures.Count -gt 0) {
    Write-Host "DSM publication preflight failed ($($script:Failures.Count) issue(s)):" -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host 'DSM publication preflight passed.' -ForegroundColor Green
