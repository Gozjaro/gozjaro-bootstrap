#!/usr/bin/env bash
# Create the FHS directory skeleton under $LFS.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 21-layout
require_root

mountpoint -q "$LFS" || die "$LFS is not mounted (run stage 10 first)"

mkdir -pv "$LFS"/{etc,var} "$LFS"/usr/{bin,lib,sbin}
mkdir -pv "$LFS"/usr/{include,libexec,share,src}
mkdir -pv "$LFS"/usr/share/{doc,info,locale,man,misc,terminfo,zoneinfo}
mkdir -pv "$LFS"/var/{cache,lib,local,log,mail,opt,spool}
mkdir -pv "$LFS"/var/lib/{color,misc,locate}
mkdir -pv "$LFS"/{boot,home,mnt,opt,srv}
mkdir -pv "$LFS"/etc/{opt,sysconfig}
mkdir -pv "$LFS"/media/{floppy,cdrom}
mkdir -pv "$LFS"/usr/local/{bin,include,lib,sbin,share,src}

for i in bin lib sbin; do
    [ -L "$LFS/$i" ] || ln -sv "usr/$i" "$LFS/$i"
done

case $(uname -m) in
    x86_64) mkdir -pv "$LFS/lib64" ;;
esac

mkdir -pv "$LFS/tools"
mkdir -pv "$LFS/var/tmp"
chmod 1777 "$LFS/var/tmp"
ensure_dirs

log "layout created"
