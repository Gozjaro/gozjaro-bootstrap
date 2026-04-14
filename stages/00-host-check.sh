#!/usr/bin/env bash
# Validate that the host meets LFS minimum tool versions.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 00-host-check

LC_ALL=C
fail=0
bail() { die "$1"; }

grep --version >/dev/null 2>&1 || bail "grep does not work"
sed '' /dev/null           || bail "sed does not work"
sort --version --check /dev/null || bail "sort does not work"

ver_check() {
    if ! type -p "$2" &>/dev/null; then
        printf 'ERROR: cannot find %s (%s)\n' "$2" "$1"; fail=1; return 1
    fi
    local v
    v=$("$2" --version 2>&1 | grep -E -o '[0-9]+\.[0-9.]+[a-z]*' | head -n1)
    if printf '%s\n' "$3" "$v" | sort --version-sort --check &>/dev/null; then
        printf 'OK:  %-12s %-10s >= %s\n' "$1" "$v" "$3"
    else
        printf 'ERR: %-12s %-10s <  %s\n' "$1" "$v" "$3"; fail=1
    fi
}

ver_kernel() {
    local kver
    kver=$(uname -r | grep -E -o '^[0-9.]+')
    if printf '%s\n' "$1" "$kver" | sort --version-sort --check &>/dev/null; then
        printf 'OK:  Kernel       %-10s >= %s\n' "$kver" "$1"
    else
        printf 'ERR: Kernel       %-10s <  %s\n' "$kver" "$1"; fail=1
    fi
}

ver_check Coreutils sort    8.1     || bail "Coreutils too old"
ver_check Bash      bash    3.2
ver_check Binutils  ld      2.13.1
ver_check Bison     bison   2.7
ver_check Diffutils diff    2.8.1
ver_check Findutils find    4.2.31
ver_check Gawk      gawk    4.0.1
ver_check GCC       gcc     5.2
ver_check "G++"     g++     5.2
ver_check Grep      grep    2.5.1a
ver_check Gzip      gzip    1.3.12
ver_check M4        m4      1.4.10
ver_check Make      make    4.0
ver_check Patch     patch   2.5.4
ver_check Perl      perl    5.8.8
ver_check Python    python3 3.4
ver_check Sed       sed     4.1.5
ver_check Tar       tar     1.22
ver_check Texinfo   texi2any 5.0
ver_check Xz        xz      5.0.0
ver_kernel 4.19

if mount | grep -q 'devpts on /dev/pts' && [ -e /dev/ptmx ]; then
    log "kernel supports UNIX 98 PTY"
else
    warn "kernel does NOT advertise UNIX 98 PTY"; fail=1
fi

alias_check() {
    if "$1" --version 2>&1 | grep -qi "$2"; then
        printf 'OK:  alias %-4s is %s\n' "$1" "$2"
    else
        printf 'ERR: alias %-4s is NOT %s\n' "$1" "$2"; fail=1
    fi
}
alias_check awk  GNU
alias_check yacc Bison
alias_check sh   Bash

if printf 'int main(){}\n' | g++ -x c++ - -o /tmp/gozjaro_cc_test >/dev/null 2>&1; then
    log "g++ works"; rm -f /tmp/gozjaro_cc_test
else
    warn "g++ does NOT work"; fail=1
fi

if [ -z "$(nproc 2>/dev/null || true)" ]; then
    warn "nproc missing"; fail=1
else
    log "nproc reports $(nproc) cores"
fi

[ "$fail" = "0" ] || die "host checks failed; install/upgrade the tools above"
log "host OK"
