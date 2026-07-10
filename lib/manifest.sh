# Gozjaro Bootstrap Manifest Library
# Shell functions for reading and managing YAML package manifests.
# Source this file: . "${GOZJARO_ROOT}/lib/manifest.sh"
#
# This library provides pure-bash manifest parsing with fallback to
# the Python manifest-parser.py when available.

# Ensure common.sh is loaded
if ! declare -f log >/dev/null 2>&1; then
    if [ -f "${GOZJARO_ROOT}/lib/common.sh" ]; then
        # shellcheck source=common.sh
        . "${GOZJARO_ROOT}/lib/common.sh"
    fi
fi

MANIFEST_DIR="${MANIFEST_DIR:-"${GOZJARO_ROOT}/config/packages"}"
export MANIFEST_DIR

# Legacy support
LEGACY_PACKAGES_TXT="${GOZJARO_ROOT}/config/packages.txt"
LEGACY_BASE_PACKAGES_TXT="${GOZJARO_ROOT}/config/base-packages.txt"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Use python parser if available, otherwise use pure bash fallback
_manifest_parser_available() {
    local parser="${GOZJARO_ROOT}/tools/manifest-parser.py"
    if [ -f "$parser" ] && command -v python3 >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Parse a YAML manifest file using Python parser
# Outputs JSON to stdout
# Usage: _manifest_parse_with_python <package-name> [categories...]
_manifest_parse_with_python() {
    local parser="${GOZJARO_ROOT}/tools/manifest-parser.py"
    local pkg_name="$1"
    shift
    local categories="$*"
    python3 "$parser" "$pkg_name" --categories $categories --manifest-dir "$MANIFEST_DIR" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Package listing
# ---------------------------------------------------------------------------

# List all package names from manifests
# Usage: manifest_list_packages [category ...]
# Example: manifest_list_packages base system kernel
manifest_list_packages() {
    local categories="$*"
    if _manifest_parser_available; then
        _manifest_parse_with_python --list $categories
    else
        _manifest_list_packages_bash $categories
    fi
}

# Pure bash fallback for listing packages
_manifest_list_packages_bash() {
    local categories="$*"
    local manifest_files=()

    if [ -n "$categories" ]; then
        for cat in $categories; do
            for ext in yaml yml; do
                [ -f "${MANIFEST_DIR}/${cat}.${ext}" ] && manifest_files+=("${MANIFEST_DIR}/${cat}.${ext}")
            done
        done
    else
        for f in "${MANIFEST_DIR}"/*.yaml "${MANIFEST_DIR}"/*.yml; do
            [ -f "$f" ] && manifest_files+=("$f")
        done
    fi

    for mfile in "${manifest_files[@]}"; do
        _manifest_extract_names_bash "$mfile"
    done | sort -u
}

# Extract package names from a YAML file (pure bash)
# Only extracts top-level package names (indented with exactly 2 spaces before -)
_manifest_extract_names_bash() {
    local file="$1"
    # Match lines like "  - name: pkgname" but not "      - name: patchfile"
    grep -E '^  - name:' "$file" 2>/dev/null | sed 's/^  - name:[[:space:]]*//' | sed 's/[[:space:]]*//g; s/"//g; s/'"'"'//g'
}

# List all packages from legacy packages.txt
# Usage: manifest_list_legacy
manifest_list_legacy() {
    if [ -f "$LEGACY_PACKAGES_TXT" ]; then
        grep -vE '^\s*$' "$LEGACY_PACKAGES_TXT" | while IFS= read -r line; do
            # Extract package name from URL
            local fn="${line##*/}"
            echo "$fn"
        done
    fi
}

# ---------------------------------------------------------------------------
# Package info retrieval
# ---------------------------------------------------------------------------

# Get a specific field for a package
# Usage: manifest_get_field <package-name> <field> [category ...]
# Fields: version, url, checksum_type, checksum_value, build_system
# Example: manifest_get_field bash url base system
manifest_get_field() {
    local pkg_name="$1"
    local field="$2"
    local categories="${3:-}"

    if _manifest_parser_available; then
        local json
        json=$(_manifest_parse_with_python "$pkg_name" $categories 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$json" ]; then
            return 1
        fi
        _manifest_json_get_field "$json" "$field"
    else
        _manifest_get_field_bash "$pkg_name" "$field" $categories
    fi
}

# Extract a field from JSON output (uses grep/sed, no jq dependency)
_manifest_json_get_field() {
    local json="$1"
    local field="$2"

    case "$field" in
        name)
            echo "$json" | grep '"name"' | head -1 | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
            ;;
        version)
            echo "$json" | grep '"version"' | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
            ;;
        url|raw_url)
            echo "$json" | grep "\"$field\"" | head -1 | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
            ;;
        checksum_type)
            echo "$json" | grep '"type"' | head -1 | sed 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
            ;;
        checksum_value)
            echo "$json" | grep '"value"' | head -1 | sed 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
            ;;
        build_system)
            echo "$json" | grep '"system"' | head -1 | sed 's/.*"system"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
            ;;
        *)
            echo "$json" | grep "\"$field\"" | head -1 | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*//' | sed 's/[,[:space:]]*//g; s/"//g'
            ;;
    esac
}

# Pure bash fallback for field retrieval
_manifest_get_field_bash() {
    local pkg_name="$1"
    local field="$2"
    local categories="${3:-}"
    local manifest_files=()

    if [ -n "$categories" ]; then
        for cat in $categories; do
            for ext in yaml yml; do
                [ -f "${MANIFEST_DIR}/${cat}.${ext}" ] && manifest_files+=("${MANIFEST_DIR}/${cat}.${ext}")
            done
        done
    else
        for f in "${MANIFEST_DIR}"/*.yaml "${MANIFEST_DIR}"/*.yml; do
            [ -f "$f" ] && manifest_files+=("$f")
        done
    fi

    for mfile in "${manifest_files[@]}"; do
        local found
        found=$(_manifest_find_package_bash "$mfile" "$pkg_name")
        if [ -n "$found" ]; then
            _manifest_parse_field_from_yaml "$found" "$field"
            return 0
        fi
    done
    return 1
}

# Find a package block in a YAML file (pure bash)
_manifest_find_package_bash() {
    local file="$1"
    local pkg_name="$2"

    if [ ! -f "$file" ]; then
        return
    fi

    local in_pkg=0
    local current_name=""
    local block=""
    local indent_level=0

    while IFS= read -r line; do
        # Skip comments and empty lines at top level
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ "$line" =~ ^[[:space:]]*$ ]]; then
            continue
        fi

        # Detect package list item
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
            # Output previous block if matched
            if [ "$found" = "yes" ] && [ -n "$block" ]; then
                echo "$block"
                return 0
            fi
            current_name=$(echo "$line" | sed 's/.*name:[[:space:]]*//' | sed 's/[[:space:]]*//g; s/"//g; s/'"'"'//g')
            block="$line"
            in_pkg=1
            continue
        fi

        if [ "$in_pkg" = "1" ]; then
            block+=$'\n'"$line"
        fi
    done < "$file"

    # Check last block
    if [ "$current_name" = "$pkg_name" ]; then
        echo "$block"
        return 0
    fi
}

# Parse a specific field from a package YAML block
_manifest_parse_field_from_yaml() {
    local block="$1"
    local field="$2"

    case "$field" in
        name)
            echo "$block" | grep '^\s*-\s*name:' | head -1 | sed 's/.*name:[[:space:]]*//' | sed 's/[[:space:]]*//g; s/"//g; s/'"'"'//g'
            ;;
        version)
            echo "$block" | grep '^\s*version:' | head -1 | sed 's/.*version:[[:space:]]*//' | sed 's/[[:space:]]*//g; s/"//g; s/'"'"'//g'
            ;;
        category)
            echo "$block" | grep '^\s*category:' | head -1 | sed 's/.*category:[[:space:]]*//' | sed 's/[[:space:]]*//g; s/"//g; s/'"'"'//g'
            ;;
        url)
            echo "$block" | grep '^\s*url:' | head -1 | sed 's/.*url:[[:space:]]*//' | sed 's/[[:space:]]*//g; s/"//g; s/'"'"'//g'
            ;;
        checksum_type)
            echo "$block" | grep '^\s*type:' | head -1 | sed 's/.*type:[[:space:]]*//' | sed 's/[[:space:]]*//g; s/"//g; s/'"'"'//g'
            ;;
        checksum_value)
            echo "$block" | grep '^\s*value:' | head -1 | sed 's/.*value:[[:space:]]*//' | sed 's/[[:space:]]*//g; s/"//g; s/'"'"'//g'
            ;;
        build_system)
            echo "$block" | grep '^\s*system:' | head -1 | sed 's/.*system:[[:space:]]*//' | sed 's/[[:space:]]*//g; s/"//g; s/'"'"'//g'
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Resolve download URL and filename for a package
# ---------------------------------------------------------------------------

# Resolve URL template variables like {{ GOZJARO_KERNEL_VERSION }}
_manifest_resolve_url() {
    local url="$1"
    local env_prefix="${2:-GOZJARO_}"

    # Replace {{ VAR_NAME }} with value from environment or default
    while [[ "$url" =~ \{\{([A-Za-z_][A-Za-z0-9_]*)\}\} ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_value="${!var_name:-}"
        if [ -z "$var_value" ]; then
            var_value="${env_prefix}${var_name}"
            var_value="${!var_value:-}"
        fi
        url="${url/\{\{${var_name}\}\}/$var_value}"
    done

    echo "$url"
}

# Get the resolved download URL for a package
# Usage: manifest_get_download_url <package-name> [category ...]
manifest_get_download_url() {
    local pkg_name="$1"
    local categories="${2:-}"

    local raw_url
    raw_url=$(manifest_get_field "$pkg_name" "url" $categories)
    if [ -z "$raw_url" ]; then
        return 1
    fi

    _manifest_resolve_url "$raw_url"
}

# Get the source filename for a package
# Usage: manifest_get_filename <package-name> [category ...]
manifest_get_filename() {
    local url
    url=$(manifest_get_download_url "$1" "${2:-}")
    if [ -n "$url" ]; then
        echo "${url##*/}"
    fi
}

# ---------------------------------------------------------------------------
# Checksum verification
# ---------------------------------------------------------------------------

# Verify checksum for a downloaded source file
# Usage: manifest_verify_checksum <filename> <package-name> [category ...]
manifest_verify_checksum() {
    local filepath="$1"
    local pkg_name="${2:-}"

    if [ ! -f "$filepath" ]; then
        warn "File not found: $filepath"
        return 1
    fi

    local checksum_value
    checksum_value=$(manifest_get_field "$pkg_name" "checksum_value" "${3:-}")

    if [ -z "$checksum_value" ]; then
        log "No checksum configured for $(basename "$filepath"), skipping verification"
        return 0
    fi

    local checksum_type
    checksum_type=$(manifest_get_field "$pkg_name" "checksum_type" "${3:-}")
    checksum_type="${checksum_type:-sha256}"

    log "Verifying checksum for $(basename "$filepath") ($checksum_type)"

    local actual_hash
    case "$checksum_type" in
        sha256)
            actual_hash=$(sha256sum "$filepath" | awk '{print $1}')
            ;;
        sha512)
            actual_hash=$(sha512sum "$filepath" | awk '{print $1}')
            ;;
        md5)
            actual_hash=$(md5sum "$filepath" | awk '{print $1}')
            ;;
        *)
            warn "Unknown checksum type: $checksum_type"
            return 1
            ;;
    esac

    if [ "$actual_hash" = "$checksum_value" ]; then
        log "Checksum OK for $(basename "$filepath")"
        return 0
    else
        warn "Checksum MISMATCH for $(basename "$filepath")!"
        warn "  Expected: $checksum_value"
        warn "  Actual:   $actual_hash"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Legacy packages.txt support
# ---------------------------------------------------------------------------

# Check if legacy packages.txt should be used
# Returns 0 if legacy files exist and YAML manifests are empty
manifest_should_use_legacy() {
    local categories="${1:-base system kernel development live}"
    local has_yaml=0

    for cat in $categories; do
        for ext in yaml yml; do
            if [ -f "${MANIFEST_DIR}/${cat}.${ext}" ]; then
                has_yaml=1
                break 2
            fi
        done
    done

    if [ "$has_yaml" = "0" ] && [ -f "$LEGACY_PACKAGES_TXT" ]; then
        return 0
    fi
    return 1
}

# Get URLs from legacy packages.txt
# Usage: manifest_legacy_urls
manifest_legacy_urls() {
    if [ -f "$LEGACY_PACKAGES_TXT" ]; then
        grep -vE '^\s*$' "$LEGACY_PACKAGES_TXT"
    fi
}

# Get URLs from legacy base-packages.txt
# Usage: manifest_base_legacy_urls
manifest_base_legacy_urls() {
    if [ -f "$LEGACY_BASE_PACKAGES_TXT" ]; then
        grep -vE '^\s*$' "$LEGACY_BASE_PACKAGES_TXT"
    fi
}

# ---------------------------------------------------------------------------
# Patch management
# ---------------------------------------------------------------------------

# List patches for a specific package
# Usage: manifest_list_patches <package-name> [category ...]
manifest_list_patches() {
    local pkg_name="$1"
    local categories="${2:-}"

    if _manifest_parser_available; then
        local json
        json=$(_manifest_parse_with_python "$pkg_name" $categories 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$json" ]; then
            # Extract patches array from JSON
            echo "$json" | sed -n '/"patches"/,/]/p' | grep 'url' | sed 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
        fi
    else
        _manifest_list_patches_bash "$pkg_name" $categories
    fi
}

# Pure bash patch listing
_manifest_list_patches_bash() {
    local pkg_name="$1"
    local categories="${2:-}"
    local manifest_files=()

    if [ -n "$categories" ]; then
        for cat in $categories; do
            for ext in yaml yml; do
                [ -f "${MANIFEST_DIR}/${cat}.${ext}" ] && manifest_files+=("${MANIFEST_DIR}/${cat}.${ext}")
            done
        done
    else
        for f in "${MANIFEST_DIR}"/*.yaml "${MANIFEST_DIR}"/*.yml; do
            [ -f "$f" ] && manifest_files+=("$f")
        done
    fi

    for mfile in "${manifest_files[@]}"; do
        # Check package-level patches
        local pkg_block
        pkg_block=$(_manifest_find_package_bash "$mfile" "$pkg_name")
        if [ -n "$pkg_block" ]; then
            echo "$pkg_block" | grep -A1 '^\s*- name:' | grep 'url:' | sed 's/.*url:[[:space:]]*//' | sed 's/[[:space:]]*//g'
        fi

        # Check global patches from patches.yaml
        if [ -f "$MANIFEST_DIR/patches.yaml" ]; then
            local in_target=0
            while IFS= read -r line; do
                if [[ "$line" =~ ^[[:space:]]*package:[[:space:]]*${pkg_name} ]]; then
                    in_target=1
                    continue
                fi
                if [ "$in_target" = "1" ]; then
                    if [[ "$line" =~ ^[[:space:]]*url: ]]; then
                        echo "$line" | sed 's/.*url:[[:space:]]*//' | sed 's/[[:space:]]*//g'
                    elif [[ "$line" =~ ^[[:space:]]*- ]] || [[ "$line" =~ ^[[:space:]]*[a-z]+: ]]; then
                        break
                    fi
                fi
            done < "$MANIFEST_DIR/patches.yaml"
        fi
    done
}

# Get patch URL and strip value for applying patches
# Usage: manifest_get_patch_info <package-name> [index]
# Returns: url strip
manifest_get_patch_info() {
    local pkg_name="$1"
    local index="${2:-0}"
    local patches=()

    while IFS= read -r patch_url; do
        [ -n "$patch_url" ] && patches+=("$patch_url")
    done < <(manifest_list_patches "$pkg_name")

    if [ "$index" -lt "${#patches[@]}" ]; then
        echo "${patches[$index]}"
    fi
}

# ---------------------------------------------------------------------------
# Build system detection
# ---------------------------------------------------------------------------

# Get the build system for a package
# Usage: manifest_get_build_system <package-name> [category ...]
manifest_get_build_system() {
    manifest_get_field "$1" "build_system" "${2:-}"
}

# Get configure arguments for a package
# Usage: manifest_get_configure_args <package-name> [category ...]
manifest_get_configure_args() {
    local pkg_name="$1"
    local categories="${2:-}"
    local json
    json=$(_manifest_parse_with_python "$pkg_name" $categories 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$json" ]; then
        echo "$json" | sed -n '/"configure"/,/]/p' | grep '"' | sed 's/.*"\([^"]*\)".*/\1/' | grep -v '^configure'
    fi
}

# ---------------------------------------------------------------------------
# Dependency resolution (basic)
# ---------------------------------------------------------------------------

# List dependencies for a package
# Usage: manifest_list_dependencies <package-name> [category ...]
manifest_list_dependencies() {
    local pkg_name="$1"
    local categories="${2:-}"
    local json
    json=$(_manifest_parse_with_python "$pkg_name" $categories 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$json" ]; then
        echo "$json" | sed -n '/"dependencies"/,/]/p' | grep '"' | grep -v 'dependencies' | sed 's/.*"\([^"]*\)".*/\1/'
    fi
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# Validate all manifest files
# Usage: manifest_validate [categories ...]
manifest_validate() {
    local categories="$*"
    local errors=0

    if _manifest_parser_available; then
        local result
        result=$(_manifest_parse_with_python --validate ${MANIFEST_DIR}/*.yaml ${MANIFEST_DIR}/*.yml 2>&1)
        local rc=$?
        echo "$result"
        return $rc
    else
        for mfile in "${MANIFEST_DIR}"/*.yaml "${MANIFEST_DIR}"/*.yml; do
            [ -f "$mfile" ] || continue
            if ! _manifest_validate_single_bash "$mfile"; then
                errors=$((errors + 1))
            fi
        done
        return $errors
    fi
}

# Validate a single manifest file (pure bash)
_manifest_validate_single_bash() {
    local file="$1"
    local errors=0

    local names
    names=$(_manifest_extract_names_bash "$file")

    if [ -z "$names" ]; then
        log "No packages found in $file (empty or no packages section)"
        return 0
    fi

    for name in $names; do
        local version
        version=$(manifest_get_field "$name" "version")
        if [ -z "$version" ]; then
            warn "Missing version for $name in $file"
            errors=$((errors + 1))
        fi

        local url
        url=$(manifest_get_field "$name" "url")
        if [ -z "$url" ]; then
            warn "Missing URL for $name in $file"
            errors=$((errors + 1))
        fi
    done

    if [ "$errors" -gt 0 ]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Migration helpers
# ---------------------------------------------------------------------------

# Generate a YAML manifest from legacy packages.txt
# Usage: manifest_migrate_legacy <output-file> [packages.txt-path]
manifest_migrate_legacy() {
    local output="$1"
    local legacy_file="${2:-$LEGACY_PACKAGES_TXT}"

    if [ ! -f "$legacy_file" ]; then
        die "Legacy file not found: $legacy_file"
    fi

    cat > "$output" << 'HEADER'
# Auto-generated from packages.txt
# Do not edit manually - regenerate with manifest-migrate-legacy
packages:
HEADER

    while IFS= read -r url; do
        [ -z "$url" ] && continue
        local fn="${url##*/}"
        local name="${fn%%-*}"
        local version="${fn#$name-}"
        version="${version%%.*}"
        version="${version%%-*}"

        cat >> "$output" << EOF
  - name: ${name}
    version: "${version}"
    category: legacy
    source:
      url: ${url}
      checksum:
        type: sha256
        value: ""
    build:
      system: custom
    dependencies: []
EOF
    done < "$legacy_file"

    log "Migrated packages to $output"
}