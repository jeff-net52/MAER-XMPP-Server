#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
# Copyright (C) 2026 MAER contributors

set -Eeuo pipefail

PATH=/usr/bin:/bin
export PATH

readonly EXPECTED_SPKSRC_COMMIT='954871e356f7f990c179eb58af11c20d82872d8f'
readonly OVERLAY_PATHS=(
    'native/erlang-maer'
    'cross/erlang-maer'
    'cross/openssl3-maer'
    'cross/maerxmppserver'
    'spk/maerxmppserver'
)

usage() {
    cat <<'EOF'
Usage: prepare-overlay.sh --spksrc PATH [--check]

Prepare the locked MAER recipes in a native Linux/WSL spksrc checkout.
With --check, perform every read-only preflight check and do not create files.
EOF
}

die() {
    printf 'prepare-overlay.sh: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

read_lock_value() {
    local key_path=$1
    python3 -c '
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    value = json.load(stream)
for component in sys.argv[2].split("."):
    value = value[component]
if not isinstance(value, str):
    raise SystemExit("lock value is not a string: " + sys.argv[2])
print(value)
' "$LOCKS_PATH" "$key_path"
}

sha256_file() {
    sha256sum -- "$1" | awk '{print $1}'
}

assert_sha256() {
    local path=$1
    local expected=$2
    local actual

    [[ -f "$path" && ! -L "$path" ]] || die "required regular file missing: $path"
    actual=$(sha256_file "$path")
    [[ "$actual" == "$expected" ]] || die "SHA256 mismatch for $path"
}

rename_no_replace() {
    local source_path=$1
    local destination_path=$2

    python3 - "$source_path" "$destination_path" <<'PY'
import ctypes
import os
import sys

AT_FDCWD = -100
RENAME_NOREPLACE = 1
libc = ctypes.CDLL(None, use_errno=True)
try:
    renameat2 = libc.renameat2
except AttributeError:
    print("renameat2 is unavailable; refusing a non-atomic move", file=sys.stderr)
    raise SystemExit(1)

renameat2.argtypes = (
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_uint,
)
renameat2.restype = ctypes.c_int
result = renameat2(
    AT_FDCWD,
    os.fsencode(sys.argv[1]),
    AT_FDCWD,
    os.fsencode(sys.argv[2]),
    RENAME_NOREPLACE,
)
if result != 0:
    error_number = ctypes.get_errno()
    print(
        f"atomic no-replace rename failed: {os.strerror(error_number)}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

tree_digest() {
    local root_path=$1

    python3 - "$root_path" <<'PY'
import hashlib
import os
import stat
import sys

root = os.path.realpath(sys.argv[1])
digest = hashlib.sha256()

def add_field(value):
    data = value if isinstance(value, bytes) else os.fsencode(value)
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)

def visit(relative_path):
    directory = root if not relative_path else os.path.join(root, relative_path)
    with os.scandir(directory) as entries:
        ordered = sorted(entries, key=lambda entry: os.fsencode(entry.name))
    for entry in ordered:
        child_relative = entry.name if not relative_path else os.path.join(relative_path, entry.name)
        metadata = entry.stat(follow_symlinks=False)
        if stat.S_ISDIR(metadata.st_mode):
            add_field(b"directory")
            add_field(child_relative)
            visit(child_relative)
        elif stat.S_ISREG(metadata.st_mode):
            add_field(b"file")
            add_field(child_relative)
            with open(entry.path, "rb") as stream:
                while True:
                    block = stream.read(1024 * 1024)
                    if not block:
                        break
                    digest.update(block)
        else:
            print(f"unsupported overlay entry: {child_relative}", file=sys.stderr)
            raise SystemExit(1)

visit("")
print(digest.hexdigest())
PY
}

SPKSRC_INPUT=''
CHECK_ONLY=0
while (($# > 0)); do
    case "$1" in
        --spksrc)
            (($# >= 2)) || die '--spksrc requires a path'
            [[ -z "$SPKSRC_INPUT" ]] || die '--spksrc may be supplied only once'
            SPKSRC_INPUT=$2
            shift 2
            ;;
        --check)
            CHECK_ONLY=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n "$SPKSRC_INPUT" ]] || die '--spksrc is required'

require_command awk
require_command cp
require_command find
require_command git
require_command mktemp
require_command python3
require_command readlink
require_command sha256sum
require_command stat

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}") || die 'unable to resolve the preparation script path'
readonly SCRIPT_PATH
SYNOLOGY_ROOT=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P) || die 'unable to resolve the Synology packaging directory'
readonly SYNOLOGY_ROOT
REPOSITORY_ROOT=$(cd -- "$SYNOLOGY_ROOT/../.." && pwd -P) || die 'unable to resolve the MAER repository root'
readonly REPOSITORY_ROOT
readonly OVERLAY_ROOT="$SYNOLOGY_ROOT/spksrc-overlay"
readonly LOCKS_PATH="$SYNOLOGY_ROOT/LOCKS.json"

[[ -d "$SPKSRC_INPUT" ]] || die "spksrc directory not found: $SPKSRC_INPUT"
SPKSRC_ROOT=$(cd -- "$SPKSRC_INPUT" && pwd -P) || die 'unable to resolve the spksrc checkout path'
readonly SPKSRC_ROOT
[[ "$SPKSRC_ROOT" != '/' ]] || die 'refusing to use the filesystem root as spksrc checkout'
[[ -f "$LOCKS_PATH" && ! -L "$LOCKS_PATH" ]] || die "lock file missing: $LOCKS_PATH"
[[ -d "$OVERLAY_ROOT" && ! -L "$OVERLAY_ROOT" ]] || die "overlay directory missing: $OVERLAY_ROOT"

LOCKED_COMMIT=$(read_lock_value 'spksrc.commit') || die 'unable to read spksrc.commit from LOCKS.json'
readonly LOCKED_COMMIT
ICON_SHA256=$(read_lock_value 'assets.maer_mark_sha256') || die 'unable to read the icon hash from LOCKS.json'
readonly ICON_SHA256
COPYING_SHA256=$(read_lock_value 'assets.copying_sha256') || die 'unable to read the COPYING hash from LOCKS.json'
readonly COPYING_SHA256
[[ "$LOCKED_COMMIT" == "$EXPECTED_SPKSRC_COMMIT" ]] || die 'LOCKS.json and preparation script disagree on the spksrc commit'

GIT_TOPLEVEL=$(GIT_OPTIONAL_LOCKS=0 git -C "$SPKSRC_ROOT" rev-parse --show-toplevel) || die 'unable to identify the spksrc Git checkout'
readonly GIT_TOPLEVEL
GIT_TOPLEVEL_REAL=$(cd -- "$GIT_TOPLEVEL" && pwd -P) || die 'unable to resolve the spksrc Git checkout root'
readonly GIT_TOPLEVEL_REAL
[[ "$GIT_TOPLEVEL_REAL" == "$SPKSRC_ROOT" ]] || die "--spksrc must name the checkout root: $GIT_TOPLEVEL_REAL"

ACTUAL_COMMIT=$(GIT_OPTIONAL_LOCKS=0 git -C "$SPKSRC_ROOT" rev-parse HEAD) || die 'unable to read the spksrc HEAD commit'
readonly ACTUAL_COMMIT
[[ "$ACTUAL_COMMIT" == "$LOCKED_COMMIT" ]] || die "spksrc HEAD is $ACTUAL_COMMIT; expected $LOCKED_COMMIT"

WORKTREE_STATUS=$(GIT_OPTIONAL_LOCKS=0 git -C "$SPKSRC_ROOT" status --porcelain=v1 --untracked-files=all) || die 'unable to inspect the spksrc working tree'
readonly WORKTREE_STATUS
[[ -z "$WORKTREE_STATUS" ]] || die 'the spksrc checkout must be clean before applying the MAER overlay'

OVERLAY_SYMLINK=$(find "$OVERLAY_ROOT" -type l -print -quit) || die 'unable to inspect the overlay for symbolic links'
readonly OVERLAY_SYMLINK
[[ -z "$OVERLAY_SYMLINK" ]] || die 'symbolic links are not allowed in the overlay source'
OVERLAY_SPECIAL=$(find "$OVERLAY_ROOT" ! -type d ! -type f -print -quit) || die 'unable to inspect overlay entry types'
readonly OVERLAY_SPECIAL
[[ -z "$OVERLAY_SPECIAL" ]] || die 'only directories and regular files are allowed in the overlay source'

readonly CANONICAL_ICON="$REPOSITORY_ROOT/maer/assets/maer-mark.png"
readonly CANONICAL_COPYING="$REPOSITORY_ROOT/COPYING"
readonly PACKAGED_ICON="$OVERLAY_ROOT/spk/maerxmppserver/src/maerxmppserver.png"
readonly PACKAGED_COPYING="$OVERLAY_ROOT/spk/maerxmppserver/src/COPYING"
assert_sha256 "$CANONICAL_ICON" "$ICON_SHA256"
assert_sha256 "$PACKAGED_ICON" "$ICON_SHA256"
assert_sha256 "$CANONICAL_COPYING" "$COPYING_SHA256"
assert_sha256 "$PACKAGED_COPYING" "$COPYING_SHA256"
OVERLAY_TREE_DIGEST=$(tree_digest "$OVERLAY_ROOT") || die 'unable to fingerprint the overlay source tree'
readonly OVERLAY_TREE_DIGEST

SPKSRC_DEVICE=$(stat -c '%d' -- "$SPKSRC_ROOT") || die 'unable to identify the spksrc filesystem'
readonly SPKSRC_DEVICE
for relative_path in "${OVERLAY_PATHS[@]}"; do
    source_path="$OVERLAY_ROOT/$relative_path"
    destination_path="$SPKSRC_ROOT/$relative_path"
    destination_parent=$(dirname -- "$destination_path")
    [[ -d "$source_path" && ! -L "$source_path" ]] || die "overlay source missing: $source_path"
    [[ ! -e "$destination_path" && ! -L "$destination_path" ]] || die "refusing to overwrite an existing spksrc path: $destination_path"
    [[ -d "$destination_parent" && ! -L "$destination_parent" ]] || die "spksrc parent directory missing or symbolic: $destination_parent"
    [[ -w "$destination_parent" ]] || die "spksrc parent directory is not writable: $destination_parent"
    parent_device=$(stat -c '%d' -- "$destination_parent") || die "unable to identify the filesystem for $destination_parent"
    [[ "$parent_device" == "$SPKSRC_DEVICE" ]] || die "spksrc recipe parent is on a different filesystem: $destination_parent"
done

if ((CHECK_ONLY)); then
    printf 'MAER Synology overlay preflight passed for %s\n' "$SPKSRC_ROOT"
    printf 'No file was created, copied, moved, or removed.\n'
    exit 0
fi

STAGING_ROOT=''
COMMITTED=0
MOVED_PATHS=()
MOVED_IDENTITIES=()

rollback_moves() {
    local index
    local destination_path
    local rollback_path
    local expected_identity
    local actual_identity

    for ((index=${#MOVED_PATHS[@]} - 1; index >= 0; index--)); do
        destination_path=${MOVED_PATHS[index]}
        case "$destination_path" in
            "$SPKSRC_ROOT/native/erlang-maer"|\
            "$SPKSRC_ROOT/cross/erlang-maer"|\
            "$SPKSRC_ROOT/cross/openssl3-maer"|\
            "$SPKSRC_ROOT/cross/maerxmppserver"|\
            "$SPKSRC_ROOT/spk/maerxmppserver")
                ;;
            *)
                printf 'Refusing unsafe rollback path: %s\n' "$destination_path" >&2
                continue
                ;;
        esac
        if [[ -e "$destination_path" || -L "$destination_path" ]]; then
            expected_identity=${MOVED_IDENTITIES[index]:-}
            actual_identity=$(stat -c '%d:%i' -- "$destination_path") || actual_identity=''
            if [[ -z "$expected_identity" || "$actual_identity" != "$expected_identity" ]]; then
                printf 'Refusing rollback for changed path: %s\n' "$destination_path" >&2
                continue
            fi
            rollback_path="$STAGING_ROOT/rollback-$index"
            rename_no_replace "$destination_path" "$rollback_path" || printf 'Rollback failed for %s\n' "$destination_path" >&2
        fi
    done
}

cleanup() {
    local status=$?

    trap - EXIT HUP INT TERM
    if ((status != 0 && COMMITTED == 0)) && [[ -n "$STAGING_ROOT" ]]; then
        rollback_moves
    fi
    if [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" && ! -L "$STAGING_ROOT" ]]; then
        case "$STAGING_ROOT" in
            "$SPKSRC_ROOT"/.maer-overlay-stage.*)
                rm -rf -- "$STAGING_ROOT"
                ;;
            *)
                printf 'Refusing unsafe staging cleanup path: %s\n' "$STAGING_ROOT" >&2
                status=1
                ;;
        esac
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

STAGING_ROOT=$(mktemp -d -- "$SPKSRC_ROOT/.maer-overlay-stage.XXXXXXXX") || die 'unable to create the staging directory'
[[ -d "$STAGING_ROOT" && ! -L "$STAGING_ROOT" ]] || die 'unable to create a safe staging directory'

for relative_path in "${OVERLAY_PATHS[@]}"; do
    source_path="$OVERLAY_ROOT/$relative_path"
    staged_path="$STAGING_ROOT/$relative_path"
    mkdir -p -- "$staged_path"
    cp -R -- "$source_path/." "$staged_path/"
done

chmod 0700 "$STAGING_ROOT"
find "$STAGING_ROOT" -mindepth 1 -type d -exec chmod 0755 {} +
find "$STAGING_ROOT" -type f -exec chmod 0644 {} +
chmod 0755 "$STAGING_ROOT/spk/maerxmppserver/src/service-setup.sh"
chmod 0755 "$STAGING_ROOT/spk/maerxmppserver/src/service-start-stop.sh"
STAGED_SPECIAL=$(find "$STAGING_ROOT" ! -type d ! -type f -print -quit) || die 'unable to inspect staged overlay entry types'
[[ -z "$STAGED_SPECIAL" ]] || die 'a non-regular entry appeared in the staged overlay'

CURRENT_OVERLAY_TREE_DIGEST=$(tree_digest "$OVERLAY_ROOT") || die 'unable to re-fingerprint the overlay source tree'
STAGED_TREE_DIGEST=$(tree_digest "$STAGING_ROOT") || die 'unable to fingerprint the staged overlay tree'
[[ "$CURRENT_OVERLAY_TREE_DIGEST" == "$OVERLAY_TREE_DIGEST" ]] || die 'overlay source changed while it was being staged'
[[ "$STAGED_TREE_DIGEST" == "$OVERLAY_TREE_DIGEST" ]] || die 'staged overlay does not match the validated source tree'

assert_sha256 "$STAGING_ROOT/spk/maerxmppserver/src/maerxmppserver.png" "$ICON_SHA256"
assert_sha256 "$STAGING_ROOT/spk/maerxmppserver/src/COPYING" "$COPYING_SHA256"

for relative_path in "${OVERLAY_PATHS[@]}"; do
    staged_path="$STAGING_ROOT/$relative_path"
    destination_path="$SPKSRC_ROOT/$relative_path"
    trap '' HUP INT TERM
    if rename_no_replace "$staged_path" "$destination_path"; then
        MOVED_PATHS+=("$destination_path")
        if moved_identity=$(stat -c '%d:%i' -- "$destination_path"); then
            MOVED_IDENTITIES+=("$moved_identity")
        else
            MOVED_IDENTITIES+=('')
            trap 'exit 129' HUP
            trap 'exit 130' INT
            trap 'exit 143' TERM
            die "unable to identify newly installed path: $destination_path"
        fi
    else
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        die "destination appeared or atomic move failed during preparation: $destination_path"
    fi
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
done

COMMITTED=1
printf 'MAER Synology overlay prepared in %s\n' "$SPKSRC_ROOT"
printf 'No package was built or installed.\n'
