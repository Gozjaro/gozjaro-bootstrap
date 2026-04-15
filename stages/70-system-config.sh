#!/usr/bin/env bash
# Chapter 9: system configuration — /etc/* files, fstab, inittab, profile.
# Runs inside chroot. Assumes lfs-bootscripts is installed.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 70-system-config
require_chroot
require_root

# --- /etc/hostname -----------------------------------------------------------
HOSTNAME_DEFAULT="${DISTRO_ID}"
: "${GOZJARO_HOSTNAME:=$HOSTNAME_DEFAULT}"
echo "$GOZJARO_HOSTNAME" > /etc/hostname

# --- /etc/hosts --------------------------------------------------------------
cat > /etc/hosts <<EOF
127.0.0.1   localhost.localdomain localhost
127.0.1.1   ${GOZJARO_HOSTNAME}.localdomain ${GOZJARO_HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# --- /etc/resolv.conf (placeholder) -----------------------------------------
cat > /etc/resolv.conf <<'EOF'
# Replace with your real resolver(s).
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF

# --- /etc/inittab (SysV) -----------------------------------------------------
cat > /etc/inittab <<'EOF'
id:3:initdefault:

si::sysinit:/etc/rc.d/init.d/rc S
l0:0:wait:/etc/rc.d/init.d/rc 0
l1:S1:wait:/etc/rc.d/init.d/rc 1
l2:2:wait:/etc/rc.d/init.d/rc 2
l3:3:wait:/etc/rc.d/init.d/rc 3
l4:4:wait:/etc/rc.d/init.d/rc 4
l5:5:wait:/etc/rc.d/init.d/rc 5
l6:6:wait:/etc/rc.d/init.d/rc 6

ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now
su:S016:once:/sbin/sulogin

1:2345:respawn:/sbin/agetty --noclear tty1 9600
2:2345:respawn:/sbin/agetty tty2 9600
3:2345:respawn:/sbin/agetty tty3 9600
4:2345:respawn:/sbin/agetty tty4 9600
5:2345:respawn:/sbin/agetty tty5 9600
6:2345:respawn:/sbin/agetty tty6 9600
EOF

# --- /etc/sysconfig/clock, network, rc.site ---------------------------------
mkdir -p /etc/sysconfig
cat > /etc/sysconfig/clock <<'EOF'
UTC=1
CLOCKPARAMS=
EOF

cat > /etc/sysconfig/network <<EOF
HOSTNAME=${GOZJARO_HOSTNAME}
EOF

cat > /etc/sysconfig/rc.site <<EOF
DISTRO="${DISTRO_NAME}"
DISTRO_CONTACT="root@${GOZJARO_HOSTNAME}"
DISTRO_MINI="${DISTRO_ID}"
EOF

# --- /etc/profile ------------------------------------------------------------
cat > /etc/profile <<'EOF'
export LANG=C.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
if [ "$(id -u)" = "0" ]; then
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
fi
umask 022
PS1='\u@\h:\w\$ '
EOF

# --- /etc/inputrc ------------------------------------------------------------
cat > /etc/inputrc <<'EOF'
set horizontal-scroll-mode Off
set meta-flag On
set input-meta On
set convert-meta Off
set output-meta On
set bell-style none
"\eOd": backward-word
"\eOc": forward-word
"\e[1~": beginning-of-line
"\e[4~": end-of-line
"\e[5~": beginning-of-history
"\e[6~": end-of-history
"\e[3~": delete-char
"\e[2~": quoted-insert
EOF

# --- /etc/shells -------------------------------------------------------------
cat > /etc/shells <<'EOF'
/bin/sh
/bin/bash
EOF

# --- /etc/fstab --------------------------------------------------------------
# Live-ISO-friendly: root is overlayfs over squashfs (no disk to fsck),
# /sys/fs/cgroup must be listed or lfs-bootscripts' mountvirtfs fails.
cat > /etc/fstab <<'EOF'
# <device>        <mount>         <type>    <options>                 <dump> <fsck>
overlay           /               overlay   defaults                       0      0
proc              /proc           proc      nosuid,noexec,nodev            0      0
sysfs             /sys            sysfs     nosuid,noexec,nodev            0      0
devpts            /dev/pts        devpts    gid=5,mode=620                 0      0
tmpfs             /run            tmpfs     defaults                       0      0
devtmpfs          /dev            devtmpfs  mode=0755,nosuid               0      0
tmpfs             /dev/shm        tmpfs     nosuid,nodev                   0      0
cgroup2           /sys/fs/cgroup  cgroup2   nosuid,nodev,noexec            0      0
EOF

# --- udev binary path fixup --------------------------------------------------
# lfs-bootscripts' S10udev calls /sbin/udevd and /sbin/udevadm. On merged-usr
# layouts eudev may have installed under /usr/bin or /usr/sbin; symlink so
# both paths work regardless.
for bin in udevd udevadm; do
    if [ ! -e "/sbin/$bin" ]; then
        for src in "/usr/sbin/$bin" "/usr/bin/$bin" "/bin/$bin" "/lib/udev/$bin" "/lib/systemd/systemd-$bin"; do
            if [ -x "$src" ]; then
                ln -sf "$src" "/sbin/$bin"
                log "symlinked /sbin/$bin -> $src"
                break
            fi
        done
    fi
done
# If we still don't have udevd, warn loudly — live boot will show failures
# but sysvinit will keep going (we patched S10udev behaviour below).
[ -e /sbin/udevd ] || warn "udevd not found anywhere; udev will be disabled on boot"

# --- defang bootscripts that assume a real disk ------------------------------
# Skip 'Mounting root filesystem read-only' and fsck — there is no disk.
if [ -f /etc/rc.d/init.d/mountfs ]; then
    # Neuter by making it a no-op script (keep the file so the symlinks resolve).
    cat > /etc/rc.d/init.d/mountfs <<'EOF'
#!/bin/bash
# Live-ISO: root is overlay, nothing to remount.
exit 0
EOF
    chmod 755 /etc/rc.d/init.d/mountfs
fi
if [ -f /etc/rc.d/init.d/checkfs ]; then
    cat > /etc/rc.d/init.d/checkfs <<'EOF'
#!/bin/bash
# Live-ISO: no filesystem to check.
exit 0
EOF
    chmod 755 /etc/rc.d/init.d/checkfs
fi
if [ -f /etc/rc.d/init.d/swap ]; then
    cat > /etc/rc.d/init.d/swap <<'EOF'
#!/bin/bash
# Live-ISO: no swap.
exit 0
EOF
    chmod 755 /etc/rc.d/init.d/swap
fi
# eudev was never built into the system, so /sbin/udevd doesn't exist.
# devtmpfs (mounted by the kernel at boot) already populates /dev with
# the nodes we need — the udev bootscript is unnecessary for a live boot.
if [ -f /etc/rc.d/init.d/udev ]; then
    cat > /etc/rc.d/init.d/udev <<'EOF'
#!/bin/bash
# Live-ISO: no udev; devtmpfs provides /dev.
exit 0
EOF
    chmod 755 /etc/rc.d/init.d/udev
fi
if [ -f /etc/rc.d/init.d/cleanfs ]; then
    # cleanfs walks /tmp, /var/run, /var/lock and fails on missing dirs in
    # the fresh overlay. Ensure the dirs exist and make cleanfs tolerant.
    cat > /etc/rc.d/init.d/cleanfs <<'EOF'
#!/bin/bash
# Live-ISO: ensure standard volatile dirs exist; do not attempt cleanup.
mkdir -p /tmp /var/run /var/lock /var/log 2>/dev/null || true
chmod 1777 /tmp 2>/dev/null || true
exit 0
EOF
    chmod 755 /etc/rc.d/init.d/cleanfs
fi
if [ -f /etc/rc.d/init.d/udev_retry ]; then
    cat > /etc/rc.d/init.d/udev_retry <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod 755 /etc/rc.d/init.d/udev_retry
fi

# --- os-release --------------------------------------------------------------
cat > /etc/os-release <<EOF
NAME="${DISTRO_NAME}"
ID=${DISTRO_ID}
VERSION="${DISTRO_VERSION}"
PRETTY_NAME="${DISTRO_NAME} ${DISTRO_VERSION}"
EOF

# --- /etc/issue --------------------------------------------------------------
cat > /etc/issue <<EOF
${DISTRO_NAME} ${DISTRO_VERSION} \\n \\l

EOF

# --- root password -----------------------------------------------------------
# GOZJARO_ROOT_PASSWORD can be set to override; defaults to "gozjaro".
: "${GOZJARO_ROOT_PASSWORD:=gozjaro}"
echo "root:${GOZJARO_ROOT_PASSWORD}" | chpasswd
log "root password set (default: 'gozjaro' — change it!)"

# Allow empty password logins on tty as a belt-and-braces fallback for the
# live ISO; harmless here since the password is already set above.
sed -i 's/^\(1:2345:respawn:\/sbin\/agetty\) --noclear/\1 --noclear --autologin root/' /etc/inittab 2>/dev/null || true

log "system configuration written"
log "NOTE: kernel build and bootloader installation are out of scope; perform them manually."
