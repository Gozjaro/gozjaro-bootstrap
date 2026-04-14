#!/usr/bin/env bash
# Chapter 7: inside the chroot — essential files, then gettext, bison, perl,
# python, texinfo, util-linux; followed by cleanup (strip + docs removal).
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
# shellcheck source=../lib/pkg.sh
. "$GOZJARO_ROOT/lib/pkg.sh"

start_log 51-chroot-tools
require_chroot
require_root

# --- 7.5/7.6 Creating Directories & Essential Files ---------------------------
if ! is_done 51.skeleton; then
    step "creating directory skeleton and essential files"
    mkdir -pv /{boot,home,mnt,opt,srv}
    mkdir -pv /etc/{opt,sysconfig}
    mkdir -pv /lib/firmware
    mkdir -pv /media/{floppy,cdrom}
    mkdir -pv /usr/{,local/}{include,src}
    mkdir -pv /usr/lib/locale
    mkdir -pv /usr/local/{bin,lib,sbin}
    mkdir -pv /usr/{,local/}share/{color,dict,doc,info,locale,man}
    mkdir -pv /usr/{,local/}share/{misc,terminfo,zoneinfo}
    mkdir -pv /usr/{,local/}share/man/man{1..8}
    mkdir -pv /var/{cache,local,log,mail,opt,spool}
    mkdir -pv /var/lib/{color,misc,locate}
    ln -sfv /run /var/run
    ln -sfv /run/lock /var/lock
    install -dv -m 0750 /root
    install -dv -m 1777 /tmp /var/tmp

    ln -sv /proc/self/mounts /etc/mtab
    cat > /etc/hosts <<EOF
127.0.0.1  localhost ${DISTRO_ID}
::1        localhost
EOF
    cat > /etc/passwd <<'EOF'
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF
    cat > /etc/group <<'EOF'
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
input:x:24:
mail:x:34:
kvm:x:61:
uuidd:x:80:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF
    localedef -i C -f UTF-8 C.UTF-8 || true
    touch /var/log/{btmp,lastlog,faillog,wtmp}
    chgrp -v utmp /var/log/lastlog
    chmod -v 664  /var/log/lastlog
    chmod -v 600  /var/log/btmp
    mark_done 51.skeleton
fi

# --- Package builders (Ch. 7.7–7.12) -----------------------------------------

b_gettext() {
    ./configure --disable-shared
    make
    cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
}

b_bison() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/bison-3.8.2
    make
    make install
}

b_perl() {
    sh Configure -des \
        -Dprefix=/usr \
        -Dvendorprefix=/usr \
        -Duseshrplib \
        -Dprivlib=/usr/lib/perl5/5.40/core_perl \
        -Darchlib=/usr/lib/perl5/5.40/core_perl \
        -Dsitelib=/usr/lib/perl5/5.40/site_perl \
        -Dsitearch=/usr/lib/perl5/5.40/site_perl \
        -Dvendorlib=/usr/lib/perl5/5.40/vendor_perl \
        -Dvendorarch=/usr/lib/perl5/5.40/vendor_perl
    make
    make install
}

b_python() {
    ./configure --prefix=/usr \
        --enable-shared \
        --without-ensurepip
    make
    make install
}

b_texinfo() {
    ./configure --prefix=/usr
    make
    make install
}

b_util_linux() {
    mkdir -pv /var/lib/hwclock
    ./configure --libdir=/usr/lib \
        --runstatedir=/run \
        --disable-chfn-chsh \
        --disable-login \
        --disable-nologin \
        --disable-su \
        --disable-setpriv \
        --disable-runuser \
        --disable-pylibmount \
        --disable-static \
        --disable-liblastlog2 \
        --without-python \
        ADJTIME_PATH=/var/lib/hwclock/adjtime \
        --docdir=/usr/share/doc/util-linux-2.40.4
    make
    make install
}

build_pkg 51.gettext     "gettext-"     b_gettext
build_pkg 51.bison       "bison-"       b_bison
build_pkg 51.perl        "perl-"        b_perl
build_pkg 51.python      "Python-"      b_python
build_pkg 51.texinfo     "texinfo-"     b_texinfo
build_pkg 51.util-linux  "util-linux-"  b_util_linux

# --- Ch. 7.13 cleanup --------------------------------------------------------
if ! is_done 51.cleanup; then
    step "stripping binaries and removing docs"
    rm -rf /usr/share/{info,man,doc}/*
    find /usr/{lib,libexec} -name \*.la -delete || true
    rm -rf /tools
    mark_done 51.cleanup
fi

log "chroot tools complete"
