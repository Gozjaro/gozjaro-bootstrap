#!/usr/bin/env bash
# Create the 'lfs' build user and hand over ownership of $LFS.
# Non-interactive: password is randomly set if unset. The user is NEVER entered
# interactively here — build.sh handles re-entry as 'lfs' via `su -l`.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 22-lfs-user
require_root

if ! getent group lfs >/dev/null; then
    groupadd lfs
fi
if ! id -u lfs >/dev/null 2>&1; then
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs
    # Lock the password; login is via `su -` from root only.
    passwd -l lfs >/dev/null
    log "created user 'lfs' (password locked)"
else
    log "user 'lfs' already exists"
fi

chown -R lfs:lfs "$LFS"/{usr,lib,var,etc,bin,sbin,tools,sources}
case $(uname -m) in
    x86_64) [ -d "$LFS/lib64" ] && chown -R lfs:lfs "$LFS/lib64" ;;
esac
# Our state/log dirs under $LFS/var already owned by lfs after the line above.
ensure_dirs
chown -R lfs:lfs "$LFS/var/gozjaro"

log "ownership handed to 'lfs'"
