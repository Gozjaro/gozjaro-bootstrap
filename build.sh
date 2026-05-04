#!/usr/bin/env bash
# Gozjaro LFS bootstrap orchestrator.
#
# Usage:
#   sudo ./build.sh all                    # run every stage (source mode)
#   sudo ./build.sh --mode binary all      # run every stage (binary mode)
#   sudo ./build.sh <stage>                # run one stage by number or name
#   sudo ./build.sh --force <stage>        # re-run a completed stage
#   sudo ./build.sh --list                 # list stages
#   sudo ./build.sh --status               # show which stages are done
#
# Build modes:
#   source (default) — compile everything from source (LFS 12.3)
#   binary           — install pre-built packages from a gozpak repo
#
# Source stages:
#   00-host-check    10-partition     20-fetch-sources  21-layout
#   22-lfs-user      23-env           30-cross-toolchain 40-temp-tools
#   50-chroot-prep   51-chroot-tools  60-final-system   70-system-config
#   80-kernel        85-initramfs     90-live-iso
#
# Binary stages:
#   00-host-check    10-partition     21-layout
#   50-chroot-prep   35-gozpak-bootstrap  36-binary-install
#   70-system-config 80-kernel        85-initramfs     90-live-iso

set -euo pipefail

GOZJARO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GOZJARO_ROOT
# shellcheck source=lib/common.sh
. "$GOZJARO_ROOT/lib/common.sh"

# Build mode: "source" (default) or "binary".
BUILD_MODE="${BUILD_MODE:-source}"
export BUILD_MODE

# Source mode: compile everything from source (LFS 12.3 chapters 5-9).
STAGES_SOURCE=(
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
  75-live-tools
  77-grub
  80-kernel
  85-initramfs
  90-live-iso
  91-release
)

# Binary mode: install pre-built packages from a gozpak repository.
# Skips source fetch, cross-toolchain, temp-tools, and source compilation.
STAGES_BINARY=(
  00-host-check
  10-partition
  21-layout
  50-chroot-prep
  35-gozpak-bootstrap
  36-binary-install
  70-system-config
  80-kernel
  85-initramfs
  90-live-iso
)

# Select active stage list based on mode.
if [ "$BUILD_MODE" = "binary" ]; then
    STAGES=("${STAGES_BINARY[@]}")
else
    STAGES=("${STAGES_SOURCE[@]}")
fi

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
        35-gozpak-bootstrap|36-binary-install) return 0 ;;
        51-chroot-tools|60-final-system|70-system-config|75-live-tools|77-grub|80-kernel|85-initramfs) return 0 ;;
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
        # When invoked from outside the chroot (e.g. by `build.sh all`), skip
        # them silently — stage 50 drives the chroot run.
        if [ ! -f /.gozjaro-chroot ]; then
            log "skip stage $stage (driven by 50-chroot-prep)"
            return 0
        fi
        "$script"
    elif stage_is_lfs_user "$stage"; then
        require_root
        # Make the repo path traversable+readable for the lfs user. Otherwise
        # repos under e.g. /root or another user's home (mode 700) can't be
        # read by the lfs login shell at all.
        local p="$GOZJARO_ROOT"
        while [ "$p" != "/" ] && [ -n "$p" ]; do
            chmod a+x "$p" 2>/dev/null || true
            p=$(dirname "$p")
        done
        chmod -R a+rX "$GOZJARO_ROOT" 2>/dev/null || true
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
            --mode)
                BUILD_MODE="$2"; shift 2
                if [ "$BUILD_MODE" = "binary" ]; then
                    STAGES=("${STAGES_BINARY[@]}")
                else
                    STAGES=("${STAGES_SOURCE[@]}")
                fi
                export BUILD_MODE
                ;;
            --list)  cmd_list; exit 0 ;;
            --status) cmd_status; exit 0 ;;
            -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
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
