# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 MAER contributors

PKG_NAME = openssl3-maer
PKG_VERS = 3.5.7
PKG_EXT = tar.gz
PKG_DIST_NAME = openssl-$(PKG_VERS).$(PKG_EXT)
PKG_DIST_SITE = https://www.openssl.org/source
PKG_DIR = openssl-$(PKG_VERS)

DEPENDS = cross/zlib

HOMEPAGE = https://www.openssl.org
COMMENT = OpenSSL runtime with reproducible MAER build metadata.
LICENSE = Apache-2.0

# OpenSSL otherwise records the wall-clock build time in libcrypto.  Pin the
# public 3.5.7 release date so the runtime metadata is byte-for-byte stable.
ENV += SOURCE_DATE_EPOCH=1780963200

CONFIGURE_TARGET = openssl3_maer_configure
INSTALL_ARGS = install_sw DESTDIR=$(INSTALL_DIR)

CONFIGURE_ARGS = --prefix=$(INSTALL_PREFIX)
CONFIGURE_ARGS += --openssldir=/etc/ssl
CONFIGURE_ARGS += zlib-dynamic
CONFIGURE_ARGS += shared
CONFIGURE_ARGS += no-tests
CONFIGURE_ARGS += --libdir=lib

include ../../mk/spksrc.cross-cc.mk

OPENSSL_PLATFORM =

ifeq ($(findstring $(ARCH),$(ARMv7_ARCHS) $(ARMv7L_ARCHS)),$(ARCH))
OPENSSL_PLATFORM = linux-armv4
endif

ifeq ($(strip $(OPENSSL_PLATFORM)),)
$(error MAER OpenSSL only supports the locked ARMv7 target, got $(ARCH))
endif

.PHONY: openssl3_maer_configure
openssl3_maer_configure:
	$(RUN) ./Configure $(OPENSSL_PLATFORM) $(CONFIGURE_ARGS)
