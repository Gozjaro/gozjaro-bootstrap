#!/usr/bin/env bash
# Write ~/.bash_profile and ~/.bashrc for the lfs user.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 23-env
require_root

lfs_home=$(getent passwd lfs | cut -d: -f6)
[ -n "$lfs_home" ] || die "lfs user missing (run stage 22 first)"

install -o lfs -g lfs -m 644 /dev/stdin "$lfs_home/.bash_profile" <<'EOF'
if [ -n "$BASH_EXECUTION_STRING" ]; then
    exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' GOZJARO_ROOT=$GOZJARO_ROOT /bin/bash -c "$BASH_EXECUTION_STRING"
fi
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF

install -o lfs -g lfs -m 644 /dev/stdin "$lfs_home/.bashrc" <<EOF
set +h
umask 022
LFS=${LFS}
LC_ALL=POSIX
LFS_TGT=\$(uname -m)-${DISTRO_ID}-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:\$PATH; fi
PATH=\$LFS/tools/bin:\$PATH
CONFIG_SITE=\$LFS/usr/share/config.site
MAKEFLAGS=-j\$(nproc)
GOZJARO_ROOT=${GOZJARO_ROOT}
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE MAKEFLAGS GOZJARO_ROOT
EOF

log "wrote bash profile/rc for lfs (LFS=$LFS, TGT=\$(uname -m)-${DISTRO_ID}-linux-gnu)"
