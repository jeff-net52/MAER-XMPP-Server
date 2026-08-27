#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
helper=$root/operator/maer-bootstrap-admin
installer=$root/operator/install-bootstrap-admin-root
server=$root/../../src/mod_maer_pairing.erl
fail() { echo "bootstrap admin test failed: $*" >&2; exit 1; }
sh -n "$helper" "$installer" || fail 'shell syntax'
text=$(cat "$helper")
case "$text" in *'tty_state=$(stty -g)'*'restore_tty; cleanup_lock'*) :;; *) fail 'TTY restoration contract';; esac
case "$text" in *'Bootstrap = fun() -> R(mod_maer_pairing,operator_bootstrap_admin,[P]) end'*'{badrpc,timeout}'*'registration_timeout_manual_inspection_required'*) :;; *) fail 'idempotent remote transaction/reconciliation contract';; esac
case "$text" in *'false = R(ejabberd_auth,user_exists'*) fail 'bootstrap must permit safe reconciliation of an existing matching admin';; esac
case "$text" in *'maer-cutover-'*|*'try_register,[X,H,TP]'*) fail 'production helper must not create test accounts';; esac
server_text=$(cat "$server")
case "$server_text" in *'operator_bootstrap_admin(Password)'*'verify_existing_admin(User, Host, Password)'*'ejabberd_auth:try_register(User, Host, Password)'*'ejabberd_auth:remove_user(User, Host)'*) :;; *) fail 'idempotent remote bootstrap/rollback contract';; esac
case "$text" in *'env -i '*'ERL_CRASH_DUMP=/dev/null'*'-dist_listen false'*) :;; *) fail 'sanitized Erlang launch contract';; esac
installer_text=$(cat "$installer")
case "$installer_text" in *'trap cleanup EXIT'*"exit 129"*"exit 130"*"exit 143"*) :;; *) fail 'installer signal cleanup contract';; esac
expected=$(sed -n 's/^EXPECTED_SHA256=//p' "$installer")
actual=$(sha256sum "$helper" | awk '{print $1}')
[ "$expected" = "$actual" ] || fail 'installer pin mismatch'
echo 'bootstrap admin tests passed'
