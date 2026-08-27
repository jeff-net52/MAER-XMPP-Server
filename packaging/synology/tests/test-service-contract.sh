#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

set -eu

TESTS_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
SOURCE_SCRIPT="${TESTS_DIR}/../spksrc-overlay/spk/maerxmppserver/src/service-start-stop.sh"
SOURCE_SETUP="${TESTS_DIR}/../spksrc-overlay/spk/maerxmppserver/src/service-setup.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/maer-service-test.XXXXXX")
trap 'rm -rf "${TEST_ROOT}"' EXIT HUP INT TERM

export TEST_ROOT
export TEST_VAR="${TEST_ROOT}/var"
export MAER_CERTIFICATE_FILE="${TEST_VAR}/certs/xmpp.pem"
export MAER_CERTIFICATE_OWNER="$(id -un):$(id -gn)"
export TEST_LOG="${TEST_ROOT}/commands.log"
export TEST_RUNNING="${TEST_ROOT}/running"
export TEST_PID_FILE="${TEST_VAR}/run/ejabberd.pid"
export TEST_PARENT_PID=$$
export SYNOPKG_PKGNAME=maerxmppserver
export SYNOPKG_DSM_VERSION_MAJOR=7
export SYNOPKG_PKGDEST="${TEST_ROOT}/target"
export SYNOPKG_PKGVAR="${TEST_VAR}"

mkdir -p "${TEST_ROOT}/target/bin" "${TEST_ROOT}/scripts" "${TEST_VAR}/config" "${TEST_VAR}/certs" "${TEST_VAR}/run" "${TEST_VAR}/log"
cp "${SOURCE_SCRIPT}" "${TEST_ROOT}/scripts/start-stop-status"
chmod 755 "${TEST_ROOT}/scripts/start-stop-status"

cat > "${TEST_ROOT}/scripts/service-setup" <<'EOF_SETUP'
MAER_PACKAGE_ROOT="${TEST_ROOT}"
MAER_VAR_DIR="${TEST_VAR}"
EJABBERD_CTL="${TEST_ROOT}/target/bin/ejabberdctl"
EJABBERD_ERL="${TEST_ROOT}/target/bin/erl"
EJABBERD_CONFIG_PATH="${TEST_VAR}/config/ejabberd.yml"
EJABBERD_LOG_PATH="${TEST_VAR}/log/ejabberd.log"
PID_FILE="${TEST_PID_FILE}"
LOG_FILE="${EJABBERD_LOG_PATH}"
export MAER_PACKAGE_ROOT MAER_VAR_DIR EJABBERD_CTL EJABBERD_ERL
export EJABBERD_CONFIG_PATH EJABBERD_LOG_PATH PID_FILE LOG_FILE
EOF_SETUP
chmod 600 "${TEST_ROOT}/scripts/service-setup"

cat > "${TEST_ROOT}/target/bin/ss" <<'EOF_SS'
#!/bin/sh
[ "${TEST_SS_FAIL:-0}" -eq 0 ] || exit 1
if [ "${TEST_SS_INVALID:-0}" -ne 0 ]; then
    printf '%s\n' 'unsupported listener output'
    exit 0
fi
printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port'
if [ -n "${TEST_OCCUPIED_PORT:-}" ]; then
    printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "${TEST_OCCUPIED_PORT}"
fi
EOF_SS

cat > "${TEST_ROOT}/target/bin/erl" <<'EOF_ERL'
#!/bin/sh
printf '%s\n' config-check >> "${TEST_LOG}"
[ "${TEST_CONFIG_FAIL:-0}" -eq 0 ]
EOF_ERL

cat > "${TEST_ROOT}/target/bin/stat" <<'EOF_STAT'
#!/bin/sh
if [ "${1:-}" = '-c' ] && [ "${2:-}" = '%a' ]; then printf '%s\n' "${TEST_CERT_MODE:-640}"; exit 0; fi
if [ "${1:-}" = '-c' ] && [ "${2:-}" = '%U:%G' ]; then printf '%s\n' "${MAER_CERTIFICATE_OWNER}"; exit 0; fi
exit 1
EOF_STAT

cat > "${TEST_ROOT}/target/bin/ejabberdctl" <<'EOF_CTL'
#!/bin/sh
command_name=${1:-}
printf '%s\n' "${command_name}" >> "${TEST_LOG}"
case "${command_name}" in
    status)
        [ -f "${TEST_RUNNING}" ]
        ;;
    start)
        : > "${TEST_RUNNING}"
        printf '%s\n' "${TEST_PARENT_PID}" > "${TEST_PID_FILE}"
        ;;
    started)
        [ "${TEST_FAIL_READY:-0}" -eq 0 ]
        ;;
    stop)
        rm -f "${TEST_RUNNING}"
        ;;
    stopped)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF_CTL

chmod 755 "${TEST_ROOT}/target/bin/ss" "${TEST_ROOT}/target/bin/erl" "${TEST_ROOT}/target/bin/stat" "${TEST_ROOT}/target/bin/ejabberdctl"
printf '%s\n' 'hosts: [xmpp.maer.fr]' > "${TEST_VAR}/config/ejabberd.yml"
printf '%s\n' 'test certificate fixture' > "${TEST_VAR}/certs/xmpp.pem"
chmod 600 "${TEST_VAR}/config/ejabberd.yml"
chmod 640 "${TEST_VAR}/certs/xmpp.pem"

reset_case()
{
    : > "${TEST_LOG}"
    rm -f "${TEST_RUNNING}" "${TEST_PID_FILE}"
    unset TEST_OCCUPIED_PORT TEST_CONFIG_FAIL TEST_FAIL_READY TEST_SS_FAIL TEST_SS_INVALID TEST_CERT_MODE || true
}

fail_test()
{
    echo "service contract test failed: $*" >&2
    exit 1
}

reset_case
export TEST_OCCUPIED_PORT=5222
if "${TEST_ROOT}/scripts/start-stop-status" start >"${TEST_ROOT}/occupied.out" 2>&1; then
    fail_test 'occupied port was accepted'
fi
if ! grep -q 'TCP port 5222 is already occupied' "${TEST_ROOT}/occupied.out"; then
    sed 's/^/service output: /' "${TEST_ROOT}/occupied.out" >&2
    fail_test 'occupied-port error is missing'
fi
if grep -q '^start$' "${TEST_LOG}"; then
    fail_test 'ejabberd was started despite an occupied port'
fi

reset_case
export TEST_SS_FAIL=1
if "${TEST_ROOT}/scripts/start-stop-status" start >"${TEST_ROOT}/listener-failed.out" 2>&1; then
    fail_test 'listener inspection failure was accepted'
fi
grep -q 'cannot inspect TCP listeners; refusing to start' "${TEST_ROOT}/listener-failed.out" || fail_test 'listener failure did not fail closed'
if grep -q '^start$' "${TEST_LOG}"; then
    fail_test 'ejabberd was started without a listener inspection'
fi

reset_case
export TEST_CONFIG_FAIL=1
if "${TEST_ROOT}/scripts/start-stop-status" start >"${TEST_ROOT}/config-failed.out" 2>&1; then
    fail_test 'invalid configuration was accepted'
fi
grep -q 'configuration validation failed' "${TEST_ROOT}/config-failed.out" || fail_test 'configuration error is missing'
if grep -q '^start$' "${TEST_LOG}"; then
    fail_test 'ejabberd was started with an invalid configuration'
fi

reset_case
export TEST_CERT_MODE=644
if "${TEST_ROOT}/scripts/start-stop-status" start >"${TEST_ROOT}/certificate-mode.out" 2>&1; then
    fail_test 'weak certificate permissions were accepted'
fi
grep -q 'TLS certificate permissions must be 0640' "${TEST_ROOT}/certificate-mode.out" || fail_test 'certificate mode error is missing'

reset_case
"${TEST_ROOT}/scripts/start-stop-status" start >"${TEST_ROOT}/start.out" 2>&1 || fail_test 'clean start failed'
grep -q '^config-check$' "${TEST_LOG}" || fail_test 'configuration was not checked'
grep -q '^start$' "${TEST_LOG}" || fail_test 'start command was not issued'
grep -q '^started$' "${TEST_LOG}" || fail_test 'readiness wait was not issued'
"${TEST_ROOT}/scripts/start-stop-status" status >"${TEST_ROOT}/running.out" 2>&1 || fail_test 'running status failed'
"${TEST_ROOT}/scripts/start-stop-status" stop >"${TEST_ROOT}/stop.out" 2>&1 || fail_test 'graceful stop failed'
grep -q '^stop$' "${TEST_LOG}" || fail_test 'stop command was not issued'
grep -q '^stopped$' "${TEST_LOG}" || fail_test 'stopped wait was not issued'
set +e
"${TEST_ROOT}/scripts/start-stop-status" status >"${TEST_ROOT}/stopped.out" 2>&1
status_code=$?
set -e
[ "${status_code}" -eq 3 ] || fail_test 'stopped status must return 3'

reset_case
export TEST_FAIL_READY=1
if "${TEST_ROOT}/scripts/start-stop-status" start >"${TEST_ROOT}/not-ready.out" 2>&1; then
    fail_test 'readiness failure was accepted'
fi
grep -q '^stop$' "${TEST_LOG}" || fail_test 'failed start did not request graceful cleanup'
if grep -q 'kill -9' "${TEST_LOG}"; then
    fail_test 'hard kill fallback was used'
fi

clean_install_var="${TEST_ROOT}/clean-install-var"
mkdir -p "${clean_install_var}"
(
    . "${SOURCE_SETUP}"
    MAER_VAR_DIR="${clean_install_var}"
    CONFIG_DIR="${clean_install_var}/config"
    wizard_smtp_password='TestOnly-Clean-Smtp-42'
    validate_preinst
) || fail_test 'empty package data directory was rejected'

missing_secret_var="${TEST_ROOT}/missing-secret-var"
mkdir -p "${missing_secret_var}"
if (
    . "${SOURCE_SETUP}"
    MAER_VAR_DIR="${missing_secret_var}"
    CONFIG_DIR="${missing_secret_var}/config"
    unset wizard_smtp_password || true
    validate_preinst
) >"${TEST_ROOT}/missing-secret.out" 2>&1
then
    fail_test 'clean installation accepted a missing SMTP password'
fi
grep -q 'portal SMTP password is required' "${TEST_ROOT}/missing-secret.out" || fail_test 'missing SMTP password refusal is not explicit'

short_secret_var="${TEST_ROOT}/short-secret-var"
mkdir -p "${short_secret_var}"
if (
    . "${SOURCE_SETUP}"
    MAER_VAR_DIR="${short_secret_var}"
    CONFIG_DIR="${short_secret_var}/config"
    wizard_smtp_password='too-short'
    validate_preinst
) >"${TEST_ROOT}/short-secret.out" 2>&1
then
    fail_test 'clean installation accepted a short SMTP password'
fi
grep -q 'SMTP password is too short' "${TEST_ROOT}/short-secret.out" || fail_test 'short SMTP password refusal is not explicit'

mkdir -p "${clean_install_var}/config"
printf '%s\n' 'legacy profile fixture' > "${clean_install_var}/config/ejabberd.yml"
if (
    . "${SOURCE_SETUP}"
    MAER_VAR_DIR="${clean_install_var}"
    validate_preinst
) >"${TEST_ROOT}/retained-data.out" 2>&1
then
    fail_test 'retained package state was accepted by a clean installation'
fi
grep -q 'requires an empty package data directory' "${TEST_ROOT}/retained-data.out" || fail_test 'retained-data refusal is not explicit'

upgrade_var="${TEST_ROOT}/upgrade-var"
upgrade_defaults="${TEST_ROOT}/upgrade-defaults"
mkdir -p "${upgrade_var}/config" "${upgrade_var}/data" "${upgrade_var}/log" \
    "${upgrade_var}/run" "${upgrade_var}/upload" "${upgrade_var}/certs" \
    "${upgrade_defaults}"
printf '%s\n' 'revision-8-profile' > "${upgrade_var}/config/ejabberd.yml"
printf '%s\n' 'revision-8-control' > "${upgrade_var}/config/ejabberdctl.cfg"
printf '%s\n' 'revision-8-inet' > "${upgrade_var}/config/inetrc"
printf '%s\n' 'account-database-marker' > "${upgrade_var}/data/ejabberd.sqlite"
printf '%s\n' 'revision-9-profile' > "${upgrade_defaults}/ejabberd.yml"
printf '%s\n' 'revision-9-control' > "${upgrade_defaults}/ejabberdctl.cfg"
printf '%s\n' 'revision-9-inet' > "${upgrade_defaults}/inetrc"

(
    . "${SOURCE_SETUP}"
    SYNOPKG_OLD_PKGVER=26.07.0-8
    MAER_VAR_DIR="${upgrade_var}"
    MAER_DEFAULTS_DIR="${upgrade_defaults}"
    CONFIG_DIR="${upgrade_var}/config"
    LOGS_DIR="${upgrade_var}/log"
    SPOOL_DIR="${upgrade_var}/data"
    wizard_smtp_password='TestOnly-Smtp-Secret-42'
    export SYNOPKG_OLD_PKGVER MAER_VAR_DIR MAER_DEFAULTS_DIR CONFIG_DIR LOGS_DIR SPOOL_DIR wizard_smtp_password
    validate_preupgrade
    service_postupgrade
) >"${TEST_ROOT}/upgrade.out" 2>&1 || {
    sed 's/^/upgrade output: /' "${TEST_ROOT}/upgrade.out" >&2
    fail_test 'validated revision-8 upgrade failed'
}

grep -q '^revision-9-profile$' "${upgrade_var}/config/ejabberd.yml" || fail_test 'upgrade profile was not refreshed'
grep -q '^revision-8-profile$' "${upgrade_var}/config/ejabberd.yml.pre-26.07.0-9" || fail_test 'revision-8 profile backup is missing'
grep -q '^revision-9-control$' "${upgrade_var}/config/ejabberdctl.cfg" || fail_test 'control defaults were not refreshed'
grep -q '^revision-9-inet$' "${upgrade_var}/config/inetrc" || fail_test 'inet defaults were not refreshed'
grep -q '^account-database-marker$' "${upgrade_var}/data/ejabberd.sqlite" || fail_test 'account database changed during upgrade'
[ "$(stat -c '%a' "${upgrade_var}/config/ejabberd.yml")" = '600' ] || fail_test 'upgraded profile permissions are not 0600'
grep -q '^TestOnly-Smtp-Secret-42$' "${upgrade_var}/config/smtp-password" || fail_test 'SMTP password was not installed'
[ "$(stat -c '%a' "${upgrade_var}/config/smtp-password")" = '600' ] || fail_test 'SMTP password permissions are not 0600'
if grep -q 'TestOnly-Smtp-Secret-42' "${TEST_ROOT}/upgrade.out"; then
    fail_test 'SMTP password leaked into upgrade output'
fi

existing_secret_var="${TEST_ROOT}/existing-secret-var"
mkdir -p "${existing_secret_var}/config"
printf '%s\n' 'Existing-Smtp-Secret-42' > "${existing_secret_var}/config/smtp-password"
chmod 644 "${existing_secret_var}/config/smtp-password"
(
    . "${SOURCE_SETUP}"
    CONFIG_DIR="${existing_secret_var}/config"
    unset wizard_smtp_password || true
    install_smtp_password
) || fail_test 'existing SMTP secret was not preserved'
grep -q '^Existing-Smtp-Secret-42$' "${existing_secret_var}/config/smtp-password" || fail_test 'existing SMTP secret changed'
[ "$(stat -c '%a' "${existing_secret_var}/config/smtp-password")" = '600' ] || fail_test 'existing SMTP secret mode was not corrected to 0600'

unsafe_upgrade_var="${TEST_ROOT}/unsafe-upgrade-var"
mkdir -p "${unsafe_upgrade_var}/config" "${unsafe_upgrade_var}/data"
printf '%s\n' 'profile' > "${unsafe_upgrade_var}/config/ejabberd.yml"
printf '%s\n' 'control' > "${unsafe_upgrade_var}/config/ejabberdctl.cfg"
mkdir "${unsafe_upgrade_var}/config/inetrc"
if (
    . "${SOURCE_SETUP}"
    SYNOPKG_OLD_PKGVER=26.07.0-8
    MAER_VAR_DIR="${unsafe_upgrade_var}"
    CONFIG_DIR="${unsafe_upgrade_var}/config"
    wizard_smtp_password='TestOnly-Unsafe-Smtp-42'
    export SYNOPKG_OLD_PKGVER MAER_VAR_DIR CONFIG_DIR wizard_smtp_password
    validate_preupgrade
) >"${TEST_ROOT}/unsafe-upgrade.out" 2>&1
then
    fail_test 'unsafe installed configuration was accepted'
fi
grep -q 'configuration is missing or unsafe' "${TEST_ROOT}/unsafe-upgrade.out" || fail_test 'unsafe configuration refusal is not explicit'

if (
    . "${SOURCE_SETUP}"
    SYNOPKG_OLD_PKGVER=26.07.0-7
    MAER_VAR_DIR="${upgrade_var}"
    CONFIG_DIR="${upgrade_var}/config"
    export SYNOPKG_OLD_PKGVER MAER_VAR_DIR CONFIG_DIR
    validate_preupgrade
) >"${TEST_ROOT}/unsupported-upgrade.out" 2>&1
then
    fail_test 'unsupported source revision was accepted'
fi
grep -q 'only supports an in-place upgrade from 26.07.0-8' "${TEST_ROOT}/unsupported-upgrade.out" || fail_test 'unsupported-upgrade refusal is not explicit'

echo 'service contract tests passed'
