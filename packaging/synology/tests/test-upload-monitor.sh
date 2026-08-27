#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

set -eu

TESTS_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
MONITOR_SCRIPT="${TESTS_DIR}/../spksrc-overlay/spk/maerxmppserver/src/upload-usage-check.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/maer-upload-monitor-test.XXXXXX")
trap 'rm -rf "${TEST_ROOT}"' EXIT HUP INT TERM

mkdir -p "${TEST_ROOT}/upload" "${TEST_ROOT}/bin"

cat > "${TEST_ROOT}/bin/du" <<'EOF_DU'
#!/bin/sh
printf '%s\t%s\n' "${TEST_USAGE_KIB:-2048}" "${2:-upload}"
EOF_DU

cat > "${TEST_ROOT}/bin/df" <<'EOF_DF'
#!/bin/sh
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '/dev/test 100000 50000 50000 %s%% /volume-test\n' "${TEST_DF_PERCENT:-50}"
EOF_DF
chmod 755 "${TEST_ROOT}/bin/du" "${TEST_ROOT}/bin/df"

export MAER_UPLOAD_DIR="${TEST_ROOT}/upload"
export MAER_DU_COMMAND="${TEST_ROOT}/bin/du"
export MAER_DF_COMMAND="${TEST_ROOT}/bin/df"

fail_test()
{
    echo "upload monitor test failed: $*" >&2
    exit 1
}

run_case()
{
    expected_code=$1
    expected_status=$2
    export TEST_DF_PERCENT=$3
    set +e
    output=$("${MONITOR_SCRIPT}" 2>&1)
    actual_code=$?
    set -e
    [ "${actual_code}" -eq "${expected_code}" ] || fail_test "expected exit ${expected_code}, got ${actual_code}: ${output}"
    printf '%s\n' "${output}" | grep -q "status=${expected_status}" || fail_test "missing ${expected_status} status"
}

run_case 0 ok 79
run_case 1 warning 80
run_case 2 critical 90

MAER_UPLOAD_DIR="${TEST_ROOT}/missing"; export MAER_UPLOAD_DIR
set +e
missing_output=$("${MONITOR_SCRIPT}" 2>&1)
missing_code=$?
set -e
[ "${missing_code}" -eq 3 ] || fail_test "missing directory must return 3"
printf '%s\n' "${missing_output}" | grep -q 'status=unknown' || fail_test "missing directory status is not unknown"

echo 'upload monitor tests passed'
