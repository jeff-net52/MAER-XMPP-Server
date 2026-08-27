#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

MAER_PACKAGE_ROOT="/var/packages/maerxmppserver"
MAER_VAR_DIR="${MAER_PACKAGE_ROOT}/var"
MAER_DEFAULTS_DIR="${MAER_PACKAGE_ROOT}/target/share/maerxmppserver/defaults"

# DSM's package service environment does not guarantee HOME.  Erlang's auth
# service requires it even when the node cookie is created automatically; an
# unset value terminates the kernel before ejabberd can write a useful log.
HOME="${MAER_PACKAGE_ROOT}/home"

CONFIG_DIR="${MAER_VAR_DIR}/config"
LOGS_DIR="${MAER_VAR_DIR}/log"
SPOOL_DIR="${MAER_VAR_DIR}/data"

EJABBERD_CTL="${MAER_PACKAGE_ROOT}/target/bin/ejabberdctl"
EJABBERD_ERL="${MAER_PACKAGE_ROOT}/target/bin/erl"
EJABBERD_CONFIG_PATH="${CONFIG_DIR}/ejabberd.yml"
EJABBERDCTL_CONFIG_PATH="${CONFIG_DIR}/ejabberdctl.cfg"
EJABBERD_LOG_PATH="${LOGS_DIR}/ejabberd.log"
EJABBERD_PID_PATH="${MAER_VAR_DIR}/run/ejabberd.pid"
ERL_LIBS="${MAER_PACKAGE_ROOT}/target/lib"

ERLANG_NODE="maerxmppserver@localhost"
INET_DIST_INTERFACE="127.0.0.1"
ERL_EPMD_ADDRESS="127.0.0.1"
ERL_DIST_PORT="5211"

LOG_FILE="${EJABBERD_LOG_PATH}"
PID_FILE="${EJABBERD_PID_PATH}"

export CONFIG_DIR LOGS_DIR SPOOL_DIR
export HOME
export EJABBERD_CONFIG_PATH EJABBERDCTL_CONFIG_PATH
export EJABBERD_LOG_PATH EJABBERD_PID_PATH ERL_LIBS
export ERLANG_NODE INET_DIST_INTERFACE ERL_EPMD_ADDRESS ERL_DIST_PORT

ensure_runtime_layout()
{
    umask 077
    for runtime_dir in \
        "${MAER_VAR_DIR}" \
        "${CONFIG_DIR}" \
        "${MAER_VAR_DIR}/certs" \
        "${SPOOL_DIR}" \
        "${LOGS_DIR}" \
        "${MAER_VAR_DIR}/run" \
        "${MAER_VAR_DIR}/upload"
    do
        mkdir -p "${runtime_dir}"
        chmod 700 "${runtime_dir}"
    done
}

install_default_file()
{
    source_file="${MAER_DEFAULTS_DIR}/$1"
    target_file="${CONFIG_DIR}/$1"

    if [ ! -f "${source_file}" ] || [ -L "${source_file}" ]; then
        echo "Missing packaged default: ${source_file}" >&2
        return 1
    fi
    if [ -L "${target_file}" ]; then
        echo "Refusing symbolic-link configuration: ${target_file}" >&2
        return 1
    fi
    if [ ! -e "${target_file}" ]; then
        cp "${source_file}" "${target_file}"
        chmod 600 "${target_file}"
    fi
}

install_runtime_defaults()
{
    ensure_runtime_layout
    install_default_file ejabberd.yml
    install_default_file ejabberdctl.cfg
    install_default_file inetrc
}

validate_preinst()
{
    # A retained var directory could contain the vulnerable configuration or
    # account database from an older revision.  Revision 5 deliberately has no
    # in-place migration path: the operator must remove retained package data
    # and perform a genuinely clean installation.
    if [ -d "${MAER_VAR_DIR}" ]; then
        legacy_entry=$(find "${MAER_VAR_DIR}" -mindepth 1 -maxdepth 1 -print -quit) || {
            echo "Cannot inspect retained package data; refusing installation." >&2
            exit 1
        }
        if [ -n "${legacy_entry}" ]; then
            echo "MAER XMPP Server 26.07.0-5 requires an empty package data directory." >&2
            echo "Remove the previous package and its retained data, then install revision 5 cleanly." >&2
            exit 1
        fi
    fi
}

validate_preupgrade()
{
    echo "In-place upgrades to MAER XMPP Server 26.07.0-5 are intentionally refused." >&2
    echo "Export any required backup, uninstall the previous revision with its data, then perform a clean installation." >&2
    exit 1
}

service_postinst()
{
    install_runtime_defaults
}

service_postupgrade()
{
    echo "Unexpected upgrade hook: revision 5 supports clean installation only." >&2
    exit 1
}
