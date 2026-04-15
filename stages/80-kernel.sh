#!/usr/bin/env bash
# Chapter 10: build and install the Linux kernel.
# Runs inside the chroot. Uses the linux-*.tar.xz fetched in stage 20.
#
# Config strategy: `make defconfig` (generic x86_64). Override by dropping
# a custom .config at $LFS/sources/kernel.config before running this stage —
# we'll copy it in and run `make olddefconfig`.
#
# Outputs:
#   /boot/vmlinuz-<ver>-gozjaro
#   /boot/System.map-<ver>-gozjaro
#   /boot/config-<ver>-gozjaro
#   /lib/modules/<ver>/...
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
# shellcheck source=../lib/pkg.sh
. "$GOZJARO_ROOT/lib/pkg.sh"

start_log 80-kernel
require_chroot
require_root

build_kernel() {
    local src="$1"

    # Clean any in-tree leftovers (no-op on a fresh extract; safe either way).
    make mrproper

    if [ -f "$SOURCES_DIR/kernel.config" ]; then
        log "using custom kernel config at $SOURCES_DIR/kernel.config"
        cp -v "$SOURCES_DIR/kernel.config" .config
        make olddefconfig
    else
        log "no custom config; using defconfig"
        make defconfig
    fi

    make
    make modules_install

    # Identify the kernel version that was just built.
    local kver
    kver=$(make -s kernelrelease)

    install -v -m644 arch/x86/boot/bzImage "/boot/vmlinuz-${kver}-gozjaro"
    install -v -m644 System.map           "/boot/System.map-${kver}"
    install -v -m644 .config              "/boot/config-${kver}"

    # Stamp /lib/modules/<ver>/install.log so we can audit which build wrote it.
    install -v -d "/lib/modules/${kver}"
    cp -v System.map ".config" "/lib/modules/${kver}/" 2>/dev/null || true

    log "kernel ${kver} installed to /boot and /lib/modules/${kver}"
}

build_pkg 80.kernel "linux-" build_kernel

log "kernel stage complete"
log "NEXT: install a bootloader (e.g. GRUB) and create /boot/grub/grub.cfg pointing at /boot/vmlinuz-*-gozjaro."
