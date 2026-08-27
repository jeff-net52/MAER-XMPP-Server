# SPDX-License-Identifier: BSD-3-Clause
# Portions Copyright (c) 2011, Sebastien Erard
# Modifications Copyright (c) 2026 MAER contributors

PKG_NAME = maer-xmpp-server
PKG_VERS = 26.07
PKG_COMMIT = e98520dbd6f8715e0fdfcc431052dfd4c6d6b8cc
PKG_EXT = tar.gz
PKG_DIST_NAME = $(PKG_COMMIT).$(PKG_EXT)
PKG_DIST_SITE = https://github.com/jeff-net52/MAER-XMPP-Server/archive
PKG_DIST_FILE = $(PKG_NAME)-$(PKG_COMMIT).$(PKG_EXT)
PKG_DIR = MAER-XMPP-Server-$(PKG_COMMIT)

BUILD_DEPENDS = native/erlang-maer
DEPENDS = cross/ncursesw cross/erlang-maer cross/libexpat cross/zlib
DEPENDS += cross/openssl3-maer cross/libyaml cross/sqlite

UNSUPPORTED_ARCHS = $(filter-out armada38x,$(ALL_ARCHS))

HOMEPAGE = https://github.com/jeff-net52/MAER-XMPP-Server
COMMENT = MAER XMPP Server, based on ejabberd Community Server.
LICENSE = GPL-2.0-only WITH OpenSSL-exception

NATIVE_ERLANG_ROOT_DIR = $(abspath $(WORK_DIR)/../../../native/erlang-maer/work-native/install/usr/local)
NATIVE_ERLANG_BIN = $(NATIVE_ERLANG_ROOT_DIR)/bin

GNU_CONFIGURE = 1
CONFIGURE_ARGS = ac_cv_erlang_root_dir=$(NATIVE_ERLANG_ROOT_DIR)
CONFIGURE_ARGS += --enable-sqlite
CONFIGURE_ARGS += --enable-multihost-sql-schema
CONFIGURE_ARGS += --sbindir=$(INSTALL_PREFIX)/bin

ADDITIONAL_LDFLAGS = -L$(STAGING_INSTALL_PREFIX)/lib/erlang/usr/lib
ADDITIONAL_CFLAGS = -I$(STAGING_INSTALL_PREFIX)/lib/erlang/usr/include
ADDITIONAL_CPPFLAGS = $(ADDITIONAL_CFLAGS)

PRE_CONFIGURE_TARGET = maerxmppserver_pre_configure
POST_INSTALL_TARGET = maerxmppserver_post_install

ENV += PATH=$(NATIVE_ERLANG_BIN):$$PATH

include ../../mk/spksrc.cross-cc.mk

.PHONY: maerxmppserver_pre_configure
maerxmppserver_pre_configure:
	@$(MSG) Patch rebar dependency configure commands for cross-compilation
	@$(RUN) ; sed -e "s#\" ./configure \"#\" ./configure $(TC_CONFIGURE_ARGS)\"#g" -i ./rebar.config.script
	@$(MSG) Generate configure without deriving the version from a Git checkout
	@$(RUN) ; sed 's#git describe --tags 2>/dev/null || ##' -i ./configure.ac
	@$(RUN) ; ./autogen.sh

.PHONY: maerxmppserver_post_install
maerxmppserver_post_install:
	sed -e "s#$(INSTALL_DIR)##g" \
	    -e "s#$(NATIVE_ERLANG_BIN)#$(INSTALL_PREFIX)/bin#g" \
	    -e 's#^INSTALLUSER=.*#INSTALLUSER="sc-maerxmppserver"#g' \
	    -i $(STAGING_INSTALL_PREFIX)/bin/ejabberdctl
