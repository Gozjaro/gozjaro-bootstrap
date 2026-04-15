#!/usr/bin/env bash
# Download all source tarballs + patches into $LFS/sources and verify md5.
#
# Downloads run serially with wget writing a live progress bar straight to the
# terminal (no tee, no GNU parallel — both interfere with real-time output).
# A concise summary is still appended to $LFS/var/gozjaro/log/.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

require_root
ensure_dirs

command -v wget >/dev/null || die "wget not installed"

mkdir -p "$SOURCES_DIR"
chmod a+wt "$SOURCES_DIR"
cd "$SOURCES_DIR"

LIST="$GOZJARO_ROOT/config/packages.txt"
[ -f "$LIST" ] || die "package list missing: $LIST"

summary_log="${LOG_DIR}/$(date +%Y%m%d-%H%M%S)-20-fetch-sources.log"
touch "$summary_log"
logline() { printf '%s\n' "$*" | tee -a "$summary_log"; }

total=$(grep -cve '^$' "$LIST")
idx=0
fail_list="$SOURCES_DIR/.fetch-failed"
: > "$fail_list"

while IFS= read -r url; do
    [ -z "$url" ] && continue
    idx=$((idx + 1))
    fn="${url##*/}"

    if [ -s "$fn" ]; then
        logline "[$idx/$total] have $fn"
        continue
    fi

    logline "[$idx/$total] fetching $fn"
    ok=0
    for try in 1 2 3; do
        # Direct terminal output: no pipe, no tee. Progress bar is live.
        if wget --continue --timeout=30 --tries=1 \
                --progress=bar:force:noscroll \
                "$url"; then
            ok=1
            logline "[$idx/$total] ok $fn"
            break
        fi
        logline "[$idx/$total] retry $try $fn"
        sleep 2
    done
    [ "$ok" = "1" ] || { logline "[$idx/$total] FAILED $fn"; echo "$url" >> "$fail_list"; }
done < "$LIST"

if [ -s "$fail_list" ]; then
    warn "some downloads failed:"
    cat "$fail_list" >&2
    die "retry after fixing network/URLs"
fi

logline "fetching upstream md5sums from $LFS_MD5_URL"
if wget --timeout=30 --tries=3 --progress=bar:force:noscroll \
        -O md5sums.upstream "$LFS_MD5_URL"; then
    grep -E "  ($(ls | tr '\n' '|' | sed 's/|$//'))\$" md5sums.upstream > md5sums.local || true
    if [ -s md5sums.local ]; then
        logline "verifying $(wc -l < md5sums.local) tarballs"
        md5sum -c md5sums.local || die "md5 verification failed"
    else
        warn "no matching entries in upstream md5sums; skipping verification"
    fi
else
    warn "could not fetch upstream md5sums; skipping verification"
fi

log "sources ready in $SOURCES_DIR (summary: $summary_log)"
