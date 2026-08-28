#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

set -eu

TESTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
DEFAULT_RECIPE_FILE="${TESTS_DIR}/../spksrc-overlay/spk/maerxmppserver/Makefile"
if [ "$#" -gt 1 ]; then
    echo 'usage: test-installer-recipe-order.sh [recipe-makefile]' >&2
    exit 2
fi
RECIPE_FILE=${1:-${DEFAULT_RECIPE_FILE}}
PATCH_FILE="${TESTS_DIR}/../spksrc-overlay/spk/maerxmppserver/src/installer-fail-closed.patch"
TEST_ROOT=$(mktemp -d)

cleanup()
{
    rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT HUP INT TERM

fail_test()
{
    echo "installer recipe order failure: $*" >&2
    exit 1
}

command -v make >/dev/null 2>&1 || fail_test 'GNU make is unavailable'
command -v patch >/dev/null 2>&1 || fail_test 'patch command is unavailable'
[ -f "${RECIPE_FILE}" ] && [ ! -L "${RECIPE_FILE}" ] || fail_test 'SPK recipe is missing or unsafe'
[ -f "${PATCH_FILE}" ] && [ ! -L "${PATCH_FILE}" ] || fail_test 'reviewed installer patch is missing or unsafe'

mkdir -p "${TEST_ROOT}/mk" "${TEST_ROOT}/spk/maerxmppserver/src"
cp "${RECIPE_FILE}" "${TEST_ROOT}/spk/maerxmppserver/Makefile"
cp "${PATCH_FILE}" "${TEST_ROOT}/spk/maerxmppserver/src/installer-fail-closed.patch"

cat > "${TEST_ROOT}/spk/maerxmppserver/fixture-installer" <<'INSTALLER_EOF'
#!/bin/sh

install_log ()
{
    :
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

# This minimal include reproduces the relevant spksrc graph: service_target
# creates SERVICE_FILES, while the generic installer is another final-package
# dependency and may be generated in parallel.  The MAER post-service target
# must therefore depend on the installer explicitly before patching it.
cat > "${TEST_ROOT}/mk/spksrc.spk.mk" <<'SPKSRC_EOF'
DSM_SCRIPTS_DIR := $(CURDIR)/work/scripts

$(POST_SERVICE_TARGET): service_target

.PHONY: service_target
service_target: $(DSM_SCRIPTS_DIR)/service-setup

$(DSM_SCRIPTS_DIR)/service-setup:
	@mkdir -p $(@D)
	@printf '%s\n' '#!/bin/sh' 'exit 0' > $@
	@chmod 755 $@

$(DSM_SCRIPTS_DIR)/installer:
	@mkdir -p $(@D)
	@cp $(CURDIR)/fixture-installer $@
	@chmod 755 $@
SPKSRC_EOF

BUILD_LOG="${TEST_ROOT}/make.log"
if ! make -j2 -C "${TEST_ROOT}/spk/maerxmppserver" maerxmppserver_service_finalize >"${BUILD_LOG}" 2>&1; then
    cat "${BUILD_LOG}" >&2
    fail_test 'POST_SERVICE_TARGET ran before the generated installer was available'
fi

GENERATED_INSTALLER="${TEST_ROOT}/spk/maerxmppserver/work/scripts/installer"
[ -f "${GENERATED_INSTALLER}" ] || fail_test 'recipe did not generate the DSM installer'
grep -F -q 'FUNC_STATUS=0' "${GENERATED_INSTALLER}" || fail_test 'generated installer was not patched'
grep -F -q 'exit "${FUNC_STATUS}"' "${GENERATED_INSTALLER}" || fail_test 'generated installer does not propagate lifecycle hook status'
! grep -F -q 'eval ${FUNC} 2>&1 | ${LOG}' "${GENERATED_INSTALLER}" || fail_test 'generated installer still masks lifecycle hook failures'

echo 'installer recipe generation-order test passed'
