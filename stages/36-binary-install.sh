#!/usr/bin/env bash
# Install the base system from pre-built binary packages using gozpak.
# Runs inside the chroot after 35-gozpak-bootstrap.
#
# This replaces stages 30/40/51/60 (cross-toolchain, temp-tools, chroot-tools,
# final-system) when building in binary mode. Instead of compiling ~80 packages
# from source, we fetch pre-built tarballs from a remote repository.
#
# Prerequisites: stage 35-gozpak-bootstrap (gozpak installed + repos configured)
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 36-binary-install
require_chroot
require_root

command -v gozpak >/dev/null 2>&1 || die "gozpak not found (run stage 35 first)"

# --- package list -------------------------------------------------------------
# The base system package list. These correspond to the LFS 12.3 final system
# (chapter 8) plus essential runtime packages. Names match the gozpak repo.
#
# Override by setting GOZPAK_BASE_PKGS to a file path.
PKG_LIST="${GOZPAK_BASE_PKGS:-$GOZJARO_ROOT/config/base-packages.txt}"

if [ -f "$PKG_LIST" ]; then
    log "reading package list from $PKG_LIST"
    pkgs=""
    while read -r pkg _; do
        case $pkg in \#*|'') continue ;; esac
        pkgs="$pkgs $pkg"
    done < "$PKG_LIST"
else
    log "using built-in base package list"
    pkgs="
        man-pages iana-etc glibc zlib bzip2 xz lz4 zstd file
        readline m4 bc flex tcl expect dejagnu pkgconf binutils
        gmp mpfr mpc attr acl libcap libxcrypt shadow
        gcc ncurses sed psmisc gettext bison grep bash
        libtool gdbm gperf expat inetutils less perl
        xml-parser intltool autoconf automake openssl kmod
        libelf libffi python3 flit-core wheel setuptools
        ninja meson coreutils check diffutils gawk findutils
        groff gzip iproute2 kbd libpipeline make patch
        man-db tar texinfo vim util-linux e2fsprogs sysklogd
        sysvinit eudev
    "
fi

# --- sync repositories -------------------------------------------------------
log "syncing package repositories"
if ! gozpak sync 2>&1; then
    war "repo sync failed — checking if repos are configured"
    if ! grep -qv '^#' /etc/gozpak/repos.conf 2>/dev/null; then
        die "no repositories configured in /etc/gozpak/repos.conf"
    fi
    die "failed to sync repositories (check network and repo URLs)"
fi

# --- install packages ---------------------------------------------------------
# Count packages.
set -- $pkgs
total=$#
log "installing $total base system packages"

failed=""
installed=0

for pkg in $pkgs; do
    installed=$((installed + 1))
    log "[$installed/$total] $pkg"

    if GOZPAK_PROMPT=0 gozpak get "$pkg" 2>&1; then
        log "$pkg: OK"
    else
        war "$pkg: FAILED"
        failed="$failed $pkg"
    fi
done

# --- report -------------------------------------------------------------------
if [ -n "$failed" ]; then
    war "the following packages failed to install:$failed"
    war "you may need to build these from source or fix the repository"
    # Don't die — partial installs can still be useful.
fi

# Show what's installed.
log "installed packages:"
gozpak list 2>&1 || true

log "binary install complete ($installed packages attempted)"
mark_done 36-binary-install
