#!/usr/bin/env bash
# Prepare the LFS partition at $LFS (default /mnt/lfs).
#
# Modes:
#   LFS_PART=/dev/sdXN  ./build.sh 10-partition   # use an existing partition
#   LFS_CREATE=1 LFS_DISK=/dev/sdX LFS_SIZE=40GiB \
#       ./build.sh 10-partition                   # create a new GPT partition (destructive!)
#
# If $LFS is already a mountpoint we skip everything and succeed.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 10-partition
require_root

mkdir -p "$LFS"

if mountpoint -q "$LFS"; then
    log "$LFS is already a mountpoint; nothing to do"
    exit 0
fi

if [ -n "${LFS_PART:-}" ]; then
    [ -b "$LFS_PART" ] || die "not a block device: $LFS_PART"
    log "mounting $LFS_PART at $LFS"
    mount -v "$LFS_PART" "$LFS"
    exit 0
fi

if [ "${LFS_CREATE:-0}" = "1" ]; then
    [ -n "${LFS_DISK:-}" ] || die "LFS_CREATE=1 requires LFS_DISK"
    [ -b "$LFS_DISK" ]     || die "not a block device: $LFS_DISK"
    size="${LFS_SIZE:-40GiB}"
    warn "ABOUT TO WIPE $LFS_DISK — creating GPT + one partition of $size"
    read -r -p "Type YES to proceed: " ans
    [ "$ans" = "YES" ] || die "aborted"

    parted -s "$LFS_DISK" mklabel gpt
    parted -s "$LFS_DISK" mkpart lfs ext4 1MiB "$size"
    sleep 1
    part="${LFS_DISK}1"
    [ -b "$part" ] || part="${LFS_DISK}p1"
    [ -b "$part" ] || die "could not locate new partition under $LFS_DISK"
    mkfs.ext4 -F -L lfs "$part"
    mount -v "$part" "$LFS"
    exit 0
fi

cat >&2 <<EOF
Neither an existing partition nor a create-request was provided.

  Option A (recommended): format and pass an existing partition
      LFS_PART=/dev/sdXN ./build.sh 10-partition

  Option B: create a new partition on an empty disk (DESTRUCTIVE)
      LFS_CREATE=1 LFS_DISK=/dev/sdX LFS_SIZE=40GiB ./build.sh 10-partition

Available block devices:
EOF
lsblk >&2
exit 1
