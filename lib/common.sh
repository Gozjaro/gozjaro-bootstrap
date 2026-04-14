# Shared helpers. Source this first in every stage/builder.
# shellcheck shell=bash

set -euo pipefail

GOZJARO_ROOT="${GOZJARO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export GOZJARO_ROOT

# shellcheck source=/dev/null
. "${GOZJARO_ROOT}/config/lfs.env"

_c_red=$'\033[0;31m'; _c_grn=$'\033[0;32m'; _c_ylw=$'\033[0;33m'
_c_cyn=$'\033[0;36m'; _c_off=$'\033[0m'

log()  { printf '%s[gozjaro]%s %s\n' "$_c_grn" "$_c_off" "$*"; }
warn() { printf '%s[gozjaro]%s %s\n' "$_c_ylw" "$_c_off" "$*" >&2; }
die()  { printf '%s[gozjaro: FATAL]%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }
step() { printf '%s==> %s%s\n' "$_c_cyn" "$*" "$_c_off"; }

require_root() {
    [ "$(id -u)" = "0" ] || die "must run as root: $*"
}

require_lfs_user() {
    [ "$(id -un)" = "lfs" ] || die "must run as user 'lfs'"
}

require_chroot() {
    [ -f /.gozjaro-chroot ] || die "must run inside the LFS chroot"
}

ensure_dirs() {
    mkdir -p "$STATE_DIR" "$LOG_DIR"
}

# Redirect all further output of the current script to a log file (tee to stdout).
start_log() {
    local name="$1"
    ensure_dirs
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    local path="${LOG_DIR}/${ts}-${name}.log"
    exec > >(tee -a "$path") 2>&1
    log "logging to $path"
}

# Idempotency markers.
marker_path() { printf '%s/%s.done\n' "$STATE_DIR" "$1"; }
is_done()     { [ -f "$(marker_path "$1")" ]; }
mark_done()   { ensure_dirs; touch "$(marker_path "$1")"; }
clear_mark()  { rm -f "$(marker_path "$1")"; }
