#!/usr/bin/env bash
# Download all source tarballs + patches into $LFS/sources and verify md5.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 20-fetch-sources
require_root

command -v wget >/dev/null || die "wget not installed"

mkdir -p "$SOURCES_DIR"
chmod a+wt "$SOURCES_DIR"
cd "$SOURCES_DIR"

LIST="$GOZJARO_ROOT/config/packages.txt"
[ -f "$LIST" ] || die "package list missing: $LIST"

download_one() {
    local url="$1" fn
    fn="${url##*/}"
    if [ -s "$fn" ]; then
        log "have $fn"
        return 0
    fi
    local try
    for try in 1 2 3; do
        if wget --continue --timeout=20 --tries=1 -q --show-progress "$url"; then
            log "got $fn"
            return 0
        fi
        warn "retry $try: $fn"
        sleep 2
    done
    warn "FAILED: $url"
    return 1
}

fail_list="$SOURCES_DIR/.fetch-failed"
: > "$fail_list"

if command -v parallel >/dev/null 2>&1; then
    export -f download_one log warn
    export _c_grn _c_ylw _c_off
    # shellcheck disable=SC2016
    parallel -j "$PARALLEL_DOWNLOADS" --halt soon,fail=0 \
        'download_one {} || echo {} >> '"$fail_list" < "$LIST"
else
    warn "GNU parallel not found; downloading serially"
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        download_one "$url" || echo "$url" >> "$fail_list"
    done < "$LIST"
fi

if [ -s "$fail_list" ]; then
    warn "some downloads failed:"
    cat "$fail_list" >&2
    die "retry after fixing network/URLs"
fi

# Fetch upstream md5sums for verification and install a patched copy limited
# to tarballs we actually downloaded (the upstream list covers every LFS pkg).
log "fetching upstream md5sums from $LFS_MD5_URL"
if wget -q -O md5sums.upstream "$LFS_MD5_URL"; then
    grep -E "  ($(ls | tr '\n' '|' | sed 's/|$//'))\$" md5sums.upstream > md5sums.local || true
    if [ -s md5sums.local ]; then
        log "verifying $(wc -l < md5sums.local) tarballs"
        md5sum -c md5sums.local || die "md5 verification failed"
    else
        warn "no matching entries in upstream md5sums; skipping verification"
    fi
else
    warn "could not fetch upstream md5sums; skipping verification"
fi

log "sources ready in $SOURCES_DIR"
