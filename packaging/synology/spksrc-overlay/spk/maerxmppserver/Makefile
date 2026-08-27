# SPDX-License-Identifier: BSD-3-Clause
# Portions Copyright (c) 2011, Sebastien Erard
# Modifications Copyright (c) 2026 MAER contributors

SPK_NAME = maerxmppserver
GROUP = sc-maerxmppserver
SPK_VERS = 26.07.0
SPK_REV = 4
SPK_ICON = src/maerxmppserver.png

DEPENDS = cross/maerxmppserver

UNSUPPORTED_ARCHS = $(filter-out armada38x,$(ALL_ARCHS))
# Armada38x has no DSM 7.2 SDK in spksrc. Build against the latest compatible
# DSM 7.1 toolchain, while OS_MIN_VER keeps installation restricted to the
# exact DSM 7.2 build validated for this package.
REQUIRED_MIN_DSM = 7.1
OS_MIN_VER = 7.2-72806

MAINTAINER = jeff-net52
MAINTAINER_URL = https://github.com/jeff-net52
DISABLE_GITHUB_MAINTAINER = 1
# spksrc/local.mk may define empty repository-wide publishing metadata after
# this recipe is parsed. Keep the package identity authoritative in INFO.
override DISTRIBUTOR = MAER
override DISTRIBUTOR_URL = https://github.com/jeff-net52/MAER-XMPP-Server
DESCRIPTION = Private XMPP messaging server for MAER Chat.
DISPLAY_NAME = MAER XMPP Server
CHANGELOG = "Clean-install-only hardened profile with strict proxy trust, upload quotas, and reproducible archives."

HOMEPAGE = https://github.com/jeff-net52/MAER-XMPP-Server
HELPURL = https://github.com/jeff-net52/MAER-XMPP-Server/tree/maer/server-v1/packaging/synology
LICENSE = GPLv2 with OpenSSL exception
LICENSE_FILE = src/COPYING

STARTABLE = yes
SERVICE_USER = auto
SERVICE_SETUP = src/service-setup.sh
SSS_SCRIPT = src/service-start-stop.sh
FWPORTS = src/maerxmppserver.sc
NO_SERVICE_SHORTCUT = yes

NATIVE_ERLANG_BIN_DIR = $(abspath $(WORK_DIR)/../../../native/erlang-maer/work-native/install/usr/local/bin)
SPKSRC_BUILD_ROOT = $(abspath $(WORK_DIR)/../../..)
RUNTIME_RPATH = /var/packages/maerxmppserver/target/lib
OTP_DEVELOPMENT_APPLICATIONS = common_test dialyzer edoc erl_interface eunit
SERVER_RUNTIME_APPLICATIONS = cache_tab eimp ejabberd erlydtl ezlib fast_tls fast_xml
SERVER_RUNTIME_APPLICATIONS += fast_yaml idna jose luerl mqtree p1_acme p1_oauth2
SERVER_RUNTIME_APPLICATIONS += p1_utils pkix sqlite3 stringprep stun xmpp yconf
SYSTEM_NEEDED_LIBRARIES = ld-linux-armhf.so.3 libc.so.6 libdl.so.2 libgcc_s.so.1
SYSTEM_NEEDED_LIBRARIES += libm.so.6 libpthread.so.0 libresolv.so.2 librt.so.1
SYSTEM_NEEDED_LIBRARIES += libstdc++.so.6 libutil.so.1

POST_STRIP_TARGET = maerxmppserver_runtime_finalize
POST_SERVICE_TARGET = maerxmppserver_service_finalize
POST_COPY_TARGET = maerxmppserver_copy_runtime

include ../../mk/spksrc.spk.mk

# spksrc normally preserves build-time mtimes in both package.tgz and the outer
# SPK tarball.  Pin the archive metadata and gzip header so that rebuilding an
# unchanged checkout produces the exact same package bytes on every host.
MAER_SOURCE_DATE_EPOCH = 1785110400
MAER_REPRODUCIBLE_TAR_OPTIONS = --sort=name --mtime=@$(MAER_SOURCE_DATE_EPOCH) --owner=0 --group=0 --numeric-owner
$(SPK_FILE_NAME): export TAR_OPTIONS = $(MAER_REPRODUCIBLE_TAR_OPTIONS)
$(SPK_FILE_NAME): export GZIP = -n

.PHONY: maerxmppserver_copy_runtime
maerxmppserver_copy_runtime: copy_target
	install -m 755 -d $(STAGING_DIR)/bin $(STAGING_DIR)/lib
	install -m 755 $(STAGING_INSTALL_PREFIX)/bin/ejabberdctl $(STAGING_DIR)/bin/ejabberdctl
	install -m 755 src/upload-usage-check.sh $(STAGING_DIR)/bin/maer-upload-usage-check
	cp -a $(foreach application,$(SERVER_RUNTIME_APPLICATIONS),$(STAGING_INSTALL_PREFIX)/lib/$(application)-*) $(STAGING_DIR)/lib/
	test -f $(STAGING_DIR)/lib/ejabberd-26.07/ebin/mod_maer_pairing.beam

.PHONY: maerxmppserver_service_finalize
maerxmppserver_service_finalize:
	chmod 755 $(DSM_SCRIPTS_DIR)/service-setup
	test -x $(DSM_SCRIPTS_DIR)/service-setup

.PHONY: maerxmppserver_runtime_finalize
maerxmppserver_runtime_finalize:
	chmod 755 $(STAGING_DIR)/bin/ejabberdctl
	install -m 755 -d $(STAGING_DIR)/share/maerxmppserver/defaults
	install -m 644 src/defaults/ejabberd.yml $(STAGING_DIR)/share/maerxmppserver/defaults/
	install -m 644 src/defaults/ejabberdctl.cfg $(STAGING_DIR)/share/maerxmppserver/defaults/
	install -m 644 src/defaults/inetrc $(STAGING_DIR)/share/maerxmppserver/defaults/
	install -m 755 -d $(STAGING_DIR)/share/maerxmppserver/licenses
	install -m 644 $(WORK_DIR)/otp-OTP-27.3.4.16/LICENSE.txt $(STAGING_DIR)/share/maerxmppserver/licenses/Erlang-OTP-27.3.4.16.txt
	install -m 644 $(WORK_DIR)/openssl-3.5.7/LICENSE.txt $(STAGING_DIR)/share/maerxmppserver/licenses/OpenSSL-3.5.7.txt
	install -m 644 $(WORK_DIR)/ncurses-6.6/COPYING $(STAGING_DIR)/share/maerxmppserver/licenses/ncurses-6.6.txt
	install -m 644 $(WORK_DIR)/zlib-1.3.2/LICENSE $(STAGING_DIR)/share/maerxmppserver/licenses/zlib-1.3.2.txt
	install -m 644 $(WORK_DIR)/libexpat-R_2_8_3/COPYING $(STAGING_DIR)/share/maerxmppserver/licenses/Expat-2.8.3.txt
	install -m 644 $(WORK_DIR)/yaml-0.2.5/License $(STAGING_DIR)/share/maerxmppserver/licenses/libyaml-0.2.5.txt
	install -m 644 $(TC_WORK_DIR)/arm-unknown-linux-gnueabi/share/licenses/gcc/COPYING3 $(STAGING_DIR)/share/maerxmppserver/licenses/GPL-3.0.txt
	install -m 644 $(TC_WORK_DIR)/arm-unknown-linux-gnueabi/share/licenses/gcc/COPYING.RUNTIME $(STAGING_DIR)/share/maerxmppserver/licenses/GCC-Runtime-Library-Exception.txt
	install -m 644 src/libatomic-GCC-8.5.0-SOURCE.txt $(STAGING_DIR)/share/maerxmppserver/licenses/
	idna_notice=$$(find $(WORK_DIR) -path '*/_build/default/lib/idna/NOTICE' -type f -print -quit); test -n "$$idna_notice"; install -m 644 "$$idna_notice" $(STAGING_DIR)/share/maerxmppserver/licenses/idna-7.1.0-NOTICE.txt
	find $(STAGING_DIR) -type f -name '*.orig' -delete
	find $(STAGING_DIR) -depth -type d \( -name src -o -name c_src -o -name examples -o -name doc -o -name man -o -name include -o -name proper_ext -o -name emacs \) -exec rm -rf {} +
	find $(STAGING_DIR) -type f \( -name '*.a' -o -name '*.la' \) -delete
	find $(STAGING_DIR) -type f \( -name '*.erl' -o -name '*.hrl' -o -name '*.c' -o -name '*.h' -o -name '*.o' -o -name '*.src' \) -delete
	find $(STAGING_DIR) -type f \( -iname 'README*' -o -iname 'HOWTO*' -o -iname '*example*' \) -delete
	rm -rf $(STAGING_DIR)/etc
	rm -rf $(STAGING_DIR)/lib/erlang/usr
	rm -rf $(STAGING_DIR)/lib/erlang/misc
	rm -rf $(foreach application,$(OTP_DEVELOPMENT_APPLICATIONS),$(STAGING_DIR)/lib/erlang/lib/$(application)-*)
	test -f $(STAGING_DIR)/lib/erlang/releases/27/installed_application_versions
	sed -i -E '/^(common_test|dialyzer|edoc|erl_interface|eunit)-/d' $(STAGING_DIR)/lib/erlang/releases/27/installed_application_versions
	rm -f $(STAGING_DIR)/lib/erlang/Install
	rm -f $(STAGING_DIR)/lib/erlang/bin/start $(STAGING_DIR)/lib/erlang/bin/start_erl
	rm -f $(STAGING_DIR)/lib/erlang/erts-*/bin/start $(STAGING_DIR)/lib/erlang/releases/start_erl.data
	rm -rf $(STAGING_DIR)/lib/engines-3
	rm -rf $(STAGING_DIR)/lib/ossl-modules
	rm -rf $(STAGING_DIR)/share/terminfo
	rm -rf $(STAGING_DIR)/share/tabset
	rm -f $(STAGING_DIR)/bin/clear $(STAGING_DIR)/bin/infocmp $(STAGING_DIR)/bin/tabs
	rm -f $(STAGING_DIR)/bin/tic $(STAGING_DIR)/bin/toe $(STAGING_DIR)/bin/tput
	rm -f $(STAGING_DIR)/bin/tset $(STAGING_DIR)/bin/reset
	rm -f $(STAGING_DIR)/bin/captoinfo $(STAGING_DIR)/bin/infotocap
	rm -f $(STAGING_DIR)/bin/openssl $(STAGING_DIR)/bin/sqlite3
	rm -f $(STAGING_DIR)/lib/libformw.so* $(STAGING_DIR)/lib/libmenuw.so* $(STAGING_DIR)/lib/libpanelw.so*
	rm -f $(STAGING_DIR)/bin/ct_run $(STAGING_DIR)/bin/dialyzer $(STAGING_DIR)/bin/erlc
	rm -f $(STAGING_DIR)/bin/escript $(STAGING_DIR)/bin/run_erl $(STAGING_DIR)/bin/to_erl $(STAGING_DIR)/bin/typer
	rm -f $(STAGING_DIR)/lib/erlang/bin/ct_run $(STAGING_DIR)/lib/erlang/bin/dialyzer
	rm -f $(STAGING_DIR)/lib/erlang/bin/erl_call $(STAGING_DIR)/lib/erlang/bin/erlc
	rm -f $(STAGING_DIR)/lib/erlang/bin/escript $(STAGING_DIR)/lib/erlang/bin/run_erl
	rm -f $(STAGING_DIR)/lib/erlang/bin/to_erl $(STAGING_DIR)/lib/erlang/bin/typer
	rm -f $(STAGING_DIR)/lib/erlang/erts-*/bin/ct_run $(STAGING_DIR)/lib/erlang/erts-*/bin/dialyzer
	rm -f $(STAGING_DIR)/lib/erlang/erts-*/bin/dyn_erl $(STAGING_DIR)/lib/erlang/erts-*/bin/erl_call
	rm -f $(STAGING_DIR)/lib/erlang/erts-*/bin/erlc $(STAGING_DIR)/lib/erlang/erts-*/bin/escript
	rm -f $(STAGING_DIR)/lib/erlang/erts-*/bin/run_erl $(STAGING_DIR)/lib/erlang/erts-*/bin/to_erl
	rm -f $(STAGING_DIR)/lib/erlang/erts-*/bin/typer $(STAGING_DIR)/lib/erlang/erts-*/bin/yielding_c_fun
	rm -f $(STAGING_DIR)/lib/erlang/lib/crypto-*/priv/lib/otp_test_engine.so
	rm -f $(STAGING_DIR)/lib/erlang/lib/crypto-*/priv/lib/crypto_callback.so
	rm -f $(STAGING_DIR)/lib/erlang/lib/diameter-*/bin/diameterc
	rm -f $(STAGING_DIR)/lib/erlang/lib/snmp-*/bin/snmpc
	find $(STAGING_DIR) -depth -type d -empty -delete
	find $(STAGING_DIR) -type f -exec sh -c 'for runtime_file; do if "$(TC_PATH)$(TC_PREFIX)readelf" -h "$$runtime_file" >/dev/null 2>&1; then "$(TC_PATH)$(TC_PREFIX)strip" --strip-unneeded "$$runtime_file"; fi; done' sh {} +
	$(NATIVE_ERLANG_BIN_DIR)/erl -noshell -noinput -eval 'Root = "$(STAGING_DIR)", Files = lists:sort(filelib:fold_files(Root, ".*[.]beam$$", true, fun(File, Acc) -> [File | Acc] end, [])), case beam_lib:strip_files(Files) of {ok, Results} when length(Results) =:= length(Files) -> io:format("Stripped ~B BEAM files.~n", [length(Results)]); Error -> io:format(standard_error, "BEAM stripping failed: ~p~n", [Error]), erlang:halt(1) end, erlang:halt(0).'
	find $(STAGING_DIR) -type f -exec sh -c 'for runtime_file; do if patchelf --print-rpath "$$runtime_file" >/dev/null 2>&1; then patchelf --force-rpath --set-rpath "$(RUNTIME_RPATH)" "$$runtime_file"; fi; done' sh {} +
	test -x $(STAGING_DIR)/bin/ejabberdctl
	test -x $(STAGING_DIR)/bin/maer-upload-usage-check
	test -e $(STAGING_DIR)/bin/erl
	test -f $(STAGING_DIR)/lib/libcrypto.so.3
	test -f $(STAGING_DIR)/lib/libssl.so.3
	test -f $(STAGING_DIR)/lib/libsqlite3.so.0.8.6
	test -f $(STAGING_DIR)/lib/libncursesw.so.6.6
	test -f $(STAGING_DIR)/lib/libatomic.so.1.2.0
	test -f $(STAGING_DIR)/lib/ejabberd-26.07/ebin/mod_maer_pairing.beam
	test -f $(STAGING_DIR)/share/maerxmppserver/defaults/ejabberd.yml
	test -f $(STAGING_DIR)/share/maerxmppserver/licenses/GPL-3.0.txt
	test -f $(STAGING_DIR)/share/maerxmppserver/licenses/GCC-Runtime-Library-Exception.txt
	test -f $(STAGING_DIR)/share/maerxmppserver/licenses/libatomic-GCC-8.5.0-SOURCE.txt
	test -f $(STAGING_DIR)/share/maerxmppserver/licenses/idna-7.1.0-NOTICE.txt
	test -z "$$(find $(STAGING_DIR) -type f -name '*.orig' -print -quit)"
	test -z "$$(find $(STAGING_DIR) -type f \( -name '*.a' -o -name '*.la' \) -print -quit)"
	test -z "$$(find $(STAGING_DIR) -type f \( -name '*.erl' -o -name '*.hrl' -o -name '*.c' -o -name '*.h' -o -name '*.o' -o -name '*.src' \) -print -quit)"
	test -z "$$(find $(STAGING_DIR) -type f \( -iname 'README*' -o -iname 'HOWTO*' -o -iname '*example*' \) -print -quit)"
	test -z "$$(find $(STAGING_DIR) -type f -name '*.key' -print -quit)"
	test "$$(find $(STAGING_DIR) -type f -name '*.pem' -print | wc -l)" -eq 1
	test -f $(STAGING_DIR)/lib/pkix-*/priv/cacert.pem
	! grep -R -a -E -l -- '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' $(STAGING_DIR)
	! grep -R -a -F -l -- 'run_erl' $(STAGING_DIR)
	! grep -E -q '^(common_test|dialyzer|edoc|erl_interface|eunit)-' $(STAGING_DIR)/lib/erlang/releases/27/installed_application_versions
	! grep -R -a -F -l -- '$(SPKSRC_BUILD_ROOT)' $(STAGING_DIR)
	test -z "$$(find $(STAGING_DIR) -xtype l -print -quit)"
	find $(STAGING_DIR) -type f -exec sh -c 'for runtime_file; do runtime_dynamic=$$("$(TC_PATH)$(TC_PREFIX)readelf" -dW "$$runtime_file" 2>/dev/null) || continue; for needed_library in $$(printf "%s\n" "$$runtime_dynamic" | sed -n "s/.*(NEEDED).*\[\([^]]*\)\].*/\1/p"); do case " $(SYSTEM_NEEDED_LIBRARIES) " in *" $$needed_library "*) continue ;; esac; test -e "$(STAGING_DIR)/lib/$$needed_library" || { printf "%s: unresolved NEEDED library: %s\n" "$$runtime_file" "$$needed_library" >&2; exit 1; }; done; done' sh {} +
	find $(STAGING_DIR) -type f -exec sh -c 'for runtime_file; do if runtime_rpath=$$(patchelf --print-rpath "$$runtime_file" 2>/dev/null); then test "$$runtime_rpath" = "$(RUNTIME_RPATH)" || { printf "%s: non-canonical RPATH: %s\n" "$$runtime_file" "$$runtime_rpath" >&2; exit 1; }; fi; done' sh {} +
