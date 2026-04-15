#!/usr/bin/env bash
# Chapter 8: build the final system inside the chroot.
# One builder function per package; `build_pkg` handles extract, cd, and marker.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
# shellcheck source=../lib/pkg.sh
. "$GOZJARO_ROOT/lib/pkg.sh"

start_log 60-final-system
require_chroot
require_root

# ---- Docs / data packages ----------------------------------------------------

b_man_pages() { make -R prefix=/usr install; }

b_iana_etc() {
    cp services protocols /etc
}

b_tzdata() {
    local src="$1"
    ZONEINFO=/usr/share/zoneinfo
    mkdir -pv "$ZONEINFO"/{posix,right}
    for tz in etcetera southamerica northamerica europe africa antarctica asia australasia backward; do
        zic -L /dev/null   -d "$ZONEINFO"        "$tz"
        zic -L /dev/null   -d "$ZONEINFO/posix"  "$tz"
        zic -L leapseconds -d "$ZONEINFO/right"  "$tz"
    done
    cp -v zone.tab zone1970.tab iso3166.tab "$ZONEINFO"
    zic -d "$ZONEINFO" -p America/New_York
    unset ZONEINFO
    ln -sfv /usr/share/zoneinfo/UTC /etc/localtime
}

# ---- Glibc (final) -----------------------------------------------------------

b_glibc_final() {
    local src="$1"
    apply_patch "$src" "glibc-2.41-fhs-1.patch"
    mkdir -v build && cd build
    echo "rootsbindir=/usr/sbin" > configparms
    ../configure --prefix=/usr \
        --disable-werror \
        --enable-kernel=4.19 \
        --enable-stack-protector=strong \
        --disable-nscd \
        libc_cv_slibdir=/usr/lib
    make
    make check || true
    touch /etc/ld.so.conf
    sed '/test-installation/s@$(PERL)@echo not running@' -i ../Makefile
    make install
    sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd
    cp -v ../nscd/nscd.conf /etc/nscd.conf
    mkdir -pv /var/cache/nscd
    make localedata/install-locales || true
    cat >> /etc/nsswitch.conf <<'EOF'
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
EOF
    cat > /etc/ld.so.conf <<'EOF'
/usr/local/lib
/opt/lib
include /etc/ld.so.conf.d/*.conf
EOF
    mkdir -pv /etc/ld.so.conf.d
}

# ---- Libraries ---------------------------------------------------------------

b_zlib() {
    ./configure --prefix=/usr
    make; make install
    rm -fv /usr/lib/libz.a
}

b_bzip2() {
    apply_patch "$PWD" "bzip2-1.0.8-install_docs-1.patch" || true
    sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
    sed -i 's@(PREFIX)/man@(PREFIX)/share/man@g' Makefile
    make -f Makefile-libbz2_so
    make clean
    make
    make PREFIX=/usr install
    cp -av libbz2.so.* /usr/lib
    ln -sv libbz2.so.1.0.8 /usr/lib/libbz2.so
    cp -v bzip2-shared /usr/bin/bzip2
    for i in /usr/bin/{bzcat,bunzip2}; do
        ln -sfv bzip2 "$i"
    done
    rm -fv /usr/lib/libbz2.a
}

b_xz_final() {
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/xz-5.6.4
    make; make install
}

b_zstd() {
    make prefix=/usr && make prefix=/usr install
    rm -v /usr/lib/libzstd.a
}

b_file_final() {
    ./configure --prefix=/usr
    make; make install
}

b_readline() {
    sed -i '/MV.*old/d' Makefile.in
    sed -i '/{OLDSUFF}/c:' support/shlib-install
    sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf
    ./configure --prefix=/usr --disable-static --with-curses --docdir=/usr/share/doc/readline-8.2.13
    make SHLIB_LIBS="-lncursesw"
    make install
}

b_m4_final() { ./configure --prefix=/usr && make && make install; }

b_bc() {
    CC=gcc ./configure --prefix=/usr -G -O3 -r
    make; make install
}

b_flex() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/flex-2.6.4 --disable-static
    make; make install
    ln -sv flex   /usr/bin/lex
    ln -sv flex.1 /usr/share/man/man1/lex.1 || true
}

b_tcl() {
    SRCDIR=$(pwd)
    cd unix
    ./configure --prefix=/usr --mandir=/usr/share/man --disable-rpath
    make
    sed -e "s|$SRCDIR/unix|/usr/lib|" -e "s|$SRCDIR|/usr/include|" -i tclConfig.sh
    make install
    chmod -v u+w /usr/lib/libtcl8.6.so
    make install-private-headers
    ln -sfv tclsh8.6 /usr/bin/tclsh
    mv /usr/share/man/man3/{Thread,Tcl_Thread}.3 || true
}

b_expect() {
    apply_patch "$PWD" "expect-5.45.4-gcc14-1.patch" || true
    python3 -c 'print("ok")' >/dev/null
    ./configure --prefix=/usr --with-tcl=/usr/lib --enable-shared --disable-rpath \
        --mandir=/usr/share/man --with-tclinclude=/usr/include
    make; make install
    ln -svf expect5.45.4/libexpect5.45.4.so /usr/lib
}

b_dejagnu() {
    mkdir -v build && cd build
    ../configure --prefix=/usr
    makeinfo --html --no-split -o doc/dejagnu.html ../doc/dejagnu.texi || true
    makeinfo --plaintext -o doc/dejagnu.txt ../doc/dejagnu.texi || true
    make install
    install -v -dm755 /usr/share/doc/dejagnu-1.6.3
}

b_pkgconf() {
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/pkgconf-2.3.0
    make; make install
    ln -sv pkgconf /usr/bin/pkg-config
    ln -sv pkgconf.1 /usr/share/man/man1/pkg-config.1 || true
}

b_binutils_final() {
    mkdir -v build && cd build
    ../configure --prefix=/usr \
        --sysconfdir=/etc \
        --enable-ld=default \
        --enable-plugins \
        --enable-shared \
        --disable-werror \
        --enable-64-bit-bfd \
        --enable-new-dtags \
        --with-system-zlib \
        --enable-default-hash-style=gnu
    make tooldir=/usr
    make -k check || true
    make tooldir=/usr install
    rm -fv /usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.a
}

b_gmp() {
    ./configure --prefix=/usr --enable-cxx --disable-static --docdir=/usr/share/doc/gmp-6.3.0
    make; make install
}

b_mpfr() {
    sed -e 's/+01,03,13/+01,02,03,13/' -e 's/LC_ALL=\(...\)/&.UTF-8/g' \
        -i tests/tst-locale.c || true
    ./configure --prefix=/usr --disable-static --enable-thread-safe --docdir=/usr/share/doc/mpfr-4.2.1
    make; make install
}

b_mpc() {
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/mpc-1.3.1
    make; make install
}

b_attr() {
    ./configure --prefix=/usr --disable-static --sysconfdir=/etc --docdir=/usr/share/doc/attr-2.5.2
    make; make install
}

b_acl() {
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/acl-2.3.2
    make; make install
}

b_libcap() {
    sed -i '/install -m.*STA/d' libcap/Makefile
    make prefix=/usr lib=lib
    make prefix=/usr lib=lib install
}

b_libxcrypt() {
    ./configure --prefix=/usr \
        --enable-hashes=strong,glibc \
        --enable-obsolete-api=no \
        --disable-static \
        --disable-failure-tokens
    make; make install
}

b_shadow() {
    sed -i 's/groups$(EXEEXT) //' src/Makefile.in
    find man -name Makefile.in -exec sed -i 's/groups\.1 / /'   {} \;
    find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /' {} \;
    find man -name Makefile.in -exec sed -i 's/passwd\.5 / /'   {} \;
    sed -e 's:#ENCRYPT_METHOD DES:ENCRYPT_METHOD YESCRYPT:' \
        -e 's:/var/spool/mail:/var/mail:' \
        -e '/PATH=/{s@/sbin:@@;s@/bin:@@}' \
        -i etc/login.defs
    touch /usr/bin/passwd
    ./configure --sysconfdir=/etc --disable-static --with-{b,yes}crypt --without-libbsd \
        --with-group-name-max-length=32
    make && make exec_prefix=/usr install
    make -C man install-man
    pwconv
    grpconv
    mkdir -p /etc/default
    useradd -D --gid 999
    echo "root:${DISTRO_ID}" | chpasswd   # default root password = distro id
    sed -i '/MAIL/s/yes/no/' /etc/default/useradd
}

b_gcc_final() {
    case $(uname -m) in
        x86_64) sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;;
    esac
    mkdir -v build && cd build
    ../configure --prefix=/usr \
        LD=ld \
        --enable-languages=c,c++ \
        --enable-default-pie \
        --enable-default-ssp \
        --enable-host-pie \
        --disable-multilib \
        --disable-bootstrap \
        --disable-fixincludes \
        --with-system-zlib
    make
    make install
    ln -svr /usr/bin/cpp /usr/lib
    ln -sfv ../../libexec/gcc/"$(gcc -dumpmachine)"/14.2.0/liblto_plugin.so \
        /usr/lib/bfd-plugins/ 2>/dev/null || true
    mkdir -pv /usr/share/gdb/auto-load/usr/lib
    mv -v /usr/lib/*gdb.py /usr/share/gdb/auto-load/usr/lib 2>/dev/null || true
}

b_ncurses_final() {
    ./configure --prefix=/usr \
        --mandir=/usr/share/man \
        --with-shared \
        --without-debug \
        --without-normal \
        --with-cxx-shared \
        --enable-pc-files \
        --with-pkg-config-libdir=/usr/lib/pkgconfig
    make
    make install
    ln -sfv libncursesw.so /usr/lib/libncurses.so
    sed -e 's/^#if.*XOPEN.*$/#if 1/' -i /usr/include/curses.h
}

b_sed_final() { ./configure --prefix=/usr && make && make install; }
b_psmisc()    { ./configure --prefix=/usr && make && make install; }

b_gettext_final() {
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/gettext-0.24
    make; make install
    chmod -v 0755 /usr/lib/preloadable_libintl.so 2>/dev/null || true
}

b_bison_final() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/bison-3.8.2
    make; make install
}

b_grep_final() {
    sed -i "s/echo/#echo/" src/egrep.sh || true
    ./configure --prefix=/usr
    make; make install
}

b_bash_final() {
    if [ -f "$SOURCES_DIR/bash-5.2.37-upstream_fixes-1.patch" ]; then
        apply_patch "$PWD" "bash-5.2.37-upstream_fixes-1.patch"
    else
        log "skip optional bash upstream-fixes patch (not present)"
    fi
    ./configure --prefix=/usr \
        --without-bash-malloc \
        --with-installed-readline \
        --docdir=/usr/share/doc/bash-5.2.37
    make; make install
    ln -sfv bash /bin/sh
}

b_libtool() {
    ./configure --prefix=/usr
    make; make install
    rm -fv /usr/lib/libltdl.a
}

b_gdbm() {
    ./configure --prefix=/usr --disable-static --enable-libgdbm-compat
    make; make install
}

b_gperf() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/gperf-3.1
    make; make install
}

b_expat() {
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/expat-2.7.5
    make; make install
}

b_inetutils() {
    ./configure --prefix=/usr \
        --bindir=/usr/bin \
        --localstatedir=/var \
        --disable-logger --disable-whois --disable-rcp --disable-rexec --disable-rlogin --disable-rsh \
        --disable-servers
    make; make install
    mv -v /usr/{,s}bin/ifconfig 2>/dev/null || true
}

b_less() {
    ./configure --prefix=/usr --sysconfdir=/etc
    make; make install
}

b_perl_final() {
    export BUILD_ZLIB=False
    export BUILD_BZIP2=0
    sh Configure -des \
        -Dprefix=/usr \
        -Dvendorprefix=/usr \
        -Dprivlib=/usr/lib/perl5/5.40/core_perl \
        -Darchlib=/usr/lib/perl5/5.40/core_perl \
        -Dsitelib=/usr/lib/perl5/5.40/site_perl \
        -Dsitearch=/usr/lib/perl5/5.40/site_perl \
        -Dvendorlib=/usr/lib/perl5/5.40/vendor_perl \
        -Dvendorarch=/usr/lib/perl5/5.40/vendor_perl \
        -Dman1dir=/usr/share/man/man1 \
        -Dman3dir=/usr/share/man/man3 \
        -Dpager="/usr/bin/less -isR" \
        -Duseshrplib \
        -Dusethreads
    make; make install
    unset BUILD_ZLIB BUILD_BZIP2
}

b_xml_parser() {
    perl Makefile.PL
    make; make install
}

b_intltool() {
    sed -i 's:\\\${:\\\$\\{:' intltool-update.in
    ./configure --prefix=/usr && make && make install
    install -v -Dm644 doc/I18N-HOWTO /usr/share/doc/intltool-0.51.0/I18N-HOWTO || true
}

b_autoconf() { ./configure --prefix=/usr && make && make install; }
b_automake() { ./configure --prefix=/usr --docdir=/usr/share/doc/automake-1.17 && make && make install; }

b_openssl() {
    ./config --prefix=/usr --openssldir=/etc/ssl --libdir=lib shared zlib-dynamic
    make
    sed -i '/INSTALL_LIBS/s/libcrypto.a libssl.a//' Makefile
    make MANSUFFIX=ssl install
    mv -v /usr/share/doc/openssl /usr/share/doc/openssl-3.4.1 2>/dev/null || true
}

b_kmod() {
    # kmod 34's tarball references GTK_DOC_CHECK but omits m4/gtk-doc.m4.
    # Automake's auto-remake (triggered by mtime ordering in the tarball)
    # re-invokes aclocal, which then errors. Drop a minimal stub so aclocal
    # can resolve the macro; gtk-doc itself stays disabled because glib /
    # gobject aren't present in a bare LFS.
    mkdir -p m4
    cat > m4/gtk-doc.m4 <<'GTKM4'
AC_DEFUN([GTK_DOC_CHECK],
[
  AM_CONDITIONAL([ENABLE_GTK_DOC],     [false])
  AM_CONDITIONAL([GTK_DOC_USE_LIBTOOL],[false])
  AM_CONDITIONAL([GTK_DOC_USE_REBASE], [false])
  AM_CONDITIONAL([GTK_DOC_BUILD_HTML], [false])
  AM_CONDITIONAL([GTK_DOC_BUILD_PDF],  [false])
  AC_SUBST([GTKDOC_CHECK])
  AC_SUBST([GTKDOC_CHECK_PATH])
  AC_SUBST([GTKDOC_REBASE])
  AC_SUBST([GTKDOC_MKPDF])
])
GTKM4
    ./configure --prefix=/usr --sysconfdir=/etc --with-openssl --with-xz --with-zstd --with-zlib \
        --disable-manpages
    # Also drop an empty gtk-doc.make in case Makefile.am still -include's it
    # during auto-remake.
    mkdir -p libkmod/docs
    : > libkmod/docs/gtk-doc.make
    # Neutralise the autotools auto-remake rules: we've already run configure,
    # we don't want make re-running aclocal/autoconf/automake.
    local nore=(ACLOCAL=: AUTOCONF=: AUTOMAKE=: AUTOHEADER=: MAKEINFO=:)
    make "${nore[@]}"
    make "${nore[@]}" install
    for t in depmod insmod modinfo modprobe rmmod; do
        ln -sfv ../bin/kmod "/usr/sbin/$t"
    done
    ln -sfv kmod /usr/bin/lsmod
}

b_elfutils() {
    ./configure --prefix=/usr --disable-debuginfod --enable-libdebuginfod=dummy
    make
    make -C libelf install
    install -vm644 config/libelf.pc /usr/lib/pkgconfig
    rm -v /usr/lib/libelf.a
}

b_libffi() {
    ./configure --prefix=/usr --disable-static --with-gcc-arch=native
    make; make install
}

b_python_final() {
    ./configure --prefix=/usr \
        --enable-shared \
        --with-system-expat \
        --enable-optimizations
    make; make install
    install -v -dm755 /usr/lib/python3.13/site-packages
}

b_flit_core() {
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD" || \
        python3 -m flit_core.wheel || true
    pip3 install --no-index --no-user --find-links dist --no-cache-dir flit_core || true
}

b_wheel() {
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
    pip3 install --no-index --find-links=dist wheel
}

b_setuptools() {
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
    pip3 install --no-index --find-links=dist setuptools
}

b_markupsafe() {
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
    pip3 install --no-index --no-user --find-links dist markupsafe
}

b_jinja2() {
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
    pip3 install --no-index --no-user --find-links dist Jinja2
}

b_coreutils_final() {
    # The i18n patch is a nice-to-have (adds multibyte locale support to a
    # handful of tools). It requires a subsequent `autoreconf -fiv`, which in
    # turn needs gnulib macros that aren't always bundled in the tarball.
    # Make it opt-in via GOZJARO_COREUTILS_I18N=1 so the core build is robust.
    if [ "${GOZJARO_COREUTILS_I18N:-0}" = "1" ] && \
       [ -f "$SOURCES_DIR/coreutils-9.6-i18n-1.patch" ]; then
        apply_patch "$PWD" "coreutils-9.6-i18n-1.patch"
        autoreconf -fiv
    else
        log "skip coreutils i18n patch (set GOZJARO_COREUTILS_I18N=1 to enable)"
    fi
    FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr \
        --enable-no-install-program=kill,uptime
    make; make install
    mv -v /usr/bin/chroot /usr/sbin 2>/dev/null || true
    mv -v /usr/share/man/man1/chroot.1 /usr/share/man/man8/chroot.8 2>/dev/null || true
    sed -i 's/"1"/"8"/' /usr/share/man/man8/chroot.8 2>/dev/null || true
}

b_check() {
    ./configure --prefix=/usr --disable-static
    make && make docdir=/usr/share/doc/check-0.15.2 install
}

b_diffutils_final() { ./configure --prefix=/usr && make && make install; }
b_gawk_final()      { sed -i 's/extras//' Makefile.in; ./configure --prefix=/usr && make && make install; }

b_findutils_final() {
    ./configure --prefix=/usr --localstatedir=/var/lib/locate
    make; make install
}

b_groff() {
    PAGE=letter ./configure --prefix=/usr
    make -j1 && make install
}

b_gzip_final() { ./configure --prefix=/usr && make && make install; }

b_iproute2() {
    sed -i /ARPD/d Makefile
    rm -fv man/man8/arpd.8
    make NETNS_RUN_DIR=/run/netns
    make SBINDIR=/usr/sbin install
    install -v -dm755 /usr/share/doc/iproute2-6.13.0
}

b_kbd() {
    apply_patch "$PWD" "kbd-2.7.1-backspace-1.patch" || true
    [ -f configure ] && sed -i '/RESIZECONS_PROGS=/s/yes/no/' configure || true
    [ -f contrib/man/man8/Makefile.in ] && \
        sed -i 's/resizecons.8 //' contrib/man/man8/Makefile.in || true
    ./configure --prefix=/usr --disable-vlock
    make; make install
}

b_libpipeline()    { ./configure --prefix=/usr && make && make install; }
b_make_final()     { ./configure --prefix=/usr && make && make install; }
b_patch_final()    { ./configure --prefix=/usr && make && make install; }
b_tar_final()      { FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr && make && make install; }
b_texinfo_final()  { ./configure --prefix=/usr && make && make install; }

b_vim() {
    echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h
    ./configure --prefix=/usr
    make; make install
    ln -sv vim /usr/bin/vi
    for L in /usr/share/man/{,*/}man1/vim.1; do
        [ -f "$L" ] && ln -sv vim.1 "$(dirname "$L")/vi.1"
    done
    ln -sv ../vim/vim91/doc /usr/share/doc/vim-9.1.1166 2>/dev/null || true
}

b_procps() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/procps-ng-4.0.5 --disable-static --disable-kill
    make; make install
}

b_util_linux_final() {
    ./configure --bindir=/usr/bin --libdir=/usr/lib --runstatedir=/run --sbindir=/usr/sbin \
        --disable-chfn-chsh --disable-login --disable-nologin --disable-su --disable-setpriv --disable-runuser \
        --disable-pylibmount --disable-static --disable-liblastlog2 \
        --without-python --docdir=/usr/share/doc/util-linux-2.40.4 \
        ADJTIME_PATH=/var/lib/hwclock/adjtime
    make; make install
}

b_e2fsprogs() {
    mkdir -v build && cd build
    ../configure --prefix=/usr --sysconfdir=/etc --enable-elf-shlibs --disable-libblkid \
        --disable-libuuid --disable-uuidd --disable-fsck
    make; make install
    rm -fv /usr/lib/{libcom_err,libe2p,libext2fs,libss}.a
}

b_sysklogd() {
    # sysklogd 1.x shipped a bare Makefile; 2.x switched to autotools.
    if [ -x ./configure ]; then
        ./configure --prefix=/usr --sysconfdir=/etc --runstatedir=/run \
            --without-logger
        make
        make install
    elif [ -f Makefile ]; then
        make
        make install
    else
        die "sysklogd: no Makefile and no ./configure"
    fi
    cat > /etc/syslog.conf <<'EOF'
auth,authpriv.* -/var/log/auth.log
*.*;auth,authpriv.none -/var/log/sys.log
daemon.* -/var/log/daemon.log
kern.* -/var/log/kern.log
mail.* -/var/log/mail.log
user.* -/var/log/user.log
*.emerg *
EOF
}

b_sysvinit() {
    apply_patch "$PWD" "sysvinit-3.14-consolidated-1.patch" || true
    make
    make install
}

b_lfs_bootscripts() {
    make install
}

# ---- Invocations in book order ----------------------------------------------

build_pkg 60.man-pages      "man-pages-"    b_man_pages
build_pkg 60.iana-etc       "iana-etc-"     b_iana_etc
build_pkg 60.glibc-final    "glibc-"        b_glibc_final
build_pkg 60.tzdata         "tzdata"        b_tzdata
build_pkg 60.zlib           "zlib-"         b_zlib
build_pkg 60.bzip2          "bzip2-"        b_bzip2
build_pkg 60.xz-final       "xz-"           b_xz_final
build_pkg 60.zstd           "zstd-"         b_zstd
build_pkg 60.file-final     "file-"         b_file_final
build_pkg 60.readline       "readline-"     b_readline
build_pkg 60.m4-final       "m4-"           b_m4_final
build_pkg 60.bc             "bc-"           b_bc
build_pkg 60.flex           "flex-"         b_flex
build_pkg 60.tcl            "tcl"           b_tcl
build_pkg 60.expect         "expect"        b_expect
build_pkg 60.dejagnu        "dejagnu-"      b_dejagnu
build_pkg 60.pkgconf        "pkgconf-"      b_pkgconf
build_pkg 60.binutils-final "binutils-"     b_binutils_final
build_pkg 60.gmp            "gmp-"          b_gmp
build_pkg 60.mpfr           "mpfr-"         b_mpfr
build_pkg 60.mpc            "mpc-"          b_mpc
build_pkg 60.attr           "attr-"         b_attr
build_pkg 60.acl            "acl-"          b_acl
build_pkg 60.libcap         "libcap-"       b_libcap
build_pkg 60.libxcrypt      "libxcrypt-"    b_libxcrypt
build_pkg 60.shadow         "shadow-"       b_shadow
build_pkg 60.gcc-final      "gcc-"          b_gcc_final
build_pkg 60.ncurses-final  "ncurses-"      b_ncurses_final
build_pkg 60.sed-final      "sed-"          b_sed_final
build_pkg 60.psmisc         "psmisc-"       b_psmisc
build_pkg 60.gettext-final  "gettext-"      b_gettext_final
build_pkg 60.bison-final    "bison-"        b_bison_final
build_pkg 60.grep-final     "grep-"         b_grep_final
build_pkg 60.bash-final     "bash-"         b_bash_final
build_pkg 60.libtool        "libtool-"      b_libtool
build_pkg 60.gdbm           "gdbm-"         b_gdbm
build_pkg 60.gperf          "gperf-"        b_gperf
build_pkg 60.expat          "expat-"        b_expat
build_pkg 60.inetutils      "inetutils-"    b_inetutils
build_pkg 60.less           "less-"         b_less
build_pkg 60.perl-final     "perl-"         b_perl_final
build_pkg 60.xml-parser     "XML-Parser-"   b_xml_parser
build_pkg 60.intltool       "intltool-"     b_intltool
build_pkg 60.autoconf       "autoconf-"     b_autoconf
build_pkg 60.automake       "automake-"     b_automake
build_pkg 60.openssl        "openssl-"      b_openssl
build_pkg 60.kmod           "kmod-"         b_kmod
build_pkg 60.elfutils       "elfutils-"     b_elfutils
build_pkg 60.libffi         "libffi-"       b_libffi
build_pkg 60.python-final   "Python-"       b_python_final
build_pkg 60.flit-core      "flit_core-"    b_flit_core
build_pkg 60.wheel          "wheel-"        b_wheel
build_pkg 60.setuptools     "setuptools-"   b_setuptools
build_pkg 60.markupsafe     "markupsafe-"   b_markupsafe
build_pkg 60.jinja2         "jinja2-"       b_jinja2
build_pkg 60.coreutils-fin  "coreutils-"    b_coreutils_final
build_pkg 60.check          "check-"        b_check
build_pkg 60.diffutils-fin  "diffutils-"    b_diffutils_final
build_pkg 60.gawk-final     "gawk-"         b_gawk_final
build_pkg 60.findutils-fin  "findutils-"    b_findutils_final
build_pkg 60.groff          "groff-"        b_groff
build_pkg 60.gzip-final     "gzip-"         b_gzip_final
build_pkg 60.iproute2       "iproute2-"     b_iproute2
build_pkg 60.kbd            "kbd-"          b_kbd
build_pkg 60.libpipeline    "libpipeline-"  b_libpipeline
build_pkg 60.make-final     "make-"         b_make_final
build_pkg 60.patch-final    "patch-"        b_patch_final
build_pkg 60.tar-final      "tar-"          b_tar_final
build_pkg 60.texinfo-final  "texinfo-"      b_texinfo_final
build_pkg 60.vim            "vim-"          b_vim
build_pkg 60.procps         "procps-ng-"    b_procps
build_pkg 60.util-linux-fin "util-linux-"   b_util_linux_final
build_pkg 60.e2fsprogs      "e2fsprogs-"    b_e2fsprogs
build_pkg 60.sysklogd       "sysklogd-"     b_sysklogd
build_pkg 60.sysvinit       "sysvinit-"     b_sysvinit
build_pkg 60.bootscripts    "lfs-bootscripts-" b_lfs_bootscripts

log "final system packages installed"
