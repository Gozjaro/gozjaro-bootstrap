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
modules=( loop squashfs isofs overlay ext4 sr_mod cdrom usb-storage uas nvme nvme-core )
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
# Dual-mode initramfs /init for Gozjaro.
#   Live boot:    kernel cmdline contains root=live:LABEL=<LABEL>
#   Installed:    kernel cmdline contains root=UUID=<uuid> or root=/dev/sdXY
#
# NO set -e: a single failing command would silently kill PID 1 and panic.

rescue() {
    echo "[gozjaro-initramfs] FAIL: $*"
    echo "[gozjaro-initramfs] dropping to rescue shell (exit to re-exec init)"
    exec /bin/bash
}

echo "[gozjaro-initramfs] starting (PID $$)"

# --- Virtual filesystems -----------------------------------------------------
mount -t proc     proc     /proc || rescue "mount /proc"
mount -t sysfs    sysfs    /sys  || rescue "mount /sys"
mount -t devtmpfs devtmpfs /dev  || rescue "mount /dev"

# --- Kernel modules ----------------------------------------------------------
echo "[gozjaro-initramfs] loading modules"
for m in loop squashfs isofs overlay ext4 sr_mod cdrom usb-storage uas nvme nvme-core; do
    modprobe -q "$m" && echo "  + $m" || echo "  - $m (missing/builtin)"
done

# --- Parse root= from kernel cmdline -----------------------------------------
get_cmdline_val() {
    local key="$1"
    local tok
    for tok in $(cat /proc/cmdline); do
        case "$tok" in "${key}="*) printf '%s' "${tok#${key}=}"; return ;; esac
    done
}
ROOT_PARAM=$(get_cmdline_val root)
echo "[gozjaro-initramfs] root=$ROOT_PARAM"

# --- Branch: live vs real-disk -----------------------------------------------
case "$ROOT_PARAM" in

    live:LABEL=*)
        # ==================================================================
        # LIVE PATH — squashfs + overlayfs
        # ==================================================================
        echo "[gozjaro-initramfs] mode: live"
        LIVE_LABEL="${ROOT_PARAM#live:LABEL=}"

        echo "[gozjaro-initramfs] waiting for label $LIVE_LABEL"
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            blkid -L "$LIVE_LABEL" >/dev/null 2>&1 && { echo "  found on try $i"; break; }
            sleep 1
        done

        LIVE_DEV=$(blkid -L "$LIVE_LABEL" 2>/dev/null)
        if [ -z "$LIVE_DEV" ]; then
            echo "[gozjaro-initramfs] label not found, scanning block devices"
            for d in /dev/sr0 /dev/sr1 /dev/sd[a-z] /dev/sd[a-z][0-9] \
                     /dev/nvme[0-9]n[0-9] /dev/nvme[0-9]n[0-9]p[0-9] \
                     /dev/nvme[0-9]n[0-9]p[0-9][0-9]; do
                [ -b "$d" ] || continue
                mkdir -p /run/probe
                if mount -o ro "$d" /run/probe 2>/dev/null; then
                    if [ -f /run/probe/live/filesystem.squashfs ]; then
                        LIVE_DEV="$d"; umount /run/probe
                        echo "  found squashfs on $d"; break
                    fi
                    umount /run/probe
                fi
            done
        fi
        [ -n "$LIVE_DEV" ] || rescue "no live medium found"
        echo "[gozjaro-initramfs] live device: $LIVE_DEV"

        mkdir -p /run/livecd /run/squashfs /run/overlay /run/newroot
        mount -o ro "$LIVE_DEV" /run/livecd                             || rescue "mount livecd"
        mount -o loop,ro /run/livecd/live/filesystem.squashfs /run/squashfs \
                                                                        || rescue "mount squashfs"
        mount -t tmpfs tmpfs /run/overlay                               || rescue "mount overlay tmpfs"
        mkdir -p /run/overlay/upper /run/overlay/work
        mount -t overlay overlay \
            -o lowerdir=/run/squashfs,upperdir=/run/overlay/upper,workdir=/run/overlay/work \
            /run/newroot                                                || rescue "mount overlay"

        echo "[gozjaro-initramfs] overlay assembled; moving mounts"
        mkdir -p /run/newroot/run/livecd /run/newroot/run/squashfs /run/newroot/run/overlay
        mount --move /run/livecd   /run/newroot/run/livecd   || echo "  warn: move livecd"
        mount --move /run/squashfs /run/newroot/run/squashfs || echo "  warn: move squashfs"
        mount --move /run/overlay  /run/newroot/run/overlay  || echo "  warn: move overlay"
        ;;

    UUID=*)
        # ==================================================================
        # REAL-DISK PATH — resolve UUID to device, mount directly
        # ==================================================================
        echo "[gozjaro-initramfs] mode: real-disk (UUID)"
        WANT_UUID="${ROOT_PARAM#UUID=}"
        ROOT_DEV=""
        for i in $(seq 1 15); do
            ROOT_DEV=$(blkid -U "$WANT_UUID" 2>/dev/null || true)
            [ -n "$ROOT_DEV" ] && break
            echo "  waiting for UUID=$WANT_UUID (try $i/15)"
            sleep 1
        done
        [ -n "$ROOT_DEV" ] || rescue "UUID=$WANT_UUID not found after 15s"
        echo "[gozjaro-initramfs] root device: $ROOT_DEV"
        mkdir -p /run/newroot
        mount "$ROOT_DEV" /run/newroot || rescue "mount $ROOT_DEV"
        ;;

    /dev/*)
        # ==================================================================
        # REAL-DISK PATH — device path given directly
        # ==================================================================
        echo "[gozjaro-initramfs] mode: real-disk (device)"
        ROOT_DEV="$ROOT_PARAM"
        for i in $(seq 1 10); do
            [ -b "$ROOT_DEV" ] && break
            echo "  waiting for $ROOT_DEV (try $i/10)"
            sleep 1
        done
        [ -b "$ROOT_DEV" ] || rescue "device $ROOT_DEV not found"
        mkdir -p /run/newroot
        mount "$ROOT_DEV" /run/newroot || rescue "mount $ROOT_DEV"
        ;;

    "")
        rescue "no root= on kernel cmdline — check grub.cfg"
        ;;

    *)
        rescue "unrecognised root= format: $ROOT_PARAM"
        ;;
esac

# --- Move virtual FS mounts into newroot (common to both paths) --------------
mkdir -p /run/newroot/dev /run/newroot/proc /run/newroot/sys
mount --move /dev  /run/newroot/dev  || echo "  warn: move /dev"
mount --move /proc /run/newroot/proc || echo "  warn: move /proc"
mount --move /sys  /run/newroot/sys  || echo "  warn: move /sys"

# --- Find init binary ---------------------------------------------------------
INIT_BIN=""
for candidate in \
    /run/newroot/sbin/init \
    /run/newroot/lib/systemd/systemd \
    /run/newroot/usr/lib/systemd/systemd; do
    if [ -x "$candidate" ]; then
        INIT_BIN="${candidate#/run/newroot}"
        break
    fi
done
[ -n "$INIT_BIN" ] || rescue "no init found in /run/newroot"

echo "[gozjaro-initramfs] switching root to $INIT_BIN"
exec switch_root /run/newroot "$INIT_BIN"
rescue "switch_root returned"
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
