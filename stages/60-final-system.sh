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
    apply_patch "$src" "glibc-fhs-1.patch"
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
    # GCC >= 16 defaults to C23, where stdbool's true/false are keywords; bc
    # 7.0.3's BC_PARSE_EXPR_ENTRY pastes the token via `false ## UL`
    # (UINTMAX_C), which becomes the undeclared identifiers `falseUL`/`trueUL`
    # under C23. bc's default (GNU) build type doesn't pin the C standard, so
    # pin C11 here — stable across future gcc bumps too.
    CC=gcc CFLAGS="-std=gnu11" ./configure --prefix=/usr -G -O3 -r
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
    apply_patch "$PWD" "expect-5.45.4-gcc15-1.patch" || true
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
    # GCC 15+ defaults to -std=gnu23 (C23): an empty parameter list now means
    # "no parameters" (was "unspecified" pre-C23), so gmp 6.3.0's hand-written
    # configure "long long reliability test" program -- which declares
    # `void g(){}` (K&R empty param list) and calls g() with 6 args -- fails
    # to compile under C23 and configure dies with
    # "could not find a working compiler". Pin C11.
    # NOTE: gmp's configure skips its own cflags_maybe (-O2 -pedantic
    # -fomit-frame-pointer -m64) when CFLAGS is set, so carry -O2 explicitly.
    CFLAGS="-O2 -std=gnu11" ./configure --prefix=/usr --enable-cxx --disable-static --docdir=/usr/share/doc/gmp-6.3.0
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
    # gcc 16 defaults to gnu23; under C23 glibc 2.44 declares strchr in the
    # const-preserving form, so libxcrypt's `char *hptr = strchr((const char *)
    # …)` triggers -Wdiscarded-qualifiers, and libxcrypt's configure adds
    # -Werror by default (warnings_are_errors=true) -> fatal. Unlike bc/gmp
    # (whose code fails to *compile* under C23), this 2024-era package compiles
    # fine in C23 and only the warning is promoted to an error, so the
    # minimal fix is the package's own --disable-werror: drop -Werror, leave
    # the compiler's default standard alone. --disable-static/failure-tokens
    # etc. are LFS 13.1 defaults, kept unchanged.
    ./configure --prefix=/usr \
        --enable-hashes=strong,glibc \
        --enable-obsolete-api=no \
        --disable-static \
        --disable-failure-tokens \
        --disable-werror
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
    # shadow 4.20 autoconf probes for libsystemd (logind) by default; in the LFS
    # chroot there is no systemd, so the probe is fatal ("configure: error:
    # libsystemd not found"). LFS disables it with --disable-logind. The cmocka
    # "not found" line in the log is only a WARNING (tests simply aren't built),
    # not the cause of the failure.
    ./configure --sysconfdir=/etc --disable-static --with-{b,yes}crypt --without-libbsd \
        --disable-logind --with-group-name-max-length=32
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
    # Fresh build dir: a stale one from a failed attempt keeps an old
    # optionlist/options.cc, and make's move-if-change + s-options stamp
    # prevents regeneration, so the corrupt options.cc would survive.
    rm -rf build
    mkdir -v build && cd build
    # gcc's option pipeline (opt-gather/optc-gen.awk) is awk-dialect
    # sensitive: the chroot's default awk (busybox/mawk) mangles the
    # optionlist (a '0' prefix lands on every flag name), so optc-gen
    # writes "#error <flag> does not have a Var() flag" diagnostics into
    # options.cc and the build dies. gawk is built just before this
    # package (60.gawk-final); force it for both configure and make.
    AWK=/usr/bin/gawk ../configure --prefix=/usr \
        LD=ld \
        --enable-languages=c,c++ \
        --enable-default-pie \
        --enable-default-ssp \
        --enable-host-pie \
        --disable-multilib \
        --disable-bootstrap \
        --disable-fixincludes \
        --with-system-zlib
    AWK=/usr/bin/gawk make
    make install
    ln -svr /usr/bin/cpp /usr/lib
    # The LTO plugin lives under <machine>/<full-version>/ in the libexec tree.
    # Ask the just-installed gcc for both parts instead of hardcoding 14.2.0
    # (which is why the stale symlink broke with gcc 16.2.0).
    ln -sfv ../../libexec/gcc/"$(gcc -dumpmachine)"/"$(gcc -dumpfullversion)"/liblto_plugin.so \
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
    bash Configure -des \
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
    # Pre-seed a stub for libkmod/docs/gtk-doc.make (referenced by
    # Makefile.am via include; autoreconf needs it to exist on disk).
    install -Dm644 /dev/null libkmod/docs/gtk-doc.make 2>/dev/null || true
    # Strip the GTK_DOC_CHECK call from configure.ac so autoreconf doesn't
    # invoke gtkdocize (which isn't installed). Our m4/gtk-doc.m4 stub is
    # then also unneeded but harmless.
    sed -i '/^GTK_DOC_CHECK/d' configure.ac
    # kmod ships ltmain.sh + aclocal.m4 from a 2.5.4.1-baa1-dirty libtool
    # snapshot that fails the runtime version check against installed
    # libtool 2.5.4. Regenerate everything from the host autotools.
    autoreconf -fi
    ./configure --prefix=/usr --sysconfdir=/etc --with-openssl --with-xz --with-zstd --with-zlib \
        --disable-manpages
    # Also drop an empty gtk-doc.make in case Makefile.am still -include's it
    # during auto-remake.
    # Some auto-remake paths include gtk-doc.make. Drop empty stubs at every
    # path any Makefile.am/.in references, plus the usual libkmod/docs spot.
    install -Dm644 /dev/null libkmod/docs/gtk-doc.make 2>/dev/null || true
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        install -Dm644 /dev/null "$target" 2>/dev/null || true
    done < <(grep -rhEo '[A-Za-z0-9_/.-]*gtk-doc\.make' \
                --include='Makefile.am' --include='Makefile.in' . 2>/dev/null \
             | sort -u)
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
    # OpenSSL 4.0 removed the legacy TLSv1/TLSv1_1/TLSv1_2/SSLv3 method
    # symbols; unpatched Python 3.14.7's _ssl.c still references them, so
    # _ssl links but fails to import (undefined symbol: TLSv1_method) and
    # the ssl module drops out of the build ("Could not build the ssl
    # module!"). LFS's openssl_4 patch guards those references behind
    # OPENSSL_VERSION_NUMBER >= 0x40000000L — verified on the 3.14.7
    # release tree: -p1 applies with 0 rejects. Stage 20 already fetched
    # it via the shared patches.yaml channel. No `|| true`: without this
    # patch the build silently ships without ssl, which is worse than a
    # hard stop (same contract as glibc-fhs).
    apply_patch "$PWD" "Python-3.14.7-openssl_4-1.patch"
    ./configure --prefix=/usr \
        --enable-shared \
        --with-system-expat \
        --enable-optimizations
    make; make install
    # Derive the minor version from the extracted tree name
    # (Python-3.14.7 -> 3.14) instead of hardcoding: this line was pinned to
    # python3.13 and would silently create the wrong site-packages dir after
    # a manifest bump to 3.14. 3.14.7 -> 3.14 via ${ver%.*}.
    local tree ver
    tree="$(basename "$PWD")"
    ver="${tree#Python-}"
    install -v -dm755 "/usr/lib/python${ver%.*}/site-packages"
    # Hard gate for the installer TUI: tui.py is the primary front-end and
    # falls back to text mode only when `import curses` fails. The curses
    # module (_curses) links ncursesw, which 60.ncurses-final exposes via
    # /usr/lib/pkgconfig/ncursesw.pc (--enable-pc-files). If _curses did not
    # build, the installer silently degrades to text mode for every user —
    # that is the exact silent failure this stage must not allow. No
    # `|| true`: a missing _curses aborts the build now instead of shipping
    # a text-only installer later.
    python3 -c "import curses; print('_curses OK', curses.version)" \
        || die "python _curses module missing — ncursesw not found by configure; installer TUI will not build"
}

b_flit_core() {
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD" || \
        python3 -m flit_core.wheel || true
    pip3 install --no-index --no-user --find-links dist --no-cache-dir flit_core || true
}

b_packaging() {
    # wheel 0.48's runtime dep (packaging >= 24.0). packaging itself has zero
    # runtime deps; its build backend is flit_core (built just before). LFS
    # 13.1 ships this package for exactly this offline-install chain.
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
    pip3 install --no-index --find-links=dist packaging
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
       [ -f "$SOURCES_DIR/coreutils-9.11-i18n-1.patch" ]; then
        apply_patch "$PWD" "coreutils-9.11-i18n-1.patch"
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
    apply_patch "$PWD" "kbd-2.10.0-backspace-1.patch" || true
    [ -f configure ] && sed -i '/RESIZECONS_PROGS=/s/yes/no/' configure || true
    [ -f contrib/man/man8/Makefile.in ] && \
        sed -i 's/resizecons.8 //' contrib/man/man8/Makefile.in || true
    ./configure --prefix=/usr --disable-vlock
    make; make install
}

b_libpipeline()    { ./configure --prefix=/usr && make && make install; }
b_make_final()     { ./configure --prefix=/usr && make && make install; }
b_patch_final()    { ./configure --prefix=/usr && make && make install; }
b_tar_final() {
    # LFS's acl_fix patch: tar 1.35 defines static acl_get_file_at /
    # acl_set_file_at / acl_delete_def_file_at with the OLD 3-arg signatures,
    # which now clash with libacl's new sys/acl.h declarations (4-arg, with
    # at_flags) installed earlier in the same stage -> "conflicting types".
    # The patch renames tar's statics to tar_acl_*. Verified on the
    # tar-1.35 release tree: -p1 applies with 0 rejects. Stage 20 already
    # fetched it via patches.yaml. No `|| true`: an unpatched tar would
    # silently build against the wrong API surface.
    apply_patch "$PWD" "tar-1.35-acl_fix-1.patch"
    FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr && make && make install;
}
b_texinfo_final()  { ./configure --prefix=/usr && make && make install; }

b_vim() {
    local srcdir="${1:-.}"
    # Derive the version from the extracted tree name (vim-9.2.0954 -> 9.2.0954),
    # not a hardcoded 9.1.1166 — the tree bumps when the manifest does.
    local v="${srcdir##*/}"
    v="${v#vim-}"
    echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h
    ./configure --prefix=/usr
    make; make install
    ln -sv vim /usr/bin/vi
    for L in /usr/share/man/{,*/}man1/vim.1; do
        [ -f "$L" ] && ln -sv vim.1 "$(dirname "$L")/vi.1"
    done
    # Vim installs its runtime files under /usr/share/vim/vimXX (the XX being
    # the version-numbered runtime dir, not necessarily derived from the patch
    # level). Locate whatever dir actually got installed and point the doc
    # symlink at it; skip cleanly when no runtime dir was installed, so we never
    # leave a dangling link. This is version-drift-proof: it tracks the real
    # tree instead of a remembered constant.
    local vimdoc
    vimdoc=$(ls -d /usr/share/vim/vim*/doc 2>/dev/null | head -n1 || true)
    [ -n "$vimdoc" ] && ln -sv "$vimdoc" "/usr/share/doc/vim-$v" 2>/dev/null || true
}

b_procps() {
    # docdir must track the manifest version (4.0.7); a stale 4.0.5 was left over.
    ./configure --prefix=/usr --docdir=/usr/share/doc/procps-ng-4.0.7 --disable-static --disable-kill
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

b_meson() {
    pip3 install --no-build-isolation --no-deps --prefix=/usr "$PWD"
}

b_ninja() {
    python3 configure.py --bootstrap
    install -vm755 ninja /usr/bin/
}

b_dbus() {
    # Create system user/group for the message bus daemon.
    groupadd -g 18 messagebus 2>/dev/null || true
    useradd -c "D-Bus Message Daemon" -d /run/dbus \
        -u 18 -g messagebus -s /bin/false messagebus 2>/dev/null || true

    # dbus 1.16.x is MESSON-ONLY: the release tarball ships no ./configure
    # (autotools was dropped after 1.10) -> old "b_dbus" hit
    # "./configure: No such file or directory". meson+ninja are built
    # earlier in this stage (60.meson/60.ninja before 60.dbus) and expat
    # (the only hard dep, required for the default message_bus=true)
    # builds at 60.expat. glib/gio are probed only when modular_tests is
    # enabled -> disable it. dbus is built AFTER systemd in this stage, so
    # enable systemd: meson then installs bus/dbus.{service,socket} into
    # systemd_system_unitdir + the multi-user/sockets wants symlinks and
    # compiles dbus-daemon with sd_listen_fds() activation. Without it
    # nothing ever creates /run/dbus/system_bus_socket and logind and
    # every bus client die with 'Failed to connect to system bus'
    # (field incident 2026-10-24). --wrap-mode=nofallback: never let
    # meson reach out the network for subprojects.
    mkdir -v build && cd build
    meson setup .. \
        --prefix=/usr \
        --buildtype=release \
        --wrap-mode=nofallback \
        -Dsystemd=enabled \
        -Dsystemd_system_unitdir=/usr/lib/systemd/system \
        -Dselinux=disabled \
        -Dapparmor=disabled \
        -Dmodular_tests=disabled \
        -Dxml_docs=disabled \
        -Ddoxygen_docs=disabled \
        -Duser_session=false \
        -Dsystem_socket=/run/dbus/system_bus_socket
    ninja
    ninja install

    # dbus-daemon never mkdir()s the socket's parent directory (verified in
    # dbus/dbus-sysdeps-unix.c: the unix listener just unlinks a stale
    # socket and binds), and dbus's own tmpfiles.d only manages
    # /var/lib/dbus - nothing creates /run/dbus. systemd 261.2 ships no
    # dbus units of its own, and neither the traditional forking unit nor
    # the socket-activated one adds SocketDirectory=. Without this
    # tmpfiles entry, every boot dies with:
    #   Failed to bind socket "/run/dbus/system_bus_socket": ENOENT
    # systemd-tmpfiles-setup.service (sysinit.target) creates the dir
    # before sockets.target starts dbus.socket.
    install -d -m755 /usr/lib/tmpfiles.d
    cat > /usr/lib/tmpfiles.d/gozjaro-dbus.conf <<'EOF'
d /run/dbus 0755 root root -
EOF
    chmod 644 /usr/lib/tmpfiles.d/gozjaro-dbus.conf

    ln -sfv /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
}

b_systemd() {
    local src="$1"

    # Disable test-suite build probes that fail inside chroot.
    sed -i -e 's/want_tests != .no./false/' test/meson.build 2>/dev/null || true

    mkdir -v build && cd build

    LANG=en_US.UTF-8 \
    meson setup .. \
        --prefix=/usr \
        --buildtype=release \
        --wrap-mode=nofallback \
        -Dmode=release \
        -Ddev-kvm-mode=0660 \
        -Dlink-udev-shared=true \
        -Dlogind=true \
        -Dvconsole=true \
        -Dhwdb=true \
        -Dsysusers=true \
        -Dtmpfiles=true \
        -Dtimedated=true \
        -Dlocaled=true \
        -Dhostnamed=true \
        -Dnetworkd=true \
        -Dresolve=true \
        -Dnss-myhostname=true \
        -Dnss-resolve=enabled \
        -Dnss-systemd=true \
        -Dmachined=false \
        -Dimportd=disabled \
        -Dhomed=disabled \
        -Dportabled=false \
        -Duserdb=false \
        -Doomd=false \
        -Dremote=disabled \
        -Dfirstboot=false \
        -Drandomseed=true \
        -Dbacklight=true \
        -Drfkill=true \
        -Dcoredump=true \
        -Dpstore=true \
        -Dpolkit=disabled \
        -Daudit=disabled \
        -Dpam=disabled \
        -Dapparmor=disabled \
        -Dselinux=disabled \
        -Dseccomp=disabled \
        -Dsmack=false \
        -Dxkbcommon=disabled \
        -Dpcre2=disabled \
        -Dglib=disabled \
        -Dgnutls=disabled \
        -Dopenssl=enabled \
        -Dp11kit=disabled \
        -Dlibcurl=disabled \
        -Dlibidn2=disabled \
        -Dlibiptc=disabled \
        -Dqrencode=disabled \
        -Dgcrypt=disabled \
        -Dmicrohttpd=disabled \
        -Dpasswdqc=disabled \
        -Dpwquality=disabled \
        -Dxenctrl=disabled \
        -Dlz4=disabled \
        -Dzstd=enabled \
        -Dxz=enabled \
        -Dzlib=enabled \
        -Dbzip2=enabled \
        -Dbootloader=disabled \
        -Dukify=disabled \
        -Dkernel-install=true \
        -Danalyze=true \
        -Dtests=false \
        -Dman=disabled \
        -Dhtml=disabled \
        -Ddbus=enabled \
        -Dblkid=enabled \
        -Dkmod=enabled \
        -Dsplit-bin=false \
        -Dfallback-hostname="${DISTRO_ID}" \
        -Ddefault-dnssec=no \
        -Ddefault-mdns=no \
        -Ddefault-llmnr=no \
        -Dinstall-sysconfdir=true \
        -Ddocdir=/usr/share/doc/systemd-261.2

    ninja
    ninja install

    # Initialize machine-id (needed by dbus and journald).
    systemd-machine-id-setup 2>/dev/null || \
        dbus-uuidgen --ensure=/etc/machine-id || true

    # Ensure /sbin/init symlink exists.
    [ -e /sbin/init ] || ln -sfv ../lib/systemd/systemd /sbin/init

    # Enable default unit presets.
    systemctl preset-all 2>/dev/null || true

    log "systemd 261.2 installed"
}

# ---- EFI boot management ------------------------------------------------------
# popt: option-parsing library (dep of efibootdump). The GitHub source export
# ships no pre-generated autotools (no configure / no m4/), and the tarball's
# po/ tree carries LINGUAS + Makevars, so GNU gettext mode works with the
# chroot's own aclocal — no external gettext.m4 needed. autoconf 2.73 is
# built at 60.autoconf-final; libtool at 60.libtool.
b_popt() {
    # The GitHub source export ships no pre-generated autotools and its po/
    # tree is incomplete (Makefile.am is a gettextize-generated file, never
    # committed), so aclocal would choke on po/Makevars. Strip the catalog
    # tree, the NLS wiring (gettext.m4 macros are not guaranteed in this
    # chroot) and the test tree: we only need the library + popt.pc.
    # poptint.h's !ENABLE_NLS fallback (POPT_(foo) -> foo) keeps the API
    # source-compatible without NLS.
    sed -i \
        -e 's/^SUBDIRS = src po tests$/SUBDIRS = src/' \
        Makefile.am
    sed -i \
        -e '/AM_GNU_GETTEXT_VERSION/d' \
        -e '/AM_GNU_GETTEXT_REQUIRE_VERSION/d' \
        -e '/AM_GNU_GETTEXT(/d' \
        -e '/AM_ICONV_LINK/d' \
        -e 's| po/Makefile.in| |' \
        -e 's|tests/test-poptrc tests/Makefile||' \
        configure.ac
    # AM_GNU_GETTEXT/AM_ICONV_LINK normally clear LTLIBINTL/LTLIBICONV.
    # With them stripped the @...@ tokens leak VERBATIM through config.status
    # into the generated Makefile (libtool then passes them to ld, which
    # dies: "cannot find @LTLIBINTL@"). Blank them in every file that
    # still references them: the lib LDFLAGS in src/Makefile.am and the
    # Libs.private line in popt.pc.in.
    sed -i 's/@LTLIBINTL@//g; s/@LTLIBICONV@//g' src/Makefile.am Makefile.am popt.pc.in
    autoreconf -fi
    ./configure --prefix=/usr --disable-static
    make; make install
}

# efivar: UEFI variable library. Pure make; installs its own .pc files to
# $(LIBDIR)/pkgconfig — efibootmgr links against them via pkg-config.
# LIBDIR override: the tree hard-codes /usr/lib64 as the default; this
# system is not FHS-lib64. ENABLE_DOCS=0: docs need pandoc (not in LFS).
# ERRORS= strips the hard -Werror (gcc 16 era-drift class, cf. libxcrypt).
b_efivar() {
    make PREFIX=/usr LIBDIR=/usr/lib ENABLE_DOCS=0 ERRORS=
    make PREFIX=/usr LIBDIR=/usr/lib ENABLE_DOCS=0 ERRORS= install
}

# efibootmgr: NVRAM boot-entry tool that grub-install --target=x86_64-efi
# shells out to. Main binary links efivar only; efibootdump adds popt.
# EFIDIR/EFI_LOADER must describe the ESP layout the installer writes
# (/boot/efi == ESP root; loader at EFI/Gozjaro/grubx64.efi) so the
# registered NVRAM entry points at \EFI\Gozjaro\grubx64.efi.
# -Werror and -Wl,--fatal-warnings are HARDCODED into the cflags/ccldflags
# variables (no override hook), so sed them out — same gcc-16 drift
# class as efivar above. CFLAGS override drops the default -flto.
b_efibootmgr() {
    # -Werror is standalone; --fatal-warnings is comma-joined with
    # --no-allow-shlib-undefined in one -Wl, argument, so strip only the
    # --fatal-warnings, token or a bare --no-allow-shlib-undefined leaks
    # into the gcc line (gcc: unrecognized option). CFLAGS override drops
    # the default -flto.
    sed -i -e 's/-Werror //g' -e 's/--fatal-warnings,//g' Make.defaults
    make EFIDIR=Gozjaro EFI_LOADER=grubx64.efi CFLAGS="-O2 -g"
    make EFIDIR=Gozjaro EFI_LOADER=grubx64.efi CFLAGS="-O2 -g" install
}

b_cpio() {
    local src="$1"
    # Shipped configure, no NLS (LFS convention). mt is unneeded for our
    # use (initramfs packing) and stays out.
    apply_patch "$src" "cpio-2.15-xstat_c23-1.patch"
    ./configure --prefix=/usr --disable-nls
    make; make install
}

b_ca_certificates() {
    local src="$1"
    # Trusted CA bundle — the distribution-level gap behind "unable to get
    # local issuer certificate (20)". openssl (60.openssl) was built
    # --openssldir=/etc/ssl and curl/wget/git point at /etc/ssl/certs, but
    # nothing ever populated /etc/ssl. This first-class package does it:
    #   apply patch -> make (121 .crt) -> make install -> update-ca-certificates
    # certdata2pem.py's only non-stdlib import is python3-cryptography, used
    # for a LOG-ONLY expired-cert notice; PEM gen is pure base64. The
    # repo-local patch (delivered into $SOURCES_DIR by stage 20) makes it
    # optional — verified byte-identical .crt with or without it — so this
    # does not drag the pip/setuptools/cffi/libffi chain into the tree.
    apply_patch "$src" "ca-certificates-20260816-lazy_import-1.patch"
    # Generate + install: .crt -> /usr/share/ca-certificates/mozilla/,
    # update-ca-certificates -> /usr/sbin. `make` (all) runs first so the
    # `install` target's `for p in *.crt` has something to copy.
    make
    make install
    # Ship the user-editable enable list (one .crt basename per line, 121 —
    # matches the Debian .deb payload exactly). The installed .crt live in
    # /usr/share/ca-certificates/mozilla/, so list bare basenames from that
    # subdir; update-ca-certificates --default adds them via its recursive
    # `find $CERTSDIR -name '*.crt'` pass regardless of the conf.
    install -v -d /etc
    ( cd /usr/share/ca-certificates/mozilla && {
        c=0
        for f in *.crt; do [ -e "$f" ] && { c=1; printf '%s\n' "$f"; }; done
        [ "$c" = "1" ] || { echo "no .crt in /usr/share/ca-certificates/mozilla"; exit 1; }
      } | sort > /etc/ca-certificates.conf )
    # Populate /etc/ssl: per-cert .pem symlinks + rehash number-suffixed links
    # + ca-certificates.crt bundle. Runs `openssl rehash .` in /etc/ssl/certs,
    # so 60.openssl must be present (it is). No hooks dir -> the run-parts
    # block is skipped, so run-parts is NOT required.
    install -v -d /etc/ssl/certs
    /usr/sbin/update-ca-certificates --default
    # Standard single-bundle symlink used by tooling that hardcodes
    # /etc/ssl/cert.pem (libcurl's default CAfile fallback, etc).
    ln -sf certs/ca-certificates.crt /etc/ssl/cert.pem
}

b_gptfdisk() {
    # Source of sgdisk (the installer's GPT partitioner) + gdisk/fixparts.
    # Pure makefile, no autotools. sgdisk links -luuid (util-linux libuuid,
    # 60.util-linux-fin) + -lpopt (60.popt); cgdisk needs ncursesw but is not
    # built — only sgdisk matters for the installer. TARGET=linux pins the
    # Linux default LIB_NAMES/LDLIBS block so the build is host-independent.
    #
    # Defensive dev-link guard: gptfdisk links -luuid against an UNVERSIONED
    # /usr/lib/libuuid.so. util-linux (built --disable-static) installs it as
    # a shared library with a .so dev link, but if a future util-linux config
    # ever ships only libuuid.so.N, this symlink is what lets sgdisk link.
    # Harmless when the link already exists.
    [ -e /usr/lib/libuuid.so ] || \
        ln -sf "$(ls -1 /usr/lib/libuuid.so.* 2>/dev/null | sort -V | tail -n1)" /usr/lib/libuuid.so
    # One invocation builds all three (make resolves each .o prerequisite).
    # sgdisk links -luuid -lpopt; gdisk -luuid; fixparts links neither.
    make TARGET=linux sgdisk gdisk fixparts
    install -v -m755 sgdisk gdisk fixparts /usr/bin
    install -v -d /usr/share/man/man8
    install -v -m644 sgdisk.8 gdisk.8 fixparts.8 /usr/share/man/man8
}

b_linux_firmware() {
    # linux-firmware is prebuilt binary blobs — no compilation, just copy.
    # This adds ~500MB to $LFS and grows the live ISO significantly; trade
    # for broad hardware support (wifi, GPU, NIC firmware).
    # MAKEFLAGS must be cleared: the Makefile forwards -jN to copy-firmware.sh
    # which requires GNU parallel (not in LFS). Serial copy is fine here.
    make install FIRMWAREDIR=/usr/lib/firmware MAKEFLAGS=
    log "linux-firmware installed at /usr/lib/firmware"
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
build_pkg 60.gawk-final     "gawk-"         b_gawk_final
build_pkg 60.gcc-final      "gcc-"          b_gcc_final
build_pkg 60.ncurses-final  "ncurses-"      b_ncurses_final
build_pkg 60.sed-final      "sed-"          b_sed_final
build_pkg 60.psmisc         "psmisc_"       b_psmisc
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
build_pkg 60.packaging      "packaging-"    b_packaging
build_pkg 60.wheel          "wheel-"        b_wheel
build_pkg 60.setuptools     "setuptools-"   b_setuptools
build_pkg 60.markupsafe     "markupsafe-"   b_markupsafe
build_pkg 60.jinja2         "jinja2-"       b_jinja2
build_pkg 60.meson          "meson-"        b_meson
build_pkg 60.ninja          "ninja-"        b_ninja
build_pkg 60.coreutils-fin  "coreutils-"    b_coreutils_final
build_pkg 60.check          "check-"        b_check
build_pkg 60.diffutils-fin  "diffutils-"    b_diffutils_final
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
build_pkg 60.procps         "procps_"       b_procps
build_pkg 60.util-linux-fin "util-linux-"   b_util_linux_final
build_pkg 60.e2fsprogs      "e2fsprogs-"    b_e2fsprogs
build_pkg 60.systemd        "systemd-"      b_systemd
build_pkg 60.dbus           "dbus-"         b_dbus
build_pkg 60.linux-firmware "linux-firmware-" b_linux_firmware
build_pkg 60.cpio          "cpio-"            b_cpio
build_pkg 60.popt          "popt-"            b_popt
build_pkg 60.efivar        "efivar-"          b_efivar
build_pkg 60.efibootmgr    "efibootmgr-"      b_efibootmgr
build_pkg 60.gptfdisk      "gptfdisk-"        b_gptfdisk
build_pkg 60.ca-certificates "ca-certificates" b_ca_certificates

log "final system packages installed"
