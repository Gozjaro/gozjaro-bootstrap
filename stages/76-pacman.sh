#!/usr/bin/env bash
# Build the pacman package manager and its core dependency libarchive.
# Runs inside the chroot, after stage 75 (live tools — needs curl).
#
# GPG signature verification is intentionally disabled for v1: gpgme's
# dependency chain (libgpg-error, libassuan, libgcrypt, libksba, npth,
# gnupg) is substantial and will land in a follow-up change once the
# package manager and repo are proven end-to-end.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
# shellcheck source=../lib/pkg.sh
. "$GOZJARO_ROOT/lib/pkg.sh"

start_log 76-pacman
require_chroot
require_root

# ---- libarchive -------------------------------------------------------------

b_libarchive() {
    ./configure --prefix=/usr \
        --disable-static \
        --without-xml2 \
        --without-lzo2 \
        --without-nettle
    make
    make install
    # libarchive's autoconf sometimes installs a bsdtar wrapper; keep our
    # GNU tar from stage 60 as the default /usr/bin/tar.
    [ -x /usr/bin/bsdtar ] || true
}

# ---- pacman -----------------------------------------------------------------

b_pacman() {
    local src="$1"

    mkdir -v build && cd build
    meson setup .. \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --buildtype=release \
        -Ddoc=disabled \
        -Ddoxygen=disabled \
        -Di18n=false \
        -Dgpgme=disabled \
        -Dcrypto=openssl \
        -Dscriptlet-shell=/bin/bash \
        -Dldconfig=/sbin/ldconfig \
        -Dpkg-ext=.pkg.tar.zst \
        -Dsrc-ext=.src.tar.gz
    ninja
    ninja install

    # ---- /etc/pacman.conf ----
    if [ ! -f /etc/pacman.conf ]; then
        cat > /etc/pacman.conf <<'EOF'
#
# /etc/pacman.conf — Gozjaro defaults
# See pacman.conf(5) for the full option list.
#

[options]
HoldPkg        = pacman
Architecture   = x86_64
CheckSpace
ParallelDownloads = 5

# SigLevel is set to Never for v1 (no GPG stack built yet). Once gpgme
# and the repo signing key land, tighten to: SigLevel = Required DatabaseOptional
SigLevel          = Never
LocalFileSigLevel = Optional

# Repositories
[gozjaro-core]
Server = https://github.com/Gozjaro/gozjaro-pkgs/releases/download/repo
EOF
    fi

    # ---- /etc/makepkg.conf ----
    if [ ! -f /etc/makepkg.conf ]; then
        cat > /etc/makepkg.conf <<'EOF'
#
# /etc/makepkg.conf — Gozjaro defaults
#

CARCH="x86_64"
CHOST="x86_64-gozjaro-linux-gnu"

CPPFLAGS="-D_FORTIFY_SOURCE=2"
CFLAGS="-march=x86-64 -mtune=generic -O2 -pipe -fno-plt -fexceptions \
        -Wp,-D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security \
        -fstack-clash-protection -fcf-protection"
CXXFLAGS="$CFLAGS"
LDFLAGS="-Wl,-O1,--sort-common,--as-needed,-z,relro,-z,now"
LTOFLAGS="-flto=auto"
MAKEFLAGS="-j$(nproc)"

BUILDENV=(!distcc color !ccache check !sign)
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
INTEGRITY_CHECK=(sha256)

COMPRESSGZ=(gzip -c -f -n)
COMPRESSBZ2=(bzip2 -c -f)
COMPRESSXZ=(xz -c -z -)
COMPRESSZST=(zstd -c -T0 --ultra -20 -)

PKGEXT='.pkg.tar.zst'
SRCEXT='.src.tar.gz'
EOF
    fi

    # ---- state dirs ----
    install -dv /var/lib/pacman
    install -dv /var/cache/pacman/pkg
    install -dv /var/log

    log "pacman ready (SigLevel=Never; GPG stack pending)"
}

# ---- Invocations ------------------------------------------------------------

build_pkg 76.libarchive "libarchive-" b_libarchive
build_pkg 76.pacman     "pacman-"     b_pacman

log "package manager installed"
