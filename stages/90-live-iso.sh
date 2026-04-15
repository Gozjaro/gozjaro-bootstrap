#!/usr/bin/env bash
# Build a bootable live ISO from the populated $LFS tree.
# Runs on the HOST (not inside chroot). Requires: mksquashfs, xorriso,
# grub-mkrescue (grub2-common + grub-pc-bin on Debian/Ubuntu).
#
# Output: $GOZJARO_ROOT/gozjaro-live.iso
#
# Layout assembled in a staging dir:
#   isoroot/
#     boot/
#       vmlinuz                       <- copy of /boot/vmlinuz-*-gozjaro
#       initrd.img                    <- copy of /boot/initrd-*-gozjaro.img
#       grub/grub.cfg
#     live/
#       filesystem.squashfs           <- squashed $LFS minus build/runtime junk
#
# The initramfs (stage 85) finds the squashfs by ISO label GOZJARO_LIVE.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 90-live-iso
require_root
[ -d "$LFS" ] || die "LFS=$LFS does not exist"

for tool in mksquashfs xorriso grub-mkrescue; do
    command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done

# --- locate kernel + initrd inside $LFS/boot ---------------------------------
shopt -s nullglob
kernels=( "$LFS"/boot/vmlinuz-*-gozjaro )
initrds=( "$LFS"/boot/initrd-*-gozjaro.img )
shopt -u nullglob
[ "${#kernels[@]}" -gt 0 ] || die "no /boot/vmlinuz-*-gozjaro found (run stage 80)"
[ "${#initrds[@]}" -gt 0 ] || die "no /boot/initrd-*-gozjaro.img found (run stage 85)"

# Pick the newest (sort -V; tail).
KERNEL=$(printf '%s\n' "${kernels[@]}" | sort -V | tail -n1)
INITRD=$(printf '%s\n' "${initrds[@]}" | sort -V | tail -n1)
log "kernel: $KERNEL"
log "initrd: $INITRD"

# --- staging directory --------------------------------------------------------
WORK=$(mktemp -d /tmp/gozjaro-iso.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
ISOROOT="$WORK/isoroot"
mkdir -p "$ISOROOT/boot/grub" "$ISOROOT/live"

cp -v "$KERNEL" "$ISOROOT/boot/vmlinuz"
cp -v "$INITRD" "$ISOROOT/boot/initrd.img"

# --- build squashfs -----------------------------------------------------------
log "creating squashfs from $LFS (this takes a while)"
mksquashfs "$LFS" "$ISOROOT/live/filesystem.squashfs" \
    -comp xz \
    -noappend \
    -e \
        "$LFS/sources" \
        "$LFS/tools" \
        "$LFS/proc" \
        "$LFS/sys" \
        "$LFS/dev" \
        "$LFS/run" \
        "$LFS/tmp" \
        "$LFS/gozjaro" \
        "$LFS/var/gozjaro" \
        "$LFS/.gozjaro-chroot"

# --- grub.cfg -----------------------------------------------------------------
cat > "$ISOROOT/boot/grub/grub.cfg" <<'GRUB'
set default=0
set timeout=5

insmod all_video
insmod gfxterm
insmod part_msdos
insmod iso9660

menuentry "Gozjaro Live" {
    linux  /boot/vmlinuz boot=live root=live:LABEL=GOZJARO_LIVE quiet
    initrd /boot/initrd.img
}

menuentry "Gozjaro Live (verbose)" {
    linux  /boot/vmlinuz boot=live root=live:LABEL=GOZJARO_LIVE
    initrd /boot/initrd.img
}
GRUB

# --- assemble ISO -------------------------------------------------------------
OUT="$GOZJARO_ROOT/gozjaro-live.iso"
log "writing $OUT"
grub-mkrescue --volid=GOZJARO_LIVE -o "$OUT" "$ISOROOT" \
    -- -volid GOZJARO_LIVE 2>&1 | tail -n 20 || die "grub-mkrescue failed"

chmod 644 "$OUT"
log "live ISO ready: $OUT ($(du -h "$OUT" | cut -f1))"
log "test with: qemu-system-x86_64 -m 2G -cdrom $OUT"
mark_done 90-live-iso
