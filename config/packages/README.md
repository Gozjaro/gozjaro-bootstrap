# Gozjaro Bootstrap Package Manifests

This directory contains YAML package manifests for the Gozjaro Live ISO build system.

## Structure

Each `.yaml` or `.yml` file defines packages for a specific category:

| File | Purpose |
|------|---------|
| `base.yaml` | Core base system packages (bash, coreutils, etc.) |
| `system.yaml` | System infrastructure packages (glibc, binutils, gcc) |
| `kernel.yaml` | Linux kernel and related packages |
| `development.yaml` | Development tools (make, autoconf, etc.) |
| `live.yaml` | Live session packages (kernel, initramfs, bootloader) |
| `patches.yaml` | LFS patches for various packages |

## Format

```yaml
packages:
  - name: bash
    version: "5.2.37"
    category: base
    source:
      url: https://mirrors.kernel.org/gnu/bash/bash-5.2.37.tar.gz
      checksum:
        type: sha256
        value: ""
    build:
      system: autotools
      configure:
        - --prefix=/usr
    dependencies:
      - ncurses
```

## URL Template Variables

Some URLs use template variables that are resolved at runtime:

- `{{ GOZJARO_KERNEL_VERSION }}` - Resolved from `GOZJARO_KERNEL_VERSION` environment variable or `config/lfs.env`

Example:
```yaml
source:
  url: https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-{{ GOZJARO_KERNEL_VERSION }}.tar.xz
```

## Tools

### manifest-parser.py

Parse YAML manifests and export package metadata.

```bash
# Get JSON for a specific package
python3 ../tools/manifest-parser.py gcc

# List all packages in a category
python3 ../tools/manifest-parser.py --list base system

# Validate all manifests
python3 ../tools/manifest-parser.py --validate
```

### downloader.py

Download package sources with checksum verification.

```bash
# Download a specific package
python3 ../tools/downloader.py gcc

# Batch download multiple categories
python3 ../tools/downloader.py --categories base system kernel

# Verify only (skip download if exists)
python3 ../tools/downloader.py --verify-only bash
```

### source-check.py

Check if source URLs are accessible.

```bash
# Check all packages
python3 ../tools/source-check.py

# Check specific category
python3 ../tools/source-check.py base

# JSON output for CI
python3 ../tools/source-check.py --json
```

### checksum.py

Compute and verify checksums.

```bash
# Compute hash of a file
python3 ../tools/checksum.py compute linux-6.7.tar.xz

# Verify against known hash
python3 ../tools/checksum.py verify linux-6.7.tar.xz abc123... sha256

# Verify using manifest checksum
python3 ../tools/checksum.py verify-package bash

# Batch verify all downloaded sources
python3 ../tools/checksum.py batch-verify
```

## Migration from Legacy Format

The legacy `config/packages.txt` and `config/base-packages.txt` files are still supported.

To migrate to YAML manifests:

```bash
python3 ../tools/manifest-parser.py --migrate config/packages/migrated.yaml
```

## Adding a New Package

1. Determine the correct category for your package
2. Edit the corresponding YAML file
3. Add a new package entry with required fields:

```yaml
packages:
  # ... existing packages ...
  - name: mypackage
    version: "1.0.0"
    category: base
    source:
      url: https://example.com/mypackage-1.0.0.tar.gz
      checksum:
        type: sha256
        value: ""  # Fill after download
    build:
      system: custom
    dependencies: []
```

4. Run `downloader.py` to download and get the actual checksum:
   ```bash
   python3 ../tools/downloader.py mypackage
   ```
5. Update the `checksum.value` field with the computed hash

## Future Compatibility

This manifest format is designed to be compatible with the future `gozpak` binary package manager. Fields like `architecture`, `license`, `maintainer`, `repository`, `binary`, `provides`, and `conflicts` are reserved for future use.