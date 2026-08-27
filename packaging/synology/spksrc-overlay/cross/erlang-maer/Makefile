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

BUILD_DEPENDS = native/erlang-maer
DEPENDS = cross/ncursesw cross/openssl3-maer

UNSUPPORTED_ARCHS = $(filter-out armada38x,$(ALL_ARCHS))

HOMEPAGE = https://www.erlang.org
COMMENT = Erlang/OTP runtime for MAER XMPP Server on armada38x.
LICENSE = Apache-2.0

NATIVE_ERLANG_BIN_DIR = $(abspath $(WORK_DIR)/../../../native/erlang-maer/work-native/install/usr/local/bin)
ENV = PATH=$(NATIVE_ERLANG_BIN_DIR):$$PATH

INSTALL_ARGS = install DESTDIR=$(INSTALL_DIR) INSTALL_PREFIX=

CONFIGURE_ARGS  = --without-javac
CONFIGURE_ARGS += --without-jinterface
CONFIGURE_ARGS += --without-odbc
CONFIGURE_ARGS += --without-wx
CONFIGURE_ARGS += --without-debugger
CONFIGURE_ARGS += --without-et
CONFIGURE_ARGS += --without-observer
CONFIGURE_ARGS += --without-reltool
CONFIGURE_ARGS += --enable-dynamic-ssl-lib
CONFIGURE_ARGS += --with-ssl=$(STAGING_INSTALL_PREFIX)
CONFIGURE_ARGS += --disable-year2038
CONFIGURE_ARGS += erl_xcomp_sysroot=$(INSTALL_DIR)
CONFIGURE_ARGS += CFLAGS="-O2 -g -D_GNU_SOURCE"

include ../../mk/spksrc.common.mk

# Force cross-compilation. The two canonical triplets must differ for OTP.
CONFIGURE_ARGS += --host=$(TC_TARGET) --prefix=$(INSTALL_PREFIX)
CONFIGURE_ARGS += --build=i686-pc-linux

include ../../mk/spksrc.cross-cc.mk
