#!/usr/bin/env bash
# Chapter 5 of the LFS book: cross-toolchain built as user 'lfs'.
# Invoked by build.sh via `su -l lfs`.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
# shellcheck source=../lib/pkg.sh
. "$GOZJARO_ROOT/lib/pkg.sh"

start_log 30-cross-toolchain
require_lfs_user

[ -n "${LFS_TGT:-}" ] || die "LFS_TGT not set (check ~/.bashrc)"

build_binutils_pass1() {
    local src="$1"
    mkdir -v build && cd build
    ../configure --prefix="$LFS/tools" \
        --with-sysroot="$LFS" \
        --target="$LFS_TGT" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --enable-new-dtags \
        --enable-default-hash-style=gnu
    make
    make install
}

build_gcc_pass1() {
    local src="$1"
    # Fold in mpfr/gmp/mpc.
    local pkg archive dir
    for pkg in mpfr gmp mpc; do
        archive=$(ls "$SOURCES_DIR/${pkg}"-*.tar.* | head -n1)
        [ -n "$archive" ] || die "missing $pkg tarball"
        tar -xf "$archive"
        dir=$(ls -d "${pkg}"-*/ | head -n1)
        mv -v "$dir" "$pkg"
    done

    case $(uname -m) in
        x86_64)
            sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
            ;;
    esac

    mkdir -v build && cd build
    ../configure \
        --target="$LFS_TGT" \
        --prefix="$LFS/tools" \
        --with-glibc-version=2.41 \
        --with-sysroot="$LFS" \
        --with-newlib \
        --without-headers \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdcxx \
        --enable-languages=c,c++
    make
    make install

    cd "$src"
    # Install limits.h (LFS book section).
    cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
        "$(dirname "$("$LFS_TGT"-gcc -print-libgcc-file-name)")"/include/limits.h
}

build_linux_headers() {
    local src="$1"
    make mrproper
    make headers
    find usr/include -type f ! -name '*.h' -delete
    cp -rv usr/include "$LFS/usr"
}

build_glibc() {
    local src="$1"

    case $(uname -m) in
        i?86)
            ln -sfv ld-linux.so.2 "$LFS/lib/ld-lsb.so.3"
            ;;
        x86_64)
            ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64/"
            ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64/ld-lsb-x86-64.so.3"
            ;;
    esac

    apply_patch "$src" "glibc-2.41-fhs-1.patch"

    mkdir -v build && cd build
    echo "rootsbindir=/usr/sbin" > configparms
    ../configure \
        --prefix=/usr \
        --host="$LFS_TGT" \
        --build="$(../scripts/config.guess)" \
        --enable-kernel=4.19 \
        --with-headers="$LFS/usr/include" \
        --disable-nscd \
        libc_cv_slibdir=/usr/lib
    make
    make DESTDIR="$LFS" install
    sed '/RTLDLIST=/s@/usr@@g' -i "$LFS/usr/bin/ldd"

    # Integrity check.
    echo 'int main(){}' | "$LFS_TGT-gcc" -xc -o a.out -
    readelf -l a.out | grep -q ld-linux || die "glibc sanity check failed"
    rm -v a.out
}

build_libstdcxx() {
    local src="$1"
    # Re-extract GCC tree for libstdc++ build (isolated from pass1 build dir).
    local gcc_src
    gcc_src=$(extract_pkg "gcc-")
    cd "$gcc_src"
    mkdir -v build && cd build
    ../libstdc++-v3/configure \
        --host="$LFS_TGT" \
        --build="$(../config.guess)" \
        --prefix=/usr \
        --disable-multilib \
        --disable-nls \
        --disable-libstdcxx-pch \
        --with-gxx-include-dir=/tools/"$LFS_TGT"/include/c++/14.2.0
    make
    make DESTDIR="$LFS" install
    rm -v "$LFS"/usr/lib/lib{stdc++{,exp,fs},supc++}.la
    cd / && rm -rf "$gcc_src"
}

build_pkg 30.binutils-pass1 "binutils-" build_binutils_pass1
build_pkg 30.gcc-pass1      "gcc-"      build_gcc_pass1
build_pkg 30.linux-headers  "linux-"    build_linux_headers
build_pkg 30.glibc          "glibc-"    build_glibc
build_pkg 30.libstdcxx      "gcc-"      build_libstdcxx

log "cross-toolchain complete"
