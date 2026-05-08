#!/usr/bin/env bash
# Install gozpak into the LFS chroot and configure repositories.
# Runs inside the chroot. This is the entry point for binary-mode builds
# where packages are installed from a remote repo instead of compiled.
#
# Prerequisites: stage 50-chroot-prep (chroot is mounted and accessible)
# Output: /usr/bin/gozpak, /etc/gozpak/repos.conf
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 35-gozpak-bootstrap
require_chroot
require_root

# --- install gozpak itself ---------------------------------------------------
GOZPAK_SRC=""

# Look for gozpak in a few likely locations.
for _try in \
    /gozjaro/../gozpak/gozpak \
    /gozjaro/pkg/gozpak/gozpak \
    /root/gozpak/gozpak \
    /gozpak/gozpak; do
    if [ -f "$_try" ]; then
        GOZPAK_SRC="$_try"
        break
    fi
done

if [ -z "$GOZPAK_SRC" ]; then
    log "gozpak not found locally, downloading from GitHub"
    GOZPAK_SRC="/tmp/gozpak-download"
    if command -v curl >/dev/null 2>&1; then
        curl -fLo "$GOZPAK_SRC" \
            "https://github.com/Gozjaro/gozpak/releases/download/stable/gozpak"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$GOZPAK_SRC" \
            "https://github.com/Gozjaro/gozpak/releases/download/stable/gozpak"
    else
        die "No curl or wget available to download gozpak"
    fi
fi

log "installing gozpak to /usr/bin/gozpak"
install -Dm755 "$GOZPAK_SRC" /usr/bin/gozpak

# --- install contrib extensions ----------------------------------------------
CONTRIB_DIR=""
_gozpak_dir=$(dirname "$GOZPAK_SRC")
if [ -d "$_gozpak_dir/contrib" ]; then
    CONTRIB_DIR="$_gozpak_dir/contrib"
elif [ -d "$_gozpak_dir/../contrib" ]; then
    CONTRIB_DIR="$_gozpak_dir/../contrib"
fi

if [ -n "$CONTRIB_DIR" ]; then
    log "installing contrib extensions"
    for ext in "$CONTRIB_DIR"/gozpak-*; do
        [ -f "$ext" ] || continue
        install -Dm755 "$ext" "/usr/bin/$(basename "$ext")"
    done
fi

# --- create package database directories -------------------------------------
mkdir -p /var/db/gozpak/installed
mkdir -p /var/db/gozpak/choices

# --- configure repositories --------------------------------------------------
mkdir -p /etc/gozpak

if [ -n "${GOZPAK_REPOS:-}" ]; then
    log "writing repos.conf from GOZPAK_REPOS"
    printf '%s\n' "$GOZPAK_REPOS" | tr ':' '\n' > /etc/gozpak/repos.conf
else
    log "writing default repos.conf"
    cat > /etc/gozpak/repos.conf <<'REPOS'
# Gozjaro package repositories.
# One URL per line. Lines starting with # are comments.
#
# Official repo:
https://github.com/Gozjaro/gozjaro-repo/releases/download/stable
#
# To use a local repo, point GOZPAK_PATH to the directory instead.
REPOS
fi

# Verify installation.
gozpak v >/dev/null 2>&1 || die "gozpak installation failed"
log "gozpak $(gozpak v) installed successfully"

mark_done 35-gozpak-bootstrap
