# SPDX-License-Identifier: BSD-3-Clause
# Portions Copyright (c) 2011, Sebastien Erard
# Modifications Copyright (c) 2026 MAER contributors

PKG_NAME = erlang
PKG_VERS = 27.3.4.16
PKG_EXT = tar.gz
PKG_DIST_NAME = OTP-$(PKG_VERS).$(PKG_EXT)
PKG_DIST_SITE = https://github.com/erlang/otp/archive
PKG_DIST_FILE = $(PKG_NAME)-OTP-$(PKG_VERS).$(PKG_EXT)
PKG_DIR = otp-OTP-$(PKG_VERS)

DEPENDS =

HOMEPAGE = https://www.erlang.org
COMMENT = Erlang/OTP native build tools for MAER XMPP Server.
LICENSE = Apache-2.0

CONFIGURE_TARGET = erlang_maer_configure
INSTALL_ARGS = install INSTALL_PREFIX=

CONFIGURE_ARGS  = --without-javac
CONFIGURE_ARGS += --without-jinterface
CONFIGURE_ARGS += --without-odbc
CONFIGURE_ARGS += --without-wx
CONFIGURE_ARGS += --without-debugger
CONFIGURE_ARGS += --without-et
CONFIGURE_ARGS += --without-observer
CONFIGURE_ARGS += --without-reltool
CONFIGURE_ARGS += --disable-pgo
CONFIGURE_ARGS += --enable-deterministic-build
CONFIGURE_ARGS += --enable-dynamic-ssl-lib
CONFIGURE_ARGS += --prefix=$(INSTALL_DIR)$(INSTALL_PREFIX)
CONFIGURE_ARGS += CFLAGS="-O2 -g -D_GNU_SOURCE"

include ../../mk/spksrc.native-cc.mk

.PHONY: erlang_maer_configure
erlang_maer_configure:
	$(RUN) ./otp_build configure $(CONFIGURE_ARGS)
