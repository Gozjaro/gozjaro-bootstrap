#!/usr/bin/env bash
# Enter the LFS chroot manually (or run a one-off command inside it).
#
# Usage:
#   sudo ./chroot.sh                       # interactive shell inside the chroot
#   sudo ./chroot.sh -- ./build.sh 60      # run a command, then exit
#
# Mounts the kernel virtual filesystems and bind-mounts this repo at
# /gozjaro before entering. Safe to run multiple times — every mount is
# idempotent.
set -euo pipefail

GOZJARO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$GOZJARO_ROOT/lib/common.sh"

require_root
[ -d "$LFS" ] || die "LFS=$LFS does not exist"
[ -x "$LFS/usr/bin/env" ] || die "$LFS doesn't look like a populated LFS root (no /usr/bin/env)"

mountpoint -q "$LFS/dev"     || mount -v --bind /dev     "$LFS/dev"
mountpoint -q "$LFS/dev/pts" || mount -v --bind /dev/pts "$LFS/dev/pts"
mountpoint -q "$LFS/proc"    || mount -vt proc  proc  "$LFS/proc"
mountpoint -q "$LFS/sys"     || mount -vt sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"     || mount -vt tmpfs tmpfs "$LFS/run"
if [ ! -h "$LFS/dev/shm" ]; then
    mountpoint -q "$LFS/dev/shm" || mount -vt tmpfs -o nosuid,nodev tmpfs "$LFS/dev/shm"
fi

mkdir -p "$LFS/gozjaro"
mountpoint -q "$LFS/gozjaro" || mount --bind "$GOZJARO_ROOT" "$LFS/gozjaro"
touch "$LFS/.gozjaro-chroot"

# Drop the leading -- if given.
[ "${1:-}" = "--" ] && shift

if [ $# -eq 0 ]; then
    log "entering chroot ($LFS) — type 'exit' to leave"
    chroot "$LFS" /usr/bin/env -i \
        HOME=/root TERM="${TERM:-xterm}" \
        PS1='(gozjaro chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin \
        GOZJARO_ROOT=/gozjaro LFS= \
        MAKEFLAGS="-j$(nproc 2>/dev/null || echo 2)" \
        /bin/bash --login
else
    log "running in chroot: $*"
    chroot "$LFS" /usr/bin/env -i \
        HOME=/root TERM="${TERM:-xterm}" \
        PATH=/usr/bin:/usr/sbin \
        GOZJARO_ROOT=/gozjaro LFS= \
        MAKEFLAGS="-j$(nproc 2>/dev/null || echo 2)" \
        /bin/bash -lc "cd /gozjaro && $*"
fi
