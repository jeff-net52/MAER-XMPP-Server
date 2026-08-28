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

validate_runtime_root()
{
    if [ ! -d "${MAER_VAR_DIR}" ]; then
        echo "The package data directory is missing or unsafe." >&2
        return 1
    fi

    resolved_runtime_root=$(realpath "${MAER_VAR_DIR}") || {
        echo "Cannot resolve the package data directory safely." >&2
        return 1
    }
    if [ ! -d "${resolved_runtime_root}" ] || [ -L "${resolved_runtime_root}" ]; then
        echo "The resolved package data directory is unsafe." >&2
        return 1
    fi

    # DSM 7 deliberately exposes the package data directory through
    # /var/packages/<package>/var -> ${SYNOPKG_PKGVAR}.  Accept that one
    # platform-managed link, but only when it resolves to the exact package
    # data directory declared by DSM.  Every nested runtime path remains
    # subject to the stricter no-symbolic-link policy below.
    if [ -L "${MAER_VAR_DIR}" ]; then
        if [ -z "${SYNOPKG_PKGVAR:-}" ] || [ ! -d "${SYNOPKG_PKGVAR}" ]; then
            echo "DSM did not provide a valid package data directory." >&2
            return 1
        fi
        resolved_synopkg_var=$(realpath "${SYNOPKG_PKGVAR}") || {
            echo "Cannot resolve DSM's package data directory safely." >&2
            return 1
        }
        if [ "${resolved_runtime_root}" != "${resolved_synopkg_var}" ]; then
            echo "The package data link does not match DSM's package data directory." >&2
            return 1
        fi
    fi
}

ensure_runtime_layout()
{
    umask 077
    validate_runtime_root || return 1
    chmod 700 "${MAER_VAR_DIR}" || return 1
    for runtime_dir in \
        "${CONFIG_DIR}" \
        "${MAER_VAR_DIR}/certs" \
        "${SPOOL_DIR}" \
        "${LOGS_DIR}" \
        "${MAER_VAR_DIR}/run" \
        "${MAER_VAR_DIR}/upload"
    do
        if [ -L "${runtime_dir}" ]; then
            echo "Refusing symbolic-link runtime directory: ${runtime_dir}" >&2
            return 1
        fi
        mkdir -p "${runtime_dir}" || return 1
        if [ ! -d "${runtime_dir}" ] || [ -L "${runtime_dir}" ]; then
            echo "Refusing unsafe runtime directory: ${runtime_dir}" >&2
            return 1
        fi
        chmod 700 "${runtime_dir}" || return 1
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
    if [ -e "${target_file}" ] && [ ! -f "${target_file}" ]; then
        echo "Refusing non-regular configuration: ${target_file}" >&2
        return 1
    fi
    if [ ! -e "${target_file}" ]; then
        cp "${source_file}" "${target_file}" || return 1
        chmod 600 "${target_file}" || return 1
    fi
}

install_runtime_defaults()
{
    ensure_runtime_layout || return 1
    install_default_file ejabberd.yml || return 1
    install_default_file ejabberdctl.cfg || return 1
    install_default_file inetrc || return 1
}

replace_default_file()
{
    source_file="${MAER_DEFAULTS_DIR}/$1"
    target_file="${CONFIG_DIR}/$1"
    temporary_file="${target_file}.maer-upgrade.$$"

    if [ ! -f "${source_file}" ] || [ -L "${source_file}" ]; then
        echo "Missing packaged default: ${source_file}" >&2
        return 1
    fi
    if [ -L "${target_file}" ]; then
        echo "Refusing symbolic-link configuration: ${target_file}" >&2
        return 1
    fi
    if [ -e "${target_file}" ] && [ ! -f "${target_file}" ]; then
        echo "Refusing non-regular configuration: ${target_file}" >&2
        return 1
    fi

    rm -f "${temporary_file}" || return 1
    cp "${source_file}" "${temporary_file}" || return 1
    chmod 600 "${temporary_file}" || return 1
    mv "${temporary_file}" "${target_file}" || return 1
}

backup_upgrade_configuration()
{
    target_file="${CONFIG_DIR}/ejabberd.yml"
    backup_file="${CONFIG_DIR}/ejabberd.yml.pre-26.07.0-9"

    if [ ! -f "${target_file}" ] || [ -L "${target_file}" ]; then
        echo "Cannot back up the installed ejabberd configuration safely." >&2
        return 1
    fi
    if [ -L "${backup_file}" ]; then
        echo "Refusing symbolic-link upgrade backup: ${backup_file}" >&2
        return 1
    fi
    if [ -e "${backup_file}" ] && [ ! -f "${backup_file}" ]; then
        echo "Refusing non-regular upgrade backup: ${backup_file}" >&2
        return 1
    fi
    if [ ! -e "${backup_file}" ]; then
        cp "${target_file}" "${backup_file}" || return 1
        chmod 600 "${backup_file}" || return 1
    fi
}

validate_smtp_password_input()
{
    secret_value=${wizard_smtp_password:-}
    secret_file="${CONFIG_DIR}/smtp-password"

    # A blank value is permitted only when an existing regular secret is
    # already in place (for example a later maintenance upgrade).  Fresh
    # installs and the revision-8 migration wizard require a value.
    if [ -z "${secret_value}" ]; then
        if [ -f "${secret_file}" ] && [ ! -L "${secret_file}" ]; then
            if [ ! -s "${secret_file}" ]; then
                echo "The existing portal SMTP password file is empty." >&2
                return 1
            fi
            secret_file_size=$(wc -c < "${secret_file}") || return 1
            if [ "${secret_file_size}" -gt 4096 ]; then
                echo "The existing portal SMTP password file is too large." >&2
                return 1
            fi
            chmod 600 "${secret_file}" || return 1
            return 0
        fi
        echo "A portal SMTP password is required." >&2
        return 1
    fi
    if [ -L "${secret_file}" ]; then
        echo "Refusing symbolic-link SMTP password file: ${secret_file}" >&2
        return 1
    fi
    if [ -e "${secret_file}" ] && [ ! -f "${secret_file}" ]; then
        echo "Refusing non-regular SMTP password file: ${secret_file}" >&2
        return 1
    fi
    if [ "${#secret_value}" -lt 12 ]; then
        echo "The portal SMTP password is too short." >&2
        return 1
    fi
    if [ "${#secret_value}" -gt 4094 ]; then
        echo "The portal SMTP password is too long." >&2
        return 1
    fi
    if printf '%s' "${secret_value}" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        echo "The portal SMTP password contains a control character." >&2
        return 1
    fi
}

install_smtp_password()
{
    validate_smtp_password_input || return 1
    temporary_file="${secret_file}.maer-install.$$"

    if [ -z "${secret_value}" ]; then
        chmod 600 "${secret_file}" || return 1
        return 0
    fi

    umask 077
    rm -f "${temporary_file}" || return 1
    printf '%s\n' "${secret_value}" > "${temporary_file}" || return 1
    chmod 600 "${temporary_file}" || return 1
    mv "${temporary_file}" "${secret_file}" || return 1
    unset secret_value wizard_smtp_password
}

validate_preinst()
{
    # A retained var directory could contain the vulnerable configuration or
    # account database from an older incompatible revision.  Revision 9 only
    # supports a narrowly validated upgrade from revision 8; a new installation
    # must still begin with an empty package data directory.
    if [ -d "${MAER_VAR_DIR}" ]; then
        legacy_entry=$(find "${MAER_VAR_DIR}" -mindepth 1 -maxdepth 1 -print -quit) || {
            echo "Cannot inspect retained package data; refusing installation." >&2
            exit 1
        }
        if [ -n "${legacy_entry}" ]; then
            echo "MAER XMPP Server 26.07.0-9 requires an empty package data directory." >&2
            echo "Remove the previous package and its retained data, then install revision 9 cleanly." >&2
            exit 1
        fi
    fi
    validate_smtp_password_input || exit 1
}

validate_preupgrade()
{
    if [ "${SYNOPKG_OLD_PKGVER:-}" != "26.07.0-8" ]; then
        echo "MAER XMPP Server 26.07.0-9 only supports an in-place upgrade from 26.07.0-8." >&2
        echo "Export any required backup and perform a clean installation for every other source version." >&2
        exit 1
    fi

    if ! validate_runtime_root; then
        echo "The installed package data directory is missing or unsafe; refusing upgrade." >&2
        exit 1
    fi
    for config_name in ejabberd.yml ejabberdctl.cfg inetrc
    do
        config_path="${CONFIG_DIR}/${config_name}"
        if [ ! -f "${config_path}" ] || [ -L "${config_path}" ]; then
            echo "An installed ejabberd configuration is missing or unsafe; refusing upgrade." >&2
            exit 1
        fi
    done
    validate_smtp_password_input || exit 1
}

service_postinst()
{
    install_runtime_defaults || exit 1
    install_smtp_password || exit 1
}

service_postupgrade()
{
    if [ "${SYNOPKG_OLD_PKGVER:-}" != "26.07.0-8" ]; then
        echo "Unexpected source version during MAER XMPP Server upgrade." >&2
        exit 1
    fi

    # SQL/Mnesia account state stays in MAER_VAR_DIR and is intentionally left
    # untouched.  Only the canonical runtime profile is refreshed so revision 9
    # can enable the MAER portal and the corrected fail2ban policy.  Keep one
    # local recovery copy of the revision-8 configuration.
    ensure_runtime_layout || exit 1
    backup_upgrade_configuration || exit 1
    replace_default_file ejabberd.yml || exit 1
    replace_default_file ejabberdctl.cfg || exit 1
    replace_default_file inetrc || exit 1
    install_smtp_password || exit 1
}
