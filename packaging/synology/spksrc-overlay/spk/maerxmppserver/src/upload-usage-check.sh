#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

set -eu

UPLOAD_DIR=${MAER_UPLOAD_DIR:-/var/packages/maerxmppserver/var/upload}
WARN_PERCENT=${MAER_UPLOAD_FS_WARN_PERCENT:-80}
CRITICAL_PERCENT=${MAER_UPLOAD_FS_CRITICAL_PERCENT:-90}
DU_COMMAND=${MAER_DU_COMMAND:-du}
DF_COMMAND=${MAER_DF_COMMAND:-df}

fail()
{
    echo "maer_upload_monitor_status=unknown error=$*" >&2
    exit 3
}

case "${WARN_PERCENT}:${CRITICAL_PERCENT}" in
    *[!0-9:]*|:*|*:) fail "thresholds must be integers" ;;
esac
[ "${WARN_PERCENT}" -gt 0 ] || fail "warning threshold must be positive"
[ "${CRITICAL_PERCENT}" -le 100 ] || fail "critical threshold must not exceed 100"
[ "${WARN_PERCENT}" -lt "${CRITICAL_PERCENT}" ] || fail "warning threshold must be below critical threshold"

[ -d "${UPLOAD_DIR}" ] || fail "upload directory is unavailable"
[ ! -L "${UPLOAD_DIR}" ] || fail "upload directory must not be a symbolic link"

usage_kib=$("${DU_COMMAND}" -sk "${UPLOAD_DIR}" | awk 'NR == 1 { print $1 }') || fail "cannot measure upload usage"
filesystem_percent=$("${DF_COMMAND}" -Pk "${UPLOAD_DIR}" | awk 'NR == 2 { value = $5; gsub(/%/, "", value); print value }') || fail "cannot measure filesystem usage"

case "${usage_kib}:${filesystem_percent}" in
    *[!0-9:]*) fail "monitor commands returned invalid metrics" ;;
esac

usage_mib=$(( (usage_kib + 1023) / 1024 ))
status=ok
exit_code=0
if [ "${filesystem_percent}" -ge "${CRITICAL_PERCENT}" ]; then
    status=critical
    exit_code=2
elif [ "${filesystem_percent}" -ge "${WARN_PERCENT}" ]; then
    status=warning
    exit_code=1
fi

printf 'maer_upload_usage_mib=%s filesystem_used_percent=%s status=%s\n' \
    "${usage_mib}" "${filesystem_percent}" "${status}"
exit "${exit_code}"
