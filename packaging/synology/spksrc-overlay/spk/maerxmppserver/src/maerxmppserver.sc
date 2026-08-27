# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

[maerxmppserver_xmpp]
title="MAER XMPP Server - XMPP"
desc="XMPP client connections with mandatory STARTTLS"
port_forward="yes"
dst.ports="5222/tcp"

[maerxmppserver_https]
title="MAER XMPP Server - HTTPS"
desc="BOSH, WebSocket, host metadata and file upload"
port_forward="yes"
dst.ports="5443/tcp"
