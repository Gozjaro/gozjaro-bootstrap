#!/usr/bin/env bash
# Download all source tarballs + patches into $LFS/sources and verify checksums.
#
# Downloads run serially with wget writing a live progress bar straight to the
# terminal (no tee, no GNU parallel — both interfere with real-time output).
# A concise summary is still appended to $LFS/var/gozjaro/log/.
#
# Package sources are read from YAML manifests in config/packages/, with
# backward-compatible fallback to the legacy packages.txt format.
#
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

require_root
ensure_dirs

command -v wget >/dev/null || die "wget not installed"

mkdir -p "$SOURCES_DIR"
chmod a+wt "$SOURCES_DIR"
cd "$SOURCES_DIR"

# ---------------------------------------------------------------------------
# Manifest library
# ---------------------------------------------------------------------------
# shellcheck source=./lib/manifest.sh
. "${GOZJARO_ROOT}/lib/manifest.sh"

summary_log="${LOG_DIR}/$(date +%Y%m%d-%H%M%S)-20-fetch-sources.log"
touch "$summary_log"
logline() { printf '%s\n' "$*" | tee -a "$summary_log"; }

# ---------------------------------------------------------------------------
# Source URL list: YAML manifests or legacy packages.txt
# ---------------------------------------------------------------------------

get_source_urls() {
    """
    Returns a list of source URLs to download.
    Priority: YAML manifests > legacy packages.txt
    """
    local urls=()
    local has_yaml=0

    # Try YAML manifests first
    if [ -d "$MANIFEST_DIR" ]; then
        for mfile in "${MANIFEST_DIR}"/*.yaml "${MANIFEST_DIR}"/*.yml; do
            [ -f "$mfile" ] || continue
            # Extract URLs from package definitions
            local pkg_names
            pkg_names=$(_manifest_extract_names_bash "$mfile")
            if [ -n "$pkg_names" ]; then
                has_yaml=1
                for name in $pkg_names; do
                    local url
                    url=$(manifest_get_download_url "$name" 2>/dev/null)
                    if [ -n "$url" ]; then
                        urls+=("$url")
                    fi
                done
            fi
        done
    fi

    if [ "$has_yaml" = "1" ]; then
        printf '%s\n' "${urls[@]}"
    elif [ -f "$LEGACY_PACKAGES_TXT" ]; then
        # Fallback to legacy format
        grep -vE '^\s*$' "$LEGACY_PACKAGES_TXT"
    elif [ -f "$LEGACY_BASE_PACKAGES_TXT" ]; then
        grep -vE '^\s*$' "$LEGACY_BASE_PACKAGES_TXT"
    else
        logline "WARNING: No package sources found (manifests or legacy)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Patch download helper
# ---------------------------------------------------------------------------

download_patches_for_package() {
    local pkg_name="$1"
    local categories="${2:-base system kernel development live}"

    local patch_urls
    patch_urls=$(manifest_list_patches "$pkg_name" $categories 2>/dev/null)

    if [ -z "$patch_urls" ]; then
        return 0
    fi

    while IFS= read -r patch_url; do
        [ -z "$patch_url" ] && continue
        local patch_fn="${patch_url##*/}"
        local dest_path="${PATCHES_DIR:-.}/${patch_fn}"

        logline "  patch: $patch_fn"
        if [ ! -f "$dest_path" ]; then
            wget --timeout=30 --tries=1 --progress=bar:force:noscroll \
                 -O "$dest_path" "$patch_url" 2>/dev/null || \
                logline "  WARN: Failed to download patch $patch_fn"
        fi
    done <<< "$patch_urls"
}

# ---------------------------------------------------------------------------
# Main download loop
# ---------------------------------------------------------------------------

source_urls=$(get_source_urls)
if [ -z "$source_urls" ]; then
    die "No source URLs found. Check config/packages/ or config/packages.txt"
fi

# Count total URLs
total=$(echo "$source_urls" | grep -cve '^\s*$')
idx=0
fail_list="$SOURCES_DIR/.fetch-failed"
: > "$fail_list"

logline "Downloading $total source files from YAML manifests (legacy fallback active)"

echo "$source_urls" | grep -vE '^\s*$' | while IFS= read -r url; do
    [ -z "$url" ] && continue
    idx=$((idx + 1))
    fn="${url##*/}"

    logline "[$idx/$total] fetching $fn"
    ok=0
    for try in 1 2 3; do
        rm -f "$fn"
        if wget --timeout=30 --tries=1 \
                --progress=bar:force:noscroll \
                "$url"; then
            ok=1
            logline "[$idx/$total] ok $fn"
            break
        fi
        logline "[$idx/$total] retry $try $fn"
        sleep 2
    done
    if [ "$ok" = "0" ]; then
        logline "[$idx/$total] FAILED $fn"
        echo "$url" >> "$fail_list"
    fi
done

# Check for failures (fail_list is written inside subshell, so check files)
failed_files=""
if [ -s "$fail_list" ]; then
    failed_files=$(cat "$fail_list")
fi

if [ -n "$failed_files" ]; then
    warn "some downloads failed:"
    echo "$failed_files" >&2
    die "retry after fixing network/URLs"
fi

# ---------------------------------------------------------------------------
# Checksum verification
# ---------------------------------------------------------------------------

verify_downloaded_checksums() {
    """
    Verify checksums for all downloaded source files using manifest data.
    Falls back to upstream md5sums if no manifest checksums are configured.
    """
    local verified=0
    local skipped=0
    local errors=0

    for mfile in "${MANIFEST_DIR}"/*.yaml "${MANIFEST_DIR}"/*.yml; do
        [ -f "$mfile" ] || continue

        local pkg_names
        pkg_names=$(_manifest_extract_names_bash "$mfile")
        for name in $pkg_names; do
            local checksum_value
            checksum_value=$(manifest_get_field "$name" "checksum_value" 2>/dev/null)

            if [ -z "$checksum_value" ]; then
                skipped=$((skipped + 1))
                continue
            fi

            # Find matching file
            local matched_file=""
            for f in "${SOURCES_DIR}"/${name}-*; do
                [ -f "$f" ] && matched_file="$f" && break
            done

            if [ -z "$matched_file" ]; then
                # Try partial match
                for f in "${SOURCES_DIR}"/*; do
                    if [ -f "$f" ] && echo "$f" | grep -qi "$name"; then
                        matched_file="$f"
                        break
                    fi
                done
            fi

            if [ -n "$matched_file" ]; then
                if manifest_verify_checksum "$matched_file" "$name" 2>/dev/null; then
                    verified=$((verified + 1))
                else
                    errors=$((errors + 1))
                fi
            fi
        done
    done

    logline "Checksum verification: $verified verified, $skipped skipped (no checksum), $errors errors"
    return $errors
}

# Run manifest-based checksum verification
verify_downloaded_checksums || true

# Fallback: also verify against upstream LFS md5sums if available
logline "checking upstream md5sums from $LFS_MD5_URL"
if wget --timeout=30 --tries=3 --progress=bar:force:noscroll \
        -O md5sums.upstream "$LFS_MD5_URL" 2>/dev/null; then
    grep -E "  ($(ls | tr '\n' '|' | sed 's/|$//'))\$" md5sums.upstream > md5sums.local 2>/dev/null || true
    if [ -s md5sums.local ]; then
        logline "verifying $(wc -l < md5sums.local) tarballs against upstream md5sums"
        if ! md5sum -c md5sums.local 2>/dev/null; then
            warn "some md5 checks failed; manifest checksums take priority"
        fi
    else
        logline "no matching entries in upstream md5sums; skipping verification"
    fi
    rm -f md5sums.upstream md5sums.local
else
    logline "could not fetch upstream md5sums; relying on manifest checksums only"
fi

log "sources ready in $SOURCES_DIR (summary: $summary_log)"