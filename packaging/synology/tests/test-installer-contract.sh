#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

set -eu

TESTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PATCH_FILE="${TESTS_DIR}/../spksrc-overlay/spk/maerxmppserver/src/installer-fail-closed.patch"
TEST_ROOT=$(mktemp -d)
TEST_LOG="${TEST_ROOT}/installer.log"
export TEST_LOG

cleanup()
{
    rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT HUP INT TERM

fail_test()
{
    echo "installer contract failure: $*" >&2
    exit 1
}

command -v patch >/dev/null 2>&1 || fail_test 'patch command is unavailable'
[ -f "${PATCH_FILE}" ] && [ ! -L "${PATCH_FILE}" ] || fail_test 'reviewed installer patch is missing or unsafe'

cat > "${TEST_ROOT}/installer" <<'INSTALLER_EOF'
#!/bin/sh

install_log ()
{
    if [ "$#" -eq 0 ]; then
        while IFS= read -r line; do
            printf '%s\n' "${line}" >> "${TEST_LOG}"
        done
    else
        printf '%s\n' "$*" >> "${TEST_LOG}"
    fi
}

# Invoke shell function if available
call_func ()
{
    FUNC=$1
    if type "${FUNC}" 2>/dev/null | grep -q 'function' 2>/dev/null; then
        install_log "Begin ${FUNC}"
        LOG=$2
        ARG=$3
        if [ -z "${LOG}" ]; then
            if [ -z "${ARG}" ]; then
                eval ${FUNC}
            else
                eval ${FUNC} ${ARG}
            fi
        else
            if [ -z "${ARG}" ]; then
                eval ${FUNC} 2>&1 | ${LOG}
            else
                eval ${FUNC} ${ARG} 2>&1 | ${LOG}
            fi
        fi
        install_log "End ${FUNC}"
    fi
}
INSTALLER_EOF

patch --batch --forward --fuzz=0 --no-backup-if-mismatch \
    -d "${TEST_ROOT}" -p0 < "${PATCH_FILE}" >/dev/null || fail_test 'reviewed installer patch no longer applies exactly'
sh -n "${TEST_ROOT}/installer" || fail_test 'patched installer has invalid shell syntax'

run_hook_test()
{
    hook_name=$1
    expected_status=$2
    observed_status=0
    if (
        . "${TEST_ROOT}/installer"
        hook_success()
        {
            echo 'success-marker'
            return 0
        }
        hook_return()
        {
            echo 'return-marker'
            return 37
        }
        hook_exit()
        {
            echo 'exit-marker'
            exit 38
        }
        call_func "${hook_name}" install_log ''
    ) >/dev/null 2>&1
    then
        observed_status=0
    else
        observed_status=$?
    fi
    [ "${observed_status}" -eq "${expected_status}" ] || fail_test "${hook_name} returned ${observed_status}, expected ${expected_status}"
}

run_hook_test hook_success 0
run_hook_test hook_return 37
run_hook_test hook_exit 38

grep -q '^success-marker$' "${TEST_LOG}" || fail_test 'successful hook output was not logged'
grep -q '^return-marker$' "${TEST_LOG}" || fail_test 'returning hook output was not logged'
grep -q '^exit-marker$' "${TEST_LOG}" || fail_test 'exiting hook output was not logged'
grep -q '^Failed hook_return (status 37)$' "${TEST_LOG}" || fail_test 'returning hook failure was not identified'
grep -q '^Failed hook_exit (status 38)$' "${TEST_LOG}" || fail_test 'exiting hook failure was not identified'

echo 'installer lifecycle contract tests passed'
