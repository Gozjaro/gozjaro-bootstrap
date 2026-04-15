#!/usr/bin/env bash
# Chapter 6: cross-compiled temporary tools, built as user 'lfs'.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
# shellcheck source=../lib/pkg.sh
. "$GOZJARO_ROOT/lib/pkg.sh"

start_log 40-temp-tools
require_lfs_user

b_m4() {
    ./configure --prefix=/usr --host="$LFS_TGT" --build="$(build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
}

b_ncurses() {
    sed -i s/mawk// configure
    mkdir build
    pushd build
        ../configure
        make -C include
        make -C progs tic
    popd
    ./configure --prefix=/usr \
        --host="$LFS_TGT" \
        --build="$(./config.guess)" \
        --mandir=/usr/share/man \
        --with-manpage-format=normal \
        --with-shared \
        --without-normal \
        --with-cxx-shared \
        --without-debug \
        --without-ada \
        --disable-stripping
    make
    make DESTDIR="$LFS" TIC_PATH="$(pwd)/build/progs/tic" install
    ln -sv libncursesw.so "$LFS/usr/lib/libncurses.so"
    sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "$LFS/usr/include/curses.h"
}

b_bash() {
    ./configure --prefix=/usr \
        --build="$(sh support/config.guess)" \
        --host="$LFS_TGT" \
        --without-bash-malloc \
        bash_cv_strtold_broken=no
    make
    make DESTDIR="$LFS" install
    ln -sv bash "$LFS/usr/bin/sh"
}

b_coreutils() {
    ./configure --prefix=/usr \
        --host="$LFS_TGT" \
        --build="$(build-aux/config.guess)" \
        --enable-install-program=hostname \
        --enable-no-install-program=kill,uptime
    make
    make DESTDIR="$LFS" install
    mv -v "$LFS/usr/bin/chroot" "$LFS/usr/sbin"
    mkdir -pv "$LFS/usr/share/man/man8"
    mv -v "$LFS/usr/share/man/man1/chroot.1" "$LFS/usr/share/man/man8/chroot.8"
    sed -i 's/"1"/"8"/' "$LFS/usr/share/man/man8/chroot.8"
}

b_diffutils() {
    ./configure --prefix=/usr --host="$LFS_TGT" --build="$(./build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
}

b_file() {
    mkdir build
    pushd build
        ../configure --disable-bzlib --disable-libseccomp \
            --disable-xzlib --disable-zlib
        make
    popd
    ./configure --prefix=/usr --host="$LFS_TGT" --build="$(./config.guess)"
    make FILE_COMPILE="$(pwd)/build/src/file"
    make DESTDIR="$LFS" install
    rm -v "$LFS/usr/lib/libmagic.la"
}

b_findutils() {
    ./configure --prefix=/usr \
        --localstatedir=/var/lib/locate \
        --host="$LFS_TGT" \
        --build="$(build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
}

b_gawk() {
    sed -i 's/extras//' Makefile.in
    ./configure --prefix=/usr --host="$LFS_TGT" --build="$(build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
}

b_grep() {
    ./configure --prefix=/usr --host="$LFS_TGT" --build="$(./build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
}

b_gzip() {
    ./configure --prefix=/usr --host="$LFS_TGT"
    make
    make DESTDIR="$LFS" install
}

b_make() {
    ./configure --prefix=/usr \
        --without-guile \
        --host="$LFS_TGT" \
        --build="$(build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
}

b_patch() {
    ./configure --prefix=/usr --host="$LFS_TGT" --build="$(build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
}

b_sed() {
    ./configure --prefix=/usr --host="$LFS_TGT"
    # Cross-built sed/sed cannot execute on the host, so help2man (invoked
    # as `perl $(HELP2MAN)`) fails while regenerating doc/sed.1. Substitute
    # a tiny perl script that just creates the requested output file; the
    # tarball already ships a usable doc/sed.1.
    cat > /tmp/h2m-noop.pl <<'PERL'
#!/usr/bin/perl
my $out;
for (my $i = 0; $i < @ARGV; $i++) {
    if ($ARGV[$i] eq '-o' || $ARGV[$i] eq '--output') { $out = $ARGV[$i+1]; last; }
}
if ($out) { open(my $fh, '>', $out) and close $fh; }
exit 0;
PERL
    make HELP2MAN=/tmp/h2m-noop.pl
    make DESTDIR="$LFS" HELP2MAN=/tmp/h2m-noop.pl install
}

b_tar() {
    ./configure --prefix=/usr \
        --host="$LFS_TGT" \
        --build="$(build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
}

b_xz() {
    ./configure --prefix=/usr \
        --host="$LFS_TGT" \
        --build="$(build-aux/config.guess)" \
        --disable-static \
        --docdir=/usr/share/doc/xz-5.6.4
    make
    make DESTDIR="$LFS" install
    rm -v "$LFS/usr/lib/liblzma.la"
}

b_binutils_pass2() {
    sed '6031s/$add_dir//' -i ltmain.sh
    mkdir -v build && cd build
    ../configure \
        --prefix=/usr \
        --build="$(../config.guess)" \
        --host="$LFS_TGT" \
        --disable-nls \
        --enable-shared \
        --enable-gprofng=no \
        --disable-werror \
        --enable-64-bit-bfd \
        --enable-new-dtags \
        --enable-default-hash-style=gnu
    make
    make DESTDIR="$LFS" install
    rm -v "$LFS"/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
}

b_gcc_pass2() {
    local src="$1" pkg archive dir
    for pkg in mpfr gmp mpc; do
        archive=$(ls "$SOURCES_DIR/${pkg}"-*.tar.* | head -n1)
        tar -xf "$archive"
        dir=$(ls -d "${pkg}"-*/ | head -n1)
        mv -v "$dir" "$pkg"
    done

    case $(uname -m) in
        x86_64) sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;;
    esac

    sed '/thread_header =/s/@.*@/gthr-posix.h/' \
        -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in

    mkdir -v build && cd build
    ../configure \
        --build="$(../config.guess)" \
        --host="$LFS_TGT" \
        --target="$LFS_TGT" \
        LDFLAGS_FOR_TARGET=-L"$PWD/$LFS_TGT"/libgcc \
        --prefix=/usr \
        --with-build-sysroot="$LFS" \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-nls \
        --disable-multilib \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libsanitizer \
        --disable-libssp \
        --disable-libvtv \
        --enable-languages=c,c++
    make
    make DESTDIR="$LFS" install
    ln -sv gcc "$LFS/usr/bin/cc"
}

build_pkg 40.m4          "m4-"          b_m4
build_pkg 40.ncurses     "ncurses-"     b_ncurses
build_pkg 40.bash        "bash-"        b_bash
build_pkg 40.coreutils   "coreutils-"   b_coreutils
build_pkg 40.diffutils   "diffutils-"   b_diffutils
build_pkg 40.file        "file-"        b_file
build_pkg 40.findutils   "findutils-"   b_findutils
build_pkg 40.gawk        "gawk-"        b_gawk
build_pkg 40.grep        "grep-"        b_grep
build_pkg 40.gzip        "gzip-"        b_gzip
build_pkg 40.make        "make-"        b_make
build_pkg 40.patch       "patch-"       b_patch
build_pkg 40.sed         "sed-"         b_sed
build_pkg 40.tar         "tar-"         b_tar
build_pkg 40.xz          "xz-"          b_xz
build_pkg 40.binutils-p2 "binutils-"    b_binutils_pass2
build_pkg 40.gcc-p2      "gcc-"         b_gcc_pass2

log "temporary tools complete"
