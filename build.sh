#!/usr/bin/env bash
# Gozjaro LFS bootstrap orchestrator.
#
# Usage:
#   sudo ./build.sh all                    # run every stage, skipping completed ones
#   sudo ./build.sh <stage>                # run one stage by number or name
#   sudo ./build.sh --force <stage>        # re-run a completed stage
#   sudo ./build.sh --list                 # list stages
#   sudo ./build.sh --status               # show which stages are done
#
# Stages:
#   00-host-check    10-partition     20-fetch-sources  21-layout
#   22-lfs-user      23-env           30-cross-toolchain 40-temp-tools
#   50-chroot-prep   51-chroot-tools  60-final-system   70-system-config

set -euo pipefail

GOZJARO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GOZJARO_ROOT
# shellcheck source=lib/common.sh
. "$GOZJARO_ROOT/lib/common.sh"

STAGES=(
  00-host-check
  10-partition
  20-fetch-sources
  21-layout
  22-lfs-user
  23-env
  30-cross-toolchain
  40-temp-tools
  50-chroot-prep
  51-chroot-tools
  60-final-system
  70-system-config
)

# Stages that must be executed as the lfs user.
stage_is_lfs_user() {
    case "$1" in
        30-cross-toolchain|40-temp-tools) return 0 ;;
        *) return 1 ;;
    esac
}

# Stages that run inside the chroot.
stage_is_chroot() {
    case "$1" in
        51-chroot-tools|60-final-system|70-system-config) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_stage() {
    local q="$1" s
    for s in "${STAGES[@]}"; do
        if [ "$s" = "$q" ] || [ "${s#*-}" = "$q" ] || [ "${s%%-*}" = "$q" ]; then
            printf '%s\n' "$s"
            return 0
        fi
    done
    die "unknown stage: $q"
}

run_stage() {
    local stage="$1" script
    script="$GOZJARO_ROOT/stages/${stage}.sh"
    [ -x "$script" ] || die "stage script missing or not executable: $script"

    if is_done "$stage"; then
        log "skip stage $stage (marker present; use --force to re-run)"
        return 0
    fi

    step "==> stage $stage"

    if stage_is_chroot "$stage"; then
        # Chroot stages are launched by 50-chroot-prep re-entering this runner.
        require_chroot
        "$script"
    elif stage_is_lfs_user "$stage"; then
        require_root
        # Re-invoke the same script as the lfs user with its login env.
        su -l lfs -c "GOZJARO_ROOT='$GOZJARO_ROOT' bash '$script'"
    else
        require_root
        "$script"
    fi

    mark_done "$stage"
    log "stage $stage complete"
}

cmd_list()   { printf '%s\n' "${STAGES[@]}"; }
cmd_status() {
    ensure_dirs
    local s
    for s in "${STAGES[@]}"; do
        if is_done "$s"; then printf '[x] %s\n' "$s"
        else                  printf '[ ] %s\n' "$s"
        fi
    done
}
cmd_all() {
    local s
    for s in "${STAGES[@]}"; do run_stage "$s"; done
    log "ALL STAGES COMPLETE"
}

main() {
    local force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1; shift ;;
            --list)  cmd_list; exit 0 ;;
            --status) cmd_status; exit 0 ;;
            -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
            --) shift; break ;;
            *) break ;;
        esac
    done
    [ $# -ge 1 ] || { sed -n '2,16p' "$0"; exit 2; }
    local target="$1"

    if [ "$target" = "all" ]; then
        [ "$force" = "1" ] && { ensure_dirs; rm -f "$STATE_DIR"/*.done; }
        cmd_all
        return
    fi

    local stage
    stage=$(resolve_stage "$target")
    [ "$force" = "1" ] && clear_mark "$stage"
    run_stage "$stage"
}

main "$@"
