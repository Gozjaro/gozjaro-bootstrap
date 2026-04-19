#!/usr/bin/env bash
# Ch. 7.2–7.4: hand $LFS back to root, mount kernel virtual FS, enter chroot,
# and re-invoke build.sh for stages 51/60/70 inside it.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 50-chroot-prep
require_root

# Change ownership of the built tree back to root:root. Some entries (e.g.
# /tools, /lib64) only exist on certain hosts/stages — chown only what's there.
for d in usr lib var etc bin sbin tools sources lib64; do
    [ -e "$LFS/$d" ] || continue
    chown -R root:root "$LFS/$d"
done

# Prepare virtual kernel file systems.
mkdir -pv "$LFS"/{dev,proc,sys,run}

mount_if_needed() {
    mountpoint -q "$2" && return 0
    mount -v --bind "$1" "$2"
}

mount_if_needed /dev  "$LFS/dev"
mount -v --bind /dev/pts "$LFS/dev/pts" 2>/dev/null || \
    mount -vt devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
mountpoint -q "$LFS/proc" || mount -vt proc  proc  "$LFS/proc"
mountpoint -q "$LFS/sys"  || mount -vt sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"  || mount -vt tmpfs tmpfs "$LFS/run"

if [ -h "$LFS/dev/shm" ]; then
    install -v -d -m 1777 "$LFS$(realpath /dev/shm)"
else
    mountpoint -q "$LFS/dev/shm" || mount -vt tmpfs -o nosuid,nodev tmpfs "$LFS/dev/shm"
fi

# Mirror the repo inside the chroot so build.sh keeps working.
mkdir -p "$LFS/gozjaro"
mountpoint -q "$LFS/gozjaro" || mount --bind "$GOZJARO_ROOT" "$LFS/gozjaro"

# Chroot marker used by lib/common.sh::require_chroot.
touch "$LFS/.gozjaro-chroot"

log "entering chroot to run stages 51, 60, 70"
chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(gozjaro chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    GOZJARO_ROOT=/gozjaro \
    LFS= \
    MAKEFLAGS="$MAKEFLAGS" \
    /bin/bash -lc '
        set -e
        cd /gozjaro
        ./build.sh 51-chroot-tools
        ./build.sh 60-final-system
        ./build.sh 70-system-config
        ./build.sh 75-live-tools
        ./build.sh 76-pacman
        ./build.sh 77-grub
        ./build.sh 80-kernel
        ./build.sh 85-initramfs
    '
log "chroot stages returned successfully"
