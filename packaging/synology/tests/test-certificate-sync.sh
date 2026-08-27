#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $(uname -s) != Linux ]]; then echo 'certificate sync tests skipped: Linux required'; exit 0; fi
if ! command -v openssl >/dev/null 2>&1; then echo 'certificate sync tests skipped: openssl unavailable'; exit 0; fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/operator/maer-certificate-sync"
script_text=$(cat "$script")
case "$script_text" in *"root requires an explicit DSM certificate archive id"*) :;; *) echo 'certificate sync test failed: root must reject automatic certificate selection' >&2; exit 1;; esac
case "$script_text" in *'certificate root permissions must be exactly 0755'*) :;; *) echo 'certificate sync test failed: certificate root traversal contract is missing' >&2; exit 1;; esac
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
archive="$tmp/archive"; destination="$tmp/certroot/xmpp.pem"; mkdir -p "$archive"
make_cert() {
  local name=$1 days=$2 san=$3
  mkdir -p "$archive/$name"
  openssl req -x509 -newkey rsa:2048 -nodes -days "$days" -subj "/CN=$san" \
    -addext "subjectAltName=DNS:$san" -keyout "$archive/$name/privkey.pem" \
    -out "$archive/$name/cert.pem" >/dev/null 2>&1
  cp "$archive/$name/cert.pem" "$archive/$name/fullchain.pem"
}
make_cert old 10 xmpp.maer.fr
make_cert newest 30 xmpp.maer.fr
make_cert near_expiry 1 xmpp.maer.fr
make_cert wrong_san 90 wrong.example
make_cert wrong_key 60 xmpp.maer.fr
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$archive/wrong_key/privkey.pem" >/dev/null 2>&1
make_cert symlink_target 120 xmpp.maer.fr
mv "$archive/symlink_target" "$tmp/symlink_target"
ln -s "$tmp/symlink_target" "$archive/zz_symlink"
restart_log="$tmp/restart.log"
synopkg_down="$tmp/synopkg-down"; printf '#!/bin/sh\n[ "$1" = status ] && exit 17\nprintf "restart\\n" >>"%s"\n' "$restart_log" >"$synopkg_down"; chmod 755 "$synopkg_down"
synopkg_up="$tmp/synopkg-up"; printf '#!/bin/sh\n[ "$1" = status ] && exit 0\nprintf "restart\\n" >>"%s"\n' "$restart_log" >"$synopkg_up"; chmod 755 "$synopkg_up"
common=(MAER_ALLOW_NON_ROOT=1 MAER_SKIP_LIVE_PROBE=1 MAER_CERT_ARCHIVE="$archive" MAER_CERT_ARCHIVE_ID=auto MAER_CERT_DESTINATION="$destination"
  MAER_CERT_STATE_DIR="$tmp/state" MAER_OPENSSL="$(command -v openssl)" MAER_CHOWN=/bin/true MAER_CERT_OWNER=test:test MAER_CERT_DIR_OWNER=test:test)

env "${common[@]}" MAER_SYNOPKG="$synopkg_down" bash "$script" >/dev/null
test "$(stat -c '%a' "${destination%/*}")" = 750
test "$(stat -c '%a' "$destination")" = 640
actual=$(openssl x509 -in "$destination" -noout -fingerprint -sha256)
expected=$(openssl x509 -in "$archive/newest/cert.pem" -noout -fingerprint -sha256)
test "$actual" = "$expected"; test ! -e "$restart_log"

env "${common[@]}" MAER_SYNOPKG="$synopkg_up" bash "$script" >/dev/null
test ! -e "$restart_log"

make_cert replacement 45 xmpp.maer.fr
env "${common[@]}" MAER_SYNOPKG="$synopkg_up" bash "$script" >/dev/null
test "$(wc -l <"$restart_log")" -eq 1
before=$(sha256sum "$destination")

restart_fail_once="$tmp/restart-fail-once"
printf '#!/bin/sh\n[ "$1" = status ] && exit 0\nprintf "restart\\n" >>"%s"\ncount=$(wc -l <"%s")\n[ "$count" -gt 2 ]\n' "$restart_log" "$restart_log" >"$restart_fail_once"; chmod 755 "$restart_fail_once"
make_cert replacement2 60 xmpp.maer.fr
if env "${common[@]}" MAER_SYNOPKG="$restart_fail_once" bash "$script" >/dev/null 2>&1; then
  echo 'restart failure was not rejected' >&2; exit 1
fi
test "$before" = "$(sha256sum "$destination")"
test "$(wc -l <"$restart_log")" -eq 3
echo 'certificate sync tests passed'
