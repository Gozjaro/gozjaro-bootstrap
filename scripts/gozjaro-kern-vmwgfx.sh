#!/bin/sh
# gozjaro-kern-vmwgfx.sh — GozJaro kernel hotfix: add the VMware display
# driver (vmwgfx) to the *running* kernel version, in place.
#
# What it does:
#   1. Rebuilds the running kernel version (uname -r) with the same recipe
#      the GozJaro pipeline uses (make defconfig + the live-boot forced
#      options from stages/80-kernel.sh), plus CONFIG_DRM_VMWGFX=m.
#   2. Installs the module tree in place (same version -> same /boot names,
#      so the existing GRUB entry and initramfs keep working: the GozJaro
#      initramfs ships no modules, all boot-critical drivers are built-in
#      and are unchanged by this hotfix).
#   3. Backs up the old vmlinuz, installs the new one under the same name.
#   4. Adds vmwgfx to /etc/modules-load.d so it loads at boot (the driver
#      appears as /dev/dri/card0 and gives X11/Wayland GPU acceleration on
#      VMware).
#   5. X11 side: writes a modesetting /etc/X11/xorg.conf (full DRM mode
#      table instead of the fbdev driver's stuck framebuffer default),
#      builds xrandr if missing, and drops a session autostart entry that
#      switches the desktop to 1920x1080.
#   6. Reboots into the new kernel (pass --no-reboot to skip).
#
# WARNING: never `rmmod vmwgfx`. The driver's exit path can oops the
# kernel (irqs-disabled BUG) on this SVGA2 hardware. To replace the
# module, reboot first, then install the new .ko.
#
# Usage (on the installed system, as root):
#   sh gozjaro-kern-vmwgfx.sh            # build + install + reboot
#   sh gozjaro-kern-vmwgfx.sh --no-reboot
#
# Requires: gcc, make, curl, internet access to kernel.org.
# Takes roughly 10-20 minutes on a 6-core machine (kernel build).
set -eu

KVER="${KVER:-$(uname -r)}"
SRC=/usr/local/src/linux-$KVER
NPROC=$(nproc 2>/dev/null || echo 4)
REBOOT=1
[ "${1:-}" = "--no-reboot" ] && REBOOT=0

log() { printf '[gozjaro-kern-vmwgfx] %s\n' "$*"; }
die() { printf '[gozjaro-kern-vmwgfx] FATAL: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "must run as root"

# --- 1. kernel source (same version as the running kernel) -----------------
if [ ! -d "$SRC" ]; then
  log "fetching linux-$KVER sources ..."
  mkdir -p /usr/local/src && cd /usr/local/src
  curl -fsSLO "https://www.kernel.org/pub/linux/kernel/v7.x/linux-$KVER.tar.xz"
  xz -dc "linux-$KVER.tar.xz" | tar xf -
fi
cd "$SRC"
[ -f Makefile ] || die "kernel source tree not found at $SRC"

# --- 2. configure: pipeline recipe + vmwgfx --------------------------------
# Same base as the pipeline's stages/80-kernel.sh (defconfig + the full forced
# option list, 1:1), so the resulting kernel behaves exactly like the one
# currently installed, with vmwgfx added on top.
log "configuring (defconfig + pipeline forced options + DRM_VMWGFX=m)"
make -s defconfig
./scripts/config \
    --enable SQUASHFS \
        --enable SQUASHFS_XZ \
        --enable SQUASHFS_ZSTD \
        --enable SQUASHFS_XATTR \
        --enable ISO9660_FS \
        --enable JOLIET \
        --enable ZISOFS \
        --enable OVERLAY_FS \
        --enable BLK_DEV_LOOP \
        --enable EXT4_FS \
        --enable DEVTMPFS \
        --enable DEVTMPFS_MOUNT \
        --enable TMPFS \
        --enable TMPFS_POSIX_ACL \
        --enable BLK_DEV_SR \
        --enable CDROM \
        --enable USB_STORAGE \
        --enable USB_UAS \
        --enable SCSI \
        --enable BLK_DEV_SD \
        --enable BLK_DEV_NVME \
        --enable NVME_CORE \
        --enable EFI \
        --enable EFI_STUB \
        --enable EFI_MIXED \
        --enable EFIVAR_FS \
        --enable EFI_VARS_PSTORE \
        --enable FB \
        --enable FB_EFI \
        --enable FB_VESA \
        --enable FB_SIMPLE \
        --enable FRAMEBUFFER_CONSOLE \
        --enable FRAMEBUFFER_CONSOLE_DETECT_PRIMARY \
        --enable SYSFB_SIMPLEFB \
        --enable DRM \
        --enable DRM_FBDEV_EMULATION \
        --enable PCI \
        --enable PCI_MSI \
        --enable ATA \
        --enable SATA_AHCI \
        --enable ATA_PIIX \
        --enable SCSI_LOWLEVEL \
        --enable VIRTIO \
        --enable VIRTIO_PCI \
        --enable VIRTIO_BLK \
        --enable VIRTIO_SCSI \
        --enable VMWARE_PVSCSI \
        --enable HYPERV \
        --enable HYPERV_STORAGE \
        --enable FUSION_SPI \
        --enable SCSI_MPT3SAS \
        --enable SCSI_BUSLOGIC \
        --enable CGROUPS \
        --enable CGROUP_BPF \
        --enable CGROUP_FREEZER \
        --enable CGROUP_PIDS \
        --enable CGROUP_DEVICE \
        --enable CGROUP_CPUACCT \
        --enable CGROUP_PERF \
        --enable CGROUP_SCHED \
        --enable MEMCG \
        --enable BPF_SYSCALL \
        --enable NAMESPACES \
        --enable USER_NS \
        --enable PID_NS \
        --enable IPC_NS \
        --enable NET_NS \
        --enable UTS_NS \
        --enable SECCOMP \
        --enable SECCOMP_FILTER \
        --enable INOTIFY_USER \
        --enable SIGNALFD \
        --enable TIMERFD \
        --enable EPOLL \
        --enable FHANDLE \
        --enable CRYPTO_USER_API_HASH \
        --enable CRYPTO_HMAC \
        --enable CRYPTO_SHA256 \
        --enable DMIID \
        --enable AUTOFS_FS \
        --enable TMPFS_XATTR \
        --enable NET_SCHED \
        --enable NET_CLS_CGROUP \
        --enable FAIR_GROUP_SCHED \
        --enable IPV6 \
        --enable UNIX
# The hotfix itself: VMware's SVGA/GPU display driver (module, auto-loaded at
# boot via /etc/modules-load.d, see step 4).
./scripts/config --module DRM_VMWGFX
grep -q "^CONFIG_DRM_VMWGFX=m$" .config || die "DRM_VMWGFX not enabled in .config (symbol missing in this kernel tree?)"
make -s olddefconfig

# --- 3. build + install in place --------------------------------------------
log "building (this is the long part, -j$NPROC)"
make -s -j"$NPROC" bzImage modules
log "installing modules (keeping version $KVER)"
[ -f /boot/vmlinuz-$KVER ] || die "/boot/vmlinuz-$KVER not found"
[ -f /boot/vmlinuz-$KVER.pre-vmwgfx.bak ] || \
  cp -a /boot/vmlinuz-$KVER /boot/vmlinuz-$KVER.pre-vmwgfx.bak
install -m 755 arch/x86/boot/bzImage /boot/vmlinuz-$KVER
install -m 644 .config /boot/config-$KVER
make -s modules_install
depmod -b / "$KVER" || depmod "$KVER"
log "module installed: $(ls /lib/modules/$KVER/kernel/drivers/gpu/drm/vmwgfx/ 2>/dev/null | head -1)"

# --- 4. load at boot ----------------------------------------------------------
mkdir -p /etc/modules-load.d
echo "vmwgfx" > /etc/modules-load.d/vmware-gfx.conf
log "vmwgfx will auto-load at boot (/etc/modules-load.d/vmware-gfx.conf)"

# --- 5. optional: load now + verify ------------------------------------------
if modprobe -n -v vmwgfx 2>/dev/null | grep -q "insmod\|install"; then
  modprobe vmwgfx 2>/dev/null && log "vmwgfx loaded in the running kernel" \
    || log "vmwgfx not loaded yet (new module; takes effect after reboot)"
fi

# --- 5b. X11 side: modesetting + xrandr + 1920x1080 at session start --------
# vmwgfx only gives the kernel a DRM node. X on this system defaults to the
# fbdev driver, which is stuck at the framebuffer default mode (typically
# 1280x800). A modesetting /etc/X11/xorg.conf gives X the full DRM mode
# table (up to 4096x2160); a session autostart entry switches the desktop
# to 1920x1080 on every login. Best effort: skipped when no X tree exists.
if [ -d /usr/lib/xorg ] || [ -d /usr/lib/X11 ]; then
  log "writing /etc/X11/xorg.conf (modesetting driver for VMware SVGA)"
  mkdir -p /etc/X11
  rm -f /etc/X11/xorg.conf.d/*.conf 2>/dev/null || true
  cat > /etc/X11/xorg.conf <<'CONF'
Section "Device"
    Identifier "VMware GPU"
    Driver "modesetting"
EndSection

Section "Screen"
    Identifier "VMware Screen"
    Device "VMware GPU"
    DefaultDepth 24
EndSection

Section "ServerLayout"
    Identifier "VMware Layout"
    Screen "VMware Screen"
EndSection
CONF

  if [ ! -x /usr/local/bin/xrandr ] && ! command -v xrandr >/dev/null 2>&1; then
    log "building xrandr from x11-xserver-utils"
    XU=/usr/local/src/x11-xserver-utils
    if [ ! -d "$XU/xrandr" ]; then
      mkdir -p /usr/local/src && cd /usr/local/src
      OK=0
      for U in \
        "http://192.168.71.36:8765/x11-xserver-utils-src.tar.gz" \
        "https://archive.debian.org/debian/pool/main/x/x11-xserver-utils/x11-xserver-utils_7.3+6.tar.gz" \
        "https://deb.debian.org/debian/pool/main/x/x11-xserver-utils/x11-xserver-utils_7.3+6.tar.gz"
      do
        curl -fsSLO x11-xserver-utils-src.tar.gz "$U" && OK=1 && break
      done
      cd - || true
      [ "$OK" = "1" ] || { log "WARN: x11-xserver-utils unavailable; skipping xrandr build"; OK=0; }
      [ "$OK" = "1" ] && tar xzf /usr/local/src/x11-xserver-utils-src.tar.gz -C /usr/local/src
    fi
    if [ -d "$XU/xrandr" ]; then
      cd "$XU/xrandr"
      ( ./configure --prefix=/usr/local && make -j"$NPROC" && make install ) || \
        ( command -v autoconf >/dev/null 2>&1 && autoconf && \
          ./configure --prefix=/usr/local && make -j"$NPROC" && make install ) || \
        log "WARN: xrandr build failed (X11 dev headers missing?)"
      cd - || true
      log "xrandr: $(command -v xrandr 2>/dev/null || echo /usr/local/bin/xrandr)"
    fi
  fi

  DESKUSER=$(awk -F: '$3>=1000 && $1!="nobody" {print $1; exit}' /etc/passwd)
  if [ -n "$DESKUSER" ]; then
    H=/home/$DESKUSER
    mkdir -p "$H/.config/autostart"
    cat > "$H/.config/autostart/set-1080p.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=Set 1080p
Comment=GozJaro: switch VMware virtual display to 1920x1080 at session start
Exec=xrandr --output Virtual-1 --mode 1920x1080
Terminal=false
NoDisplay=true
DESK
    chown -R "$DESKUSER" "$H/.config/autostart" 2>/dev/null || true
    log "session autostart 1920x1080 written for $DESKUSER"
  fi
fi

# --- 6. reboot ----------------------------------------------------------------
if [ "$REBOOT" = "1" ]; then
  log "rebooting into the updated kernel (verify after boot: lsmod | grep vmwgfx; ls /dev/dri/; xrandr)"
  exec /sbin/reboot
else
  log "done. Reboot when ready: reboot"
fi
