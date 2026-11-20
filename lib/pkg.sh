# Package build helpers.
# shellcheck shell=bash
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# find_tarball <basename-prefix>
# echoes the first matching tarball under $SOURCES_DIR (e.g. "binutils-").
find_tarball() {
    local prefix="$1" f
    # Case-sensitive first.
    for f in "$SOURCES_DIR/${prefix}"*.tar.*; do
        [ -e "$f" ] || continue
        printf '%s\n' "$f"
        return 0
    done
    # Fallback: case-insensitive (handles e.g. Jinja2 vs jinja2).
    f=$(shopt -s nocaseglob nullglob
        files=( "$SOURCES_DIR/${prefix}"*.tar.* )
        [ "${#files[@]}" -gt 0 ] && printf '%s\n' "${files[0]}" || true)
    if [ -n "$f" ]; then
        printf '%s\n' "$f"
        return 0
    fi
    die "no tarball for prefix '$prefix' in $SOURCES_DIR; run 'sudo ./build.sh 20-fetch-sources'"
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
    if ! tarball=$(find_tarball "$prefix"); then
        return 1
    fi
    # Catch truncated/corrupt archives before extraction. Drop the bad file so
    # the next fetch run cannot reuse it from the source cache.
    if ! tar tf "$tarball" >/dev/null 2>&1; then
        rm -f -- "$tarball" 2>/dev/null || true
        die "corrupt source archive '$tarball' (truncated or unreadable); removed it — rerun 'sudo ./build.sh 20-fetch-sources' to re-download"
    fi
    # Distinct top-level path components in the archive.
    tops=$(tar tf "$tarball" 2>/dev/null | awk -F/ 'NF{print $1}' | sort -u)
    if [ -n "$tops" ] && [ "$(printf '%s\n' "$tops" | wc -l)" = "1" ]; then
        top="$tops"
        target="${workdir}/${top}"
        [ -e "$target" ] && rm -rf "$target"
        if ! ( cd "$workdir" && tar -xf "$tarball" ); then
            rm -rf "$target"
            die "failed to extract source archive '$tarball'; check free disk space and permissions, then rerun 'sudo ./build.sh 20-fetch-sources'"
        fi
    else
        # Tarball has no single top dir (e.g. tzdata). Extract into a
        # synthesised dir named after the tarball stem.
        stem=$(basename "$tarball")
        stem=${stem%.tar.*}
        target="${workdir}/${stem}"
        [ -e "$target" ] && rm -rf "$target"
        mkdir -p "$target"
        if ! ( cd "$target" && tar -xf "$tarball" ); then
            rm -rf "$target"
            die "failed to extract source archive '$tarball'; check free disk space and permissions, then rerun 'sudo ./build.sh 20-fetch-sources'"
        fi
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
    local tarball
    # A tarball delivered after the package marker (version bump, re-fetch)
    # invalidates the marker: rebuild so the new source is actually used.
    if tarball=$(find_tarball "$prefix"); then
        if is_done "$marker" && [ ! "$(marker_path "$marker")" -ot "$tarball" ]; then
            log "skip $marker (already done)"
            return 0
        fi
        if is_done "$marker"; then
            log "rebuilding $marker (marker older than $(basename "$tarball"))"
        fi
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
