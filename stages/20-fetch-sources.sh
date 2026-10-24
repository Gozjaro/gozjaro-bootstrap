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

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "need curl or wget installed"
fi

mkdir -p "$SOURCES_DIR"
chmod a+wt "$SOURCES_DIR"
cd "$SOURCES_DIR"

# Downloads are written to "<name>.part" and renamed only on success, so a
# .part file is never mistaken for a source archive. Leftover .part files are
# deliberately kept: the next run resumes them instead of restarting a
# multi-hundred-megabyte transfer from byte 0 on a slow link. A resumed file
# is still validated by the archive/checksum pass below, which deletes it if
# the result is not a valid tarball.

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
    # Returns a list of source URLs to download.
    # Priority: YAML manifests > legacy packages.txt.
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
            fetch_to "$patch_url" "${dest_path}.part" && mv -f -- "${dest_path}.part" "$dest_path" || \
                logline "  WARN: Failed to download patch $patch_fn"
        fi
    done <<< "$patch_urls"
}

# ---------------------------------------------------------------------------
# HTTP transfer primitives
# ---------------------------------------------------------------------------
# curl is preferred because it can abort a *slow but alive* transfer:
# --speed-limit/--speed-time kills the connection when the rate stays below
# the threshold. Plain `wget --timeout=30` never fires in that case, since
# every arriving byte resets the read timeout — that is exactly how a 30 MB
# tarball from a throttled upstream looks like a frozen stage for an hour.
#
# The UA is deliberately honest: a spoofed browser UA is actively harmful
# here, because the TUNA mirror (which serves the sourceware tree) answers
# 403 to a fake "Mozilla/5.0 ..." header, while every upstream we hit
# accepts this one.
UA="Gozjaro-Bootstrap/1.0"
: "${GOZJARO_MIN_SPEED:=10240}"     # bytes/s before a transfer counts as stalled
: "${GOZJARO_STALL_SECONDS:=30}"    # how long it may stay below that rate

export GOZJARO_MIN_SPEED GOZJARO_STALL_SECONDS

have_curl() { command -v curl >/dev/null 2>&1; }

# fetch_to <url> <dest>
# Single logical transfer, resuming an existing <dest> when possible.
# Returns 0 only when the server delivered a non-empty result.
# Progress goes to stderr (the terminal), so a big download is not silent.
fetch_to() {
    local url="$1" dest="$2" rc=0

    if have_curl; then
        local resume=()
        [ -s "$dest" ] && resume=(-C -)
        curl --fail --location --progress-bar --show-error \
             --connect-timeout 15 --retry 1 --retry-delay 2 \
             --speed-limit "$GOZJARO_MIN_SPEED" --speed-time "$GOZJARO_STALL_SECONDS" \
             -A "$UA" ${resume[@]+"${resume[@]}"} -o "$dest" "$url" || rc=$?
        if [ "$rc" -ne 0 ] && [ "${#resume[@]}" -gt 0 ]; then
            # The partial file is unusable (server ignored the range, connection
            # died mid-header, ...): restart this candidate from byte 0 once.
            rm -f -- "$dest" 2>/dev/null || true
            logline "    resume failed; restarting ${dest##*/} from scratch"
            rc=0
            curl --fail --location --progress-bar --show-error \
                 --connect-timeout 15 --retry 1 --retry-delay 2 \
                 --speed-limit "$GOZJARO_MIN_SPEED" --speed-time "$GOZJARO_STALL_SECONDS" \
                 -A "$UA" -o "$dest" "$url" || rc=$?
        fi
        [ "$rc" -eq 0 ] && [ -s "$dest" ]
        return $?
    fi

    local -a wopts=(--dns-timeout=10 --connect-timeout=15 --read-timeout=30 \
                    --timeout=30 --tries=2 --progress=bar:force:noscroll -U "$UA")
    if [ -s "$dest" ]; then
        wget "${wopts[@]}" -c -O "$dest" "$url" && [ -s "$dest" ] && return 0
        rm -f -- "$dest" 2>/dev/null || true
    fi
    wget "${wopts[@]}" -O "$dest" "$url" || rc=$?
    [ "$rc" -eq 0 ] && [ -s "$dest" ]
}

# ---------------------------------------------------------------------------
# Mirror + fallback download helper
# ---------------------------------------------------------------------------
# When mirroring is active, candidate URLs are [mirror, upstream]; otherwise
# just [upstream]. This makes a wrong mirror-map entry a cache miss (never a
# build failure). LFS patches are never mirrored.
#
# Usage: download_url <dest-filename> <url> [upstream-or-not]
#   $3 = "mirror" -> compute mirror candidate and try it FIRST, then fall back
#                    to the given URL (upstream).
#   $3 = "direct" -> try the URL as-is.
# Returns 0 on success, 1 if every candidate failed.
download_url() {
    local fn="$1" url="$2" mode="${3:-direct}"
    local candidates=()
    if [ "$mode" = "mirror" ]; then
        local m
        m=$(manifest_mirror_url "$url")
        [ "$m" != "$url" ] && candidates+=("$m")
    fi
    candidates+=("$url")

    # Never write the final filename directly, so an interrupted transfer can
    # never masquerade as a cached archive.
    local tmp="${fn}.part" c
    for c in "${candidates[@]}"; do
        [ -z "$c" ] && continue
        logline "    GET ${c}"
        if fetch_to "$c" "$tmp"; then
            mv -f -- "$tmp" "$fn"
            return 0
        fi
        # A failed candidate may have left a partial file with unknown
        # provenance; the next candidate always starts clean.
        rm -f -- "$tmp" 2>/dev/null || true
        logline "    failed: ${c}"
    done
    return 1
}

# ---------------------------------------------------------------------------
# Main download loop
# ---------------------------------------------------------------------------

MIRROR_ACTIVE=0

# Distinct mirror hosts declared in the map, e.g. mirrors.ustc.edu.cn.
mirror_hosts() {
    awk -F'\t' '!/^#/ && NF >= 2 { u=$2; sub(/^https?:\/\//, "", u); sub(/\/.*/, "", u); print u }' \
        "${GOZJARO_MIRROR_MAP:-/dev/null}" 2>/dev/null | sort -u
}

# Probe every mirror host once (cheap HEAD-ish GET on '/'). Enabling the
# mirror only when something answers avoids burning a 15s connect timeout per
# source file on a network where the mirrors are blocked.
mirror_reachable() {
    [ -r "${GOZJARO_MIRROR_MAP:-/dev/null}" ] || return 1
    local host
    while IFS= read -r host; do
        [ -z "$host" ] && continue
        if have_curl; then
            curl -sS -o /dev/null --max-time 5 --connect-timeout 3 "https://${host}/" && return 0
        else
            wget -q --spider --timeout=5 --tries=1 "https://${host}/" && return 0
        fi
    done < <(mirror_hosts)
    return 1
}

case "${GOZJARO_SOURCE_MIRROR:-auto}" in
    ustc|on|yes|1)
        MIRROR_ACTIVE=1
        ;;
    auto)
        # Default: use the mirrors when they are reachable, upstream otherwise.
        if mirror_reachable; then
            MIRROR_ACTIVE=1
        else
            logline "source mirror: no mirror host reachable; using upstream directly"
        fi
        ;;
    *)
        MIRROR_ACTIVE=0
        ;;
esac
[ "$MIRROR_ACTIVE" = "1" ] && logline "source mirror: enabled ($GOZJARO_MIRROR_MAP), with upstream fallback"
[ "$MIRROR_ACTIVE" = "1" ] && [ ! -r "${GOZJARO_MIRROR_MAP:-/dev/null}" ] && {
    logline "WARNING: mirror map not readable: ${GOZJARO_MIRROR_MAP}; using upstream directly"
}

source_urls=$(get_source_urls)
if [ -z "$source_urls" ]; then
    die "No source URLs found. Check config/packages/ or config/packages.txt"
fi

# ---------------------------------------------------------------------------
# LFS patch download pass
# ---------------------------------------------------------------------------
# Collect every patch URL referenced by the package manifests (package-level
# `patches:` blocks) plus the shared entries in patches.yaml, then fetch each
# into $SOURCES_DIR. These are applied verbatim by the build stages
# (30-cross-toolchain / 60-final-system). LFS patches are NOT mirrored — they
# stay on linuxfromscratch.org. Failures here are hard: the glibc FHS patch in
# particular is applied without `|| true`, so a missing patch aborts the build.
download_all_patches() {
    local all_urls
    all_urls=$({
        # Package-level patch URLs from every category manifest.
        grep -rhoE 'url:[[:space:]]*https?://[^[:space:]]+\.patch' \
            "${MANIFEST_DIR}"/*.yaml "${MANIFEST_DIR}"/*.yml 2>/dev/null \
            | sed -E 's/^url:[[:space:]]*//'
        # Shared/global patch URLs from patches.yaml (top-level `patches:` key).
        if [ -f "${MANIFEST_DIR}/patches.yaml" ]; then
            grep -hoE 'url:[[:space:]]*https?://[^[:space:]]+\.patch' \
                "${MANIFEST_DIR}/patches.yaml" 2>/dev/null \
                | sed -E 's/^url:[[:space:]]*//'
        fi
    } | sort -u)

    local count purl pfn pdst ptmp
    count=$(printf '%s\n' "$all_urls" | grep -cve '^\s*$' || true)
    logline "Downloading $count LFS patch files (upstream, not mirrored)"
    local pfail=0
    while IFS= read -r purl; do
        [ -z "$purl" ] && continue
        pfn="${purl##*/}"
        pdst="${SOURCES_DIR}/${pfn}"
        if [ -f "$pdst" ]; then
            logline "  patch: $pfn (cached)"
            continue
        fi
        ptmp="${pdst}.part"
        if fetch_to "$purl" "$ptmp"; then
            mv -f -- "$ptmp" "$pdst"
            logline "  patch: $pfn ok"
        else
            rm -f -- "$ptmp" 2>/dev/null || true
            logline "  patch: $pfn FAILED"
            pfail=1
        fi
    done <<< "$all_urls"
    [ "$pfail" = "0" ] || die "one or more LFS patches failed to download; check network"
}

download_all_patches

remove_invalid_cached_sources() {
    for mfile in "${MANIFEST_DIR}"/*.yaml "${MANIFEST_DIR}"/*.yml; do
        [ -f "$mfile" ] || continue

        local pkg_names
        pkg_names=$(_manifest_extract_names_bash "$mfile")
        for name in $pkg_names; do
            local checksum_value source_filename cached_file
            source_filename=$(manifest_get_filename "$name" 2>/dev/null || true)
            [ -n "$source_filename" ] || continue
            # Patch entries have no source archive of their own.
            if [[ "$source_filename" == *.patch ]]; then
                continue
            fi
            cached_file="${SOURCES_DIR}/$source_filename"
            [ -f "$cached_file" ] || continue

            checksum_value=$(manifest_get_field "$name" "checksum_value" 2>/dev/null)
            if [ -n "$checksum_value" ]; then
                if ! manifest_verify_checksum "$cached_file" "$name" 2>/dev/null; then
                    warn "discarding cached source with invalid checksum: $source_filename"
                    rm -f -- "$cached_file" || die "cannot remove invalid source: $cached_file"
                fi
            elif ! tar tf "$cached_file" >/dev/null 2>&1; then
                # No manifest checksum (e.g. acl, linux): a structural test
                # still catches truncated downloads before a build stage does.
                warn "discarding corrupt cached source archive: $source_filename"
                rm -f -- "$cached_file" || die "cannot remove corrupt source: $cached_file"
            fi
        done
    done
}

logline "Revalidating cached source archives (checksums + archive integrity)"
remove_invalid_cached_sources

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

    # Patches stay on upstream (LFS does not mirror them). Tarballs use the
    # mirror when GOZJARO_SOURCE_MIRROR=ustc, falling back to upstream.
    if [[ "$url" == *.patch ]]; then
        mode="direct"
    else
        [ "$MIRROR_ACTIVE" = "1" ] && mode="mirror" || mode="direct"
    fi

    logline "[$idx/$total] fetching $fn"
    if [ -f "$fn" ]; then
        logline "[$idx/$total] $fn already exists, skipping download"
        ok=1
    else
        ok=0
        for try in 1 2 3; do
            if download_url "$fn" "$url" "$mode"; then
                ok=1
                logline "[$idx/$total] ok $fn"
                break
            fi
            logline "[$idx/$total] retry $try $fn"
            sleep 2
        done
    fi
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
    local verified=0
    local skipped=0
    local errors=0

    for mfile in "${MANIFEST_DIR}"/*.yaml "${MANIFEST_DIR}"/*.yml; do
        [ -f "$mfile" ] || continue

        local pkg_names
        pkg_names=$(_manifest_extract_names_bash "$mfile")
        for name in $pkg_names; do
            local checksum_value source_filename matched_file
            checksum_value=$(manifest_get_field "$name" "checksum_value" 2>/dev/null)
            source_filename=$(manifest_get_filename "$name" 2>/dev/null || true)

            # Patch entries and other URL-less entries have no archive.
            if [ -z "$source_filename" ]; then
                skipped=$((skipped + 1))
                continue
            fi

            # Find matching file
            matched_file="${SOURCES_DIR}/$source_filename"
            if [ ! -f "$matched_file" ]; then
                matched_file=""
                for f in "${SOURCES_DIR}"/${name}-*; do
                    if [ -f "$f" ]; then
                        matched_file="$f"
                        break
                    fi
                done
            fi

            if [ -z "$matched_file" ]; then
                # Try partial match
                for f in "${SOURCES_DIR}"/*; do
                    if [ -f "$f" ] && echo "$f" | grep -qi "$name"; then
                        matched_file="$f"
                        break
                    fi
                done
            fi

            if [ -z "$matched_file" ]; then
                skipped=$((skipped + 1))
                continue
            fi

            if [ -n "$checksum_value" ]; then
                if manifest_verify_checksum "$matched_file" "$name" 2>/dev/null; then
                    verified=$((verified + 1))
                else
                    warn "checksum verification failed: $(basename "$matched_file")"
                    rm -f -- "$matched_file" 2>/dev/null || true
                    errors=$((errors + 1))
                fi
            elif tar tf "$matched_file" >/dev/null 2>&1; then
                # Packages without a manifest checksum still get a structural
                # check so a truncated download cannot reach a build stage.
                verified=$((verified + 1))
            else
                warn "corrupt source archive: $(basename "$matched_file")"
                rm -f -- "$matched_file" 2>/dev/null || true
                errors=$((errors + 1))
            fi
        done
    done

    logline "Checksum verification: $verified verified, $skipped skipped, $errors errors"
    return $errors
}

# Run manifest-based checksum verification
verify_downloaded_checksums || die "one or more source checksum verifications failed"

# Fallback: also verify against upstream LFS md5sums if available
logline "checking upstream md5sums from $LFS_MD5_URL"
if wget --timeout=30 --tries=3 --progress=bar:force:noscroll \
        -U "$UA" \
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

# ---------------------------------------------------------------------------
# Repo-local patches.
# patches/*.patch are Gozjaro's own in-tree fixes (e.g. the ca-certificates
# lazy-import guard) with NO upstream URL, so the URL fetcher above never sees
# them. Copy them into $SOURCES_DIR; build stages apply them via apply_patch(),
# which reads from $SOURCES_DIR.
# ---------------------------------------------------------------------------
repo_local_patches() {
    local pdir="${GOZJARO_ROOT}/patches"
    [ -d "$pdir" ] || return 0
    local p copied=0
    for p in "$pdir"/*.patch; do
        [ -f "$p" ] || continue
        cp -f "$p" "$SOURCES_DIR/$(basename "$p")"
        logline "repo-local patch: $(basename "$p") -> $SOURCES_DIR"
        copied=$((copied + 1))
    done
    [ "$copied" = "0" ] || logline "delivered $copied repo-local patch(es)"
}
repo_local_patches

# ---------------------------------------------------------------------------
# Installer (github.com/Gozjaro/gozjaro-installer-rs), pinned in lfs.env:
#   * source tarball (codeload @GOZJARO_INSTALL_REF, SHA256 hard gate) —
#     carries the chroot initramfs builder script
#   * release binary (GOZJARO_INSTALL_RELEASE + _BIN_SHA256) — the x86_64
#     ELF /usr/bin/gozjaro-install, built by the repo's GHA in a
#     debian:bullseye container (glibc 2.31). codeload tarballs and
#     release assets are byte-stable for a pinned ref, so the sha256
#     checks are hard gates: a changed/absent release fails the build
#     here, not later in the live image. Stage 77 deploys both.
# ---------------------------------------------------------------------------
if [ -n "${GOZJARO_INSTALL_REF:-}" ]; then
    install_tarball="gozjaro-install-${GOZJARO_INSTALL_REF}.tar.gz"
    install_url="https://codeload.github.com/Gozjaro/gozjaro-installer-rs/tar.gz/${GOZJARO_INSTALL_REF}"
    if [ -f "$SOURCES_DIR/$install_tarball" ]; then
        logline "installer $install_tarball already present"
    else
        logline "fetching installer source $install_tarball (${GOZJARO_INSTALL_REF:0:8})"
        wget --timeout=30 --tries=3 --progress=bar:force:noscroll \
            -U "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            -O "$SOURCES_DIR/$install_tarball" "$install_url" \
            || die "failed to download installer source $install_url"
    fi
    if [ -n "${GOZJARO_INSTALL_SHA256:-}" ]; then
        actual=$(sha256sum "$SOURCES_DIR/$install_tarball" | awk '{print $1}')
        [ "$actual" = "$GOZJARO_INSTALL_SHA256" ] || \
            die "installer tarball $install_tarball sha256 mismatch: got $actual, want $GOZJARO_INSTALL_SHA256"
        logline "installer $install_tarball sha256 verified"
    fi
    if [ -n "${GOZJARO_INSTALL_RELEASE:-}" ]; then
        install_bin="gozjaro-install-x86_64-linux"
        bin_url="https://github.com/Gozjaro/gozjaro-installer-rs/releases/download/${GOZJARO_INSTALL_RELEASE}/gozjaro-install-x86_64-linux"
        if [ -f "$SOURCES_DIR/$install_bin" ]; then
            logline "installer binary $install_bin already present"
        else
            logline "fetching installer release binary $install_bin (${GOZJARO_INSTALL_RELEASE})"
            wget --timeout=30 --tries=3 --progress=bar:force:noscroll \
                -U "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                -O "$SOURCES_DIR/$install_bin" "$bin_url" \
                || die "failed to download installer binary $bin_url"
        fi
        if [ -n "${GOZJARO_INSTALL_BIN_SHA256:-}" ]; then
            actual=$(sha256sum "$SOURCES_DIR/$install_bin" | awk '{print $1}')
            [ "$actual" = "$GOZJARO_INSTALL_BIN_SHA256" ] || \
                die "installer binary $install_bin sha256 mismatch: got $actual, want $GOZJARO_INSTALL_BIN_SHA256"
            logline "installer $install_bin sha256 verified"
        fi
    fi
fi

log "sources ready in $SOURCES_DIR (summary: $summary_log)"