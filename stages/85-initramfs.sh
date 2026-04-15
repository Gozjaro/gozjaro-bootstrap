#!/usr/bin/env bash
# Build a minimal initramfs that can boot the live ISO.
# Runs inside the chroot, after stage 80 has installed a kernel.
#
# The initramfs:
#   * mounts /proc, /sys, /dev (devtmpfs)
#   * loads the modules needed for the live medium (loop, squashfs, isofs,
#     overlay, ext4)
#   * locates the squashfs image on the live CD (by label "GOZJARO_LIVE")
#   * sets up an overlayfs over the read-only squashfs (writeable in tmpfs)
#   * switch_roots into the merged tree and execs /sbin/init
#
# Output: /boot/initrd-<kver>-gozjaro.img (gzip'd cpio newc archive)
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 85-initramfs
require_chroot
require_root

# --- pick the kernel version --------------------------------------------------
KVER="${KVER:-}"
if [ -z "$KVER" ]; then
    # newest installed kernel module set
    KVER=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1 || true)
fi
[ -n "$KVER" ] || die "no kernel found under /lib/modules (run stage 80 first)"
log "building initramfs for kernel $KVER"

# --- staging ------------------------------------------------------------------
mkdir -p /tmp
STAGING=$(mktemp -d /tmp/gozjaro-initramfs.XXXXXX)
log "staging dir: $STAGING"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$STAGING"/{bin,sbin,lib,lib64,etc,proc,sys,dev,run,newroot}
ln -s bin "$STAGING/usr"   2>/dev/null || true   # tiny merged-usr inside ramfs

# --- copy a small set of binaries --------------------------------------------
need_bins=(
    bash mount umount mkdir sleep cat ls echo ln cp mv rm sed grep findmnt
    blkid switch_root modprobe insmod losetup kmod
)
# Resolve each name against common locations (covers merged-usr layouts where
# /sbin is a symlink into /usr/bin).
resolve_bin() {
    local name="$1" p
    for p in "/bin/$name" "/usr/bin/$name" "/sbin/$name" "/usr/sbin/$name"; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    # Last resort: PATH lookup.
    command -v "$name" 2>/dev/null || true
}
log "staging binaries"
for name in "${need_bins[@]}"; do
    b=$(resolve_bin "$name")
    [ -n "$b" ] || { warn "missing $name — skipping"; continue; }
    # Strip leading slash then install under the same path inside STAGING,
    # but normalise /usr/bin → /bin so the initramfs PATH (/bin:/sbin) works.
    dest="/bin/$name"
    case "$name" in
        blkid|switch_root|modprobe|insmod|losetup|kmod) dest="/sbin/$name" ;;
    esac
    install -Dm755 "$b" "$STAGING$dest"
done

# --- copy the libraries each binary needs ------------------------------------
copy_lib() {
    local lib="$1"
    [ -e "$lib" ] || return 0
    # Resolve symlink chain so we copy real file plus symlinks pointing to it.
    local real; real=$(readlink -f "$lib")
    install -Dm755 "$real" "$STAGING$real"
    if [ "$real" != "$lib" ]; then
        mkdir -p "$STAGING$(dirname "$lib")"
        cp -d "$lib" "$STAGING$lib"
    fi
}

log "resolving library dependencies"
for b in "$STAGING"/{bin,sbin}/*; do
    [ -x "$b" ] || continue
    while read -r _ _ path _; do
        case "$path" in
            /*) copy_lib "$path" ;;
        esac
    done < <(ldd "$b" 2>/dev/null | sed 's/^[[:space:]]*//')
done

# Always include the ELF interpreter (some bins skip it in ldd output).
for ld in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2; do
    [ -e "$ld" ] && copy_lib "$ld"
done

# --- copy the kernel modules we need at boot ---------------------------------
modules=( loop squashfs isofs overlay ext4 sr_mod cdrom usb-storage uas )
moddir="/lib/modules/$KVER"
[ -d "$moddir" ] || die "kernel modules dir missing: $moddir"
mkdir -p "$STAGING$moddir"
# Always copy depmod metadata.
cp -a "$moddir"/modules.* "$STAGING$moddir/" 2>/dev/null || true
# Walk each requested module and pull it + its dependencies.
log "copying kernel modules for $KVER"
for mod in "${modules[@]}"; do
    log "  module: $mod"
    while read -r verb path; do
        # `modprobe -D` emits "insmod /path/to.ko.xz" for real modules and
        # "builtin <name>" for modules compiled into the kernel — skip the
        # latter, they're already in vmlinuz.
        [ "$verb" = "insmod" ] || continue
        [ -n "$path" ] && [ -f "$path" ] || continue
        install -Dm644 "$path" "$STAGING$path"
    done < <(modprobe -D -S "$KVER" "$mod" 2>/dev/null || true)
done

# --- /init --------------------------------------------------------------------
cat > "$STAGING/init" <<'INIT'
#!/bin/bash
set -e
echo "[gozjaro-initramfs] starting"

mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev

for m in loop squashfs isofs overlay ext4 sr_mod cdrom usb-storage uas; do
    modprobe -q "$m" || true
done

# Allow USB / SCSI to settle.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if blkid -L GOZJARO_LIVE >/dev/null 2>&1; then break; fi
    sleep 1
done

LIVE_DEV=$(blkid -L GOZJARO_LIVE || true)
if [ -z "$LIVE_DEV" ]; then
    # Last-ditch scan for /live/filesystem.squashfs.
    for d in /dev/sr0 /dev/sr1 /dev/sda /dev/sdb /dev/sdc /dev/nvme0n1p1; do
        [ -b "$d" ] || continue
        mkdir -p /run/probe
        if mount -o ro "$d" /run/probe 2>/dev/null; then
            if [ -f /run/probe/live/filesystem.squashfs ]; then
                LIVE_DEV="$d"; umount /run/probe; break
            fi
            umount /run/probe
        fi
    done
fi
[ -n "$LIVE_DEV" ] || { echo "[gozjaro-initramfs] no live medium found"; exec /bin/bash; }

mkdir -p /run/livecd /run/squashfs /run/overlay /run/newroot
mount -o ro "$LIVE_DEV" /run/livecd
mount -o loop,ro /run/livecd/live/filesystem.squashfs /run/squashfs
mount -t tmpfs tmpfs /run/overlay
mkdir -p /run/overlay/upper /run/overlay/work
mount -t overlay overlay \
    -o lowerdir=/run/squashfs,upperdir=/run/overlay/upper,workdir=/run/overlay/work \
    /run/newroot

# Hand the squashfs/overlay mounts off to the new root.
mkdir -p /run/newroot/run/livecd /run/newroot/run/squashfs /run/newroot/run/overlay
mount --move /run/livecd  /run/newroot/run/livecd
mount --move /run/squashfs /run/newroot/run/squashfs
mount --move /run/overlay  /run/newroot/run/overlay

echo "[gozjaro-initramfs] switching root"
exec switch_root /run/newroot /sbin/init
INIT
chmod 755 "$STAGING/init"

# --- pack the cpio.gz ---------------------------------------------------------
out="/boot/initrd-${KVER}-gozjaro.img"

if command -v cpio >/dev/null 2>&1; then
    log "packing $out with in-chroot cpio"
    ( cd "$STAGING" && find . -print0 | cpio --null --create --format=newc ) \
        | gzip -9 > "$out"
    chmod 644 "$out"
    log "wrote $out ($(du -h "$out" | cut -f1))"
else
    # cpio isn't part of the LFS package set. Hand the staging tree off to the
    # host (stage 90 / host side) by parking it under /boot.
    handoff="/boot/initramfs-stage-${KVER}"
    rm -rf "$handoff"
    log "cpio not installed; handing staging tree off to host at $handoff"
    cp -a "$STAGING" "$handoff"
    # Drop a tiny README so stage 90 knows what to do.
    cat > "${handoff}.README" <<EOF
This directory is a prepared initramfs root built inside the chroot.
On the host, pack it with:
  ( cd "$handoff" && find . -print0 | cpio --null --create --format=newc ) \\
      | gzip -9 > "/boot/initrd-${KVER}-gozjaro.img"
Stage 90 (90-live-iso.sh) does this automatically.
EOF
fi

mark_done 85-initramfs
