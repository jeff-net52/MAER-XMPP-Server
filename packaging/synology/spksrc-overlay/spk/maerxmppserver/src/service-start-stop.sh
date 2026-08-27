#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

set -eu

DNAME="${SYNOPKG_PKGNAME:-maerxmppserver}"
SVC_SETUP="$(dirname "$0")/service-setup"

if [ ! -r "${SVC_SETUP}" ] || [ -L "${SVC_SETUP}" ]; then
    echo "${DNAME}: service setup is unavailable" >&2
    exit 1
fi
. "${SVC_SETUP}"

PATH="${MAER_PACKAGE_ROOT}/target/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
export PATH

fail()
{
    echo "${DNAME}: $*" >&2
    exit 1
}

daemon_status()
{
    if [ ! -f "${PID_FILE}" ] || [ -L "${PID_FILE}" ]; then
        return 1
    fi

    daemon_pid=$(sed -n '1p' "${PID_FILE}" 2>/dev/null || true)
    case "${daemon_pid}" in
        ''|*[!0-9]*) return 1 ;;
    esac

    kill -0 "${daemon_pid}" 2>/dev/null || return 1
    "${EJABBERD_CTL}" status >/dev/null 2>&1
}

node_status()
{
    [ -x "${EJABBERD_CTL}" ] || return 1
    "${EJABBERD_CTL}" status >/dev/null 2>&1
}

listener_snapshot()
{
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null
    else
        return 1
    fi
}

assert_ports_available()
{
    if ! listeners=$(listener_snapshot); then
        fail "cannot inspect TCP listeners; refusing to start"
    fi
    case "${listeners}" in
        *"Local Address"*) ;;
        *) fail "unrecognized TCP listener output; refusing to start" ;;
    esac

    for service_port in 5211 5222 5280 5443
    do
        if printf '%s\n' "${listeners}" | awk -v port="${service_port}" '
            NR > 1 {
                local_address = $4
                if (local_address ~ (":" port "$")) {
                    found = 1
                }
            }
            END { exit(found ? 0 : 1) }
        '
        then
            fail "TCP port ${service_port} is already occupied; no process was stopped"
        fi
    done
}

assert_runtime_files()
{
    [ -x "${EJABBERD_CTL}" ] || fail "ejabberdctl is not executable"
    [ -x "${EJABBERD_ERL}" ] || fail "Erlang runtime is not executable"
    [ -f "${EJABBERD_CONFIG_PATH}" ] || fail "configuration file is missing"
    [ ! -L "${EJABBERD_CONFIG_PATH}" ] || fail "configuration must not be a symbolic link"

    certificate_file="${MAER_VAR_DIR}/certs/xmpp.pem"
    [ -f "${certificate_file}" ] || fail "combined TLS certificate is missing: ${certificate_file}"
    [ ! -L "${certificate_file}" ] || fail "TLS certificate must not be a symbolic link"
    [ -r "${certificate_file}" ] || fail "TLS certificate is not readable by the package user"

    if ! certificate_mode=$(stat -c '%a' "${certificate_file}" 2>/dev/null); then
        fail "cannot verify TLS certificate permissions"
    fi
    case "${certificate_mode}" in
        400|600) ;;
        *) fail "TLS certificate permissions must be 0400 or 0600" ;;
    esac
}

check_config()
{
    config_check_expression='case application:load(ejabberd) of ok -> ok; {error,{already_loaded,ejabberd}} -> ok; LoadError -> io:format(standard_error,"application_load_failed: ~p~n",[LoadError]), erlang:halt(1) end, case ejabberd_config:load() of ok -> erlang:halt(0); ConfigError -> io:format(standard_error,"configuration_invalid: ~p~n",[ConfigError]), erlang:halt(1) end.'

    if ! "${EJABBERD_ERL}" -noshell -noinput -eval "${config_check_expression}"
    then
        fail "configuration validation failed"
    fi
}

start_daemon()
{
    assert_runtime_files
    check_config
    assert_ports_available

    "${EJABBERD_CTL}" start || fail "ejabberd start command failed"
    if ! "${EJABBERD_CTL}" started
    then
        "${EJABBERD_CTL}" stop >/dev/null 2>&1 || true
        "${EJABBERD_CTL}" stopped >/dev/null 2>&1 || true
        fail "ejabberd did not become ready"
    fi
}

stop_daemon()
{
    "${EJABBERD_CTL}" stop || fail "ejabberd stop command failed"
    "${EJABBERD_CTL}" stopped || fail "ejabberd did not stop cleanly"
}

case "${1:-}" in
    start)
        if daemon_status; then
            echo "${DNAME} is already running"
            exit 0
        fi
        if node_status; then
            fail "ejabberd responds but its PID file is invalid; refusing a second start"
        fi
        echo "Starting ${DNAME} ..."
        start_daemon
        ;;
    stop)
        if daemon_status || node_status; then
            echo "Stopping ${DNAME} ..."
            stop_daemon
        else
            echo "${DNAME} is not running"
            exit 0
        fi
        ;;
    status)
        if daemon_status; then
            echo "${DNAME} is running"
            exit 0
        fi
        if node_status; then
            echo "${DNAME} responds but its PID file is invalid" >&2
            exit 1
        fi
        echo "${DNAME} is not running"
        exit 3
        ;;
    log)
        printf '%s\n' "${LOG_FILE}"
        ;;
    *)
        echo "Usage: $0 {start|stop|status|log}" >&2
        exit 1
        ;;
esac
