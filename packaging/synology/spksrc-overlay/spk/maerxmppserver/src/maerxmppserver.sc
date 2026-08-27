# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

[maerxmppserver_xmpp]
title="MAER XMPP Server - XMPP"
desc="XMPP client connections with mandatory STARTTLS"
port_forward="yes"
dst.ports="5222/tcp"

# HTTPS is deliberately loopback-only on 127.0.0.1:5443. DSM reverse proxy
# publishes the allowlisted protocol paths on the canonical public port 443.
