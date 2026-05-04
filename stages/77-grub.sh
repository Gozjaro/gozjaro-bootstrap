#!/usr/bin/env bash
# Build GRUB 2 (both i386-pc BIOS and x86_64-efi UEFI targets) and install
# the gozjaro-install CLI installer to /usr/bin.
# Runs inside the chroot, after stage 75 (live-tools) and before stage 80 (kernel).
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
# shellcheck source=../lib/pkg.sh
. "$GOZJARO_ROOT/lib/pkg.sh"

start_log 77-grub
require_chroot
require_root

b_grub() {
    local src="$1"

    # grub's configure probes for python3, bison, flex, gettext — all present.
    # --disable-werror is mandatory: GCC 14 promotes GRUB's intentional
    # warnings (-Wno-* suppressed upstream) to errors.
    #
    # Two separate out-of-tree builds from the same extracted source:
    #   build-bios: i386-pc module tree + all grub-* binaries
    #   build-efi:  x86_64-efi module tree only (binaries already installed)

    # GRUB 2.12 out-of-tree builds require extra_deps.lst to exist in the
    # source grub-core/ directory. It is normally created by an in-tree
    # configure; touch it here so out-of-tree Makefiles find it.
    touch grub-core/extra_deps.lst

    # --- BIOS target (i386-pc) -----------------------------------------------
    log "configuring GRUB for i386-pc (BIOS)"
    mkdir -p build-bios && cd build-bios
    ../configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --disable-werror \
        --with-platform=pc \
        --target=i386
    make
    make install
    cd ..

    # --- UEFI target (x86_64-efi) --------------------------------------------
    # Only install the module tree (/usr/lib/grub/x86_64-efi/) — the
    # grub-install / grub-mkconfig / grub-probe binaries from the BIOS build
    # are architecture-neutral wrappers that detect the module tree at runtime.
    # Overwriting them with the EFI-build copies is harmless but unnecessary.
    log "configuring GRUB for x86_64-efi (UEFI)"
    mkdir -p build-efi && cd build-efi
    ../configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --disable-werror \
        --with-platform=efi \
        --target=x86_64
    make
    make -C grub-core install   # module tree only
    cd ..

    log "GRUB i386-pc + x86_64-efi installed"
}

build_pkg 77.grub "grub-2." b_grub

# --- Install gozjaro-install -------------------------------------------------
# The repo root is bind-mounted at /gozjaro inside the chroot (stage 50).
if [ -f /gozjaro/tools/gozjaro-install ]; then
    install -v -m755 /gozjaro/tools/gozjaro-install /usr/bin/gozjaro-install
    log "gozjaro-install deployed to /usr/bin"
else
    die "tools/gozjaro-install not found at /gozjaro/tools/gozjaro-install"
fi
