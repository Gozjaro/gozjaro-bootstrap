# Package build helpers.
# shellcheck shell=bash
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# find_tarball <basename-prefix>
# echoes the first matching tarball under $SOURCES_DIR (e.g. "binutils-").
find_tarball() {
    local prefix="$1" f
    for f in "$SOURCES_DIR/${prefix}"*.tar.*; do
        [ -e "$f" ] || continue
        printf '%s\n' "$f"
        return 0
    done
    die "no tarball for prefix '$prefix' in $SOURCES_DIR"
}

# tarball_topdir <tarball>
# echoes the top-level directory inside a tarball.
tarball_topdir() {
    tar tf "$1" 2>/dev/null | head -n1 | cut -d/ -f1
}

# extract_pkg <prefix> [workdir]
# Extracts into workdir (default $SOURCES_DIR), echoes absolute path of the extracted dir.
extract_pkg() {
    local prefix="$1"
    local workdir="${2:-$SOURCES_DIR}"
    local tarball tops top target stem
    tarball=$(find_tarball "$prefix")
    # Distinct top-level path components in the archive.
    tops=$(tar tf "$tarball" 2>/dev/null | awk -F/ 'NF{print $1}' | sort -u)
    if [ "$(printf '%s\n' "$tops" | wc -l)" = "1" ]; then
        top="$tops"
        target="${workdir}/${top}"
        [ -e "$target" ] && rm -rf "$target"
        ( cd "$workdir" && tar -xf "$tarball" )
    else
        # Tarball has no single top dir (e.g. tzdata). Extract into a
        # synthesised dir named after the tarball stem.
        stem=$(basename "$tarball")
        stem=${stem%.tar.*}
        target="${workdir}/${stem}"
        [ -e "$target" ] && rm -rf "$target"
        mkdir -p "$target"
        ( cd "$target" && tar -xf "$tarball" )
    fi
    printf '%s\n' "$target"
}

# apply_patch <srcdir> <patchname> [strip]
apply_patch() {
    local srcdir="$1" patch="$2" strip="${3:-1}"
    local p="$SOURCES_DIR/$patch"
    [ -f "$p" ] || die "patch not found: $p"
    ( cd "$srcdir" && patch "-Np${strip}" -i "$p" )
}

# build_pkg <marker-name> <tarball-prefix> <build-func>
# Runs build-func with cwd = extracted source dir, only if marker not set.
# build-func may re-cd; extracted dir passed as $1.
build_pkg() {
    local marker="$1" prefix="$2" func="$3"
    if is_done "$marker"; then
        log "skip $marker (already done)"
        return 0
    fi
    step "build $marker"
    local srcdir
    srcdir=$(extract_pkg "$prefix")
    ( cd "$srcdir" && "$func" "$srcdir" )
    # Clean up extracted tree to save disk; keep sources tar intact.
    rm -rf "$srcdir"
    mark_done "$marker"
    log "done $marker"
}
