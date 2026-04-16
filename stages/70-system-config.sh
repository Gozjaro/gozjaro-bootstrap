#!/usr/bin/env bash
# Chapter 9: system configuration — /etc/* files, fstab, systemd units, profile.
# Runs inside chroot. Assumes systemd is installed (stage 60).
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
# Live-ISO-friendly: root is overlayfs over squashfs (no disk to fsck).
# systemd mounts cgroup2 on its own; no need to list it here.
cat > /etc/fstab <<'EOF'
# <device>        <mount>         <type>    <options>                 <dump> <fsck>
overlay           /               overlay   defaults                       0      0
proc              /proc           proc      nosuid,noexec,nodev            0      0
sysfs             /sys            sysfs     nosuid,noexec,nodev            0      0
devpts            /dev/pts        devpts    gid=5,mode=620                 0      0
tmpfs             /run            tmpfs     defaults                       0      0
devtmpfs          /dev            devtmpfs  mode=0755,nosuid               0      0
tmpfs             /dev/shm        tmpfs     nosuid,nodev                   0      0
EOF

# --- systemd configuration ---------------------------------------------------

# Ensure machine-id exists (needed by journald, dbus, etc.)
[ -f /etc/machine-id ] || systemd-machine-id-setup 2>/dev/null || \
    dbus-uuidgen --ensure=/etc/machine-id || true

# Set the default target to multi-user (runlevel 3 equivalent).
mkdir -p /etc/systemd/system
ln -sfv /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target

# Enable systemd-networkd for DHCP on all ethernet interfaces.
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/80-dhcp.network <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes

[DHCPv4]
UseDomains=yes
EOF

# Enable systemd-resolved for DNS.
ln -sfv /run/systemd/resolve/resolv.conf /etc/resolv.conf

# Enable essential services.
mkdir -p /etc/systemd/system/multi-user.target.wants
mkdir -p /etc/systemd/system/network-online.target.wants
mkdir -p /etc/systemd/system/sockets.target.wants
mkdir -p /etc/systemd/system/sysinit.target.wants

for svc in systemd-networkd systemd-resolved; do
    ln -sfv "/usr/lib/systemd/system/${svc}.service" \
        "/etc/systemd/system/multi-user.target.wants/${svc}.service" 2>/dev/null || true
done

# Enable getty on tty1 with autologin for the live ISO.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

# Journal: volatile storage only (live ISO has no persistent /var/log/journal).
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/live.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=30M
EOF

# Disable services that are unnecessary or harmful on a live ISO.
for svc in systemd-firstboot systemd-sysupdate; do
    ln -sfv /dev/null "/etc/systemd/system/${svc}.service" 2>/dev/null || true
done

# Locale configuration (systemd reads /etc/locale.conf).
cat > /etc/locale.conf <<'EOF'
LANG=C.UTF-8
EOF

# Virtual console (systemd reads /etc/vconsole.conf).
cat > /etc/vconsole.conf <<'EOF'
KEYMAP=us
EOF

# Timezone symlink.
[ -L /etc/localtime ] || ln -sfv /usr/share/zoneinfo/UTC /etc/localtime

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

log "system configuration written (systemd)"
