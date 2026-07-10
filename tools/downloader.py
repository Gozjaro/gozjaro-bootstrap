#!/usr/bin/env python3
"""
Gozjaro Bootstrap Source Downloader

Downloads package source archives and verifies checksums.

Features:
- Resume interrupted downloads
- Avoid re-downloading existing files
- Verify SHA256/SHA512 checksums after download
- Support for manifest-based package definitions

Usage:
    python3 tools/downloader.py <package-name> [categories...]
    python3 tools/downloader.py --download-all [categories...]
    python3 tools/downloader.py --check-only <package-name> [categories...]

Examples:
    # Download bash from default categories
    python3 tools/downloader.py bash

    # Download all packages in base category
    python3 tools/downloader.py --download-all base

    # Check if sources exist without downloading
    python3 tools/downloader.py --check-only bash base system
"""

import argparse
import hashlib
import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path


# Default download directory
DEFAULT_DOWNLOAD_DIR = "sources"

# HTTP headers for requests
USER_AGENT = "Gozjaro-Bootstrap/1.0"

# Chunk size for downloads (1MB)
DOWNLOAD_CHUNK_SIZE = 1024 * 1024

# Timeout for HTTP requests (seconds)
HTTP_TIMEOUT = 300


def load_yaml_simple(filepath):
    """Minimal YAML loader - delegates to manifest-parser."""
    try:
        import yaml
        with open(filepath, 'r') as f:
            return yaml.safe_load(f)
    except ImportError:
        pass

    with open(filepath, 'r') as f:
        content = f.read()

    # Simple parser for our YAML subset
    packages = []
    current_pkg = {}
    in_packages = False
    current_indent = 0

    for line in content.split('\n'):
        if line.startswith('packages:'):
            in_packages = True
            continue
        if not in_packages:
            continue
        if line.startswith('  - name:'):
            if current_pkg:
                packages.append(current_pkg)
            current_pkg = {'name': line.split(':', 1)[1].strip().strip('"').strip("'")}
            continue
        if current_pkg and ': ' in line:
            parts = line.split(': ', 1)
            key = parts[0].strip()
            value = parts[1].strip().strip('"').strip("'")
            if key == 'version':
                current_pkg['version'] = value
            elif key == 'category':
                current_pkg['category'] = value
            elif key == 'url':
                current_pkg['url'] = value

    if current_pkg:
        packages.append(current_pkg)

    return {'packages': packages}


def get_package_info(package_name, categories=None, manifest_dir="config/packages", env_vars=None):
    """Get package info from manifests, resolving URL templates."""
    if env_vars is None:
        env_vars = {}

    manifest_files = []
    if categories:
        for cat in categories:
            for ext in ('.yaml', '.yml'):
                fpath = os.path.join(manifest_dir, cat + ext)
                if os.path.exists(fpath):
                    manifest_files.append(fpath)
    else:
        dir_path = Path(manifest_dir)
        if dir_path.exists():
            for f in sorted(dir_path.glob("*.yaml")):
                manifest_files.append(str(f))
            for f in sorted(dir_path.glob("*.yml")):
                manifest_files.append(str(f))

    all_patches = []
    for mfile in manifest_files:
        data = load_yaml_simple(mfile)
        if data is None:
            continue
        pkg_list = data.get('packages', [])
        if isinstance(pkg_list, list):
            for pkg in pkg_list:
                if pkg.get('name') == package_name:
                    # Resolve URL templates
                    source = pkg.get('source', {})
                    if isinstance(source, dict) and 'url' in source:
                        url = source['url']
                        import re
                        matches = re.findall(r'\{\{(\w+)\}\}', url)
                        for var in matches:
                            val = env_vars.get(var, '')
                            if val:
                                url = url.replace('{{' + var + '}}', val)
                        source['url'] = url
                    pkg['source'] = source
                    return pkg

        patch_list = data.get('patches', [])
        if isinstance(patch_list, list):
            all_patches.extend(patch_list)

    return None


def get_filename_from_url(url):
    """Extract filename from URL."""
    import re
    # Remove query parameters
    url_clean = url.split('?')[0]
    # Get last path component
    filename = os.path.basename(url_clean)
    if not filename:
        filename = "download"
    return filename


def calculate_checksum(filepath, algorithm='sha256'):
    """Calculate checksum of a file."""
    hash_func = hashlib.new(algorithm)
    with open(filepath, 'rb') as f:
        while True:
            chunk = f.read(DOWNLOAD_CHUNK_SIZE)
            if not chunk:
                break
            hash_func.update(chunk)
    return hash_func.hexdigest()


def download_file(url, dest_path, resume=False):
    """
    Download a file from URL to dest_path.
    Supports resuming interrupted downloads.
    Returns True on success, False on failure.
    """
    dest_path = Path(dest_path)
    dest_path.parent.mkdir(parents=True, exist_ok=True)

    # Check if file already exists
    if dest_path.exists() and not resume:
        print(f"  Already exists: {dest_path.name}")
        return True

    # Get file size for resume support
    start_pos = 0
    if resume and dest_path.exists():
        start_pos = dest_path.stat().st_size
        print(f"  Resuming from byte {start_pos}")

    # Prepare request
    req = urllib.request.Request(url)
    req.add_header('User-Agent', USER_AGENT)
    if start_pos > 0:
        req.add_header('Range', f'bytes={start_pos}-')

    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as response:
            total_size = int(response.headers.get('Content-Length', 0))
            if start_pos > 0:
                total_size += start_pos

            mode = 'ab' if start_pos > 0 else 'wb'
            with open(dest_path, mode) as f:
                while True:
                    chunk = response.read(DOWNLOAD_CHUNK_SIZE)
                    if not chunk:
                        break
                    f.write(chunk)

                    # Progress indicator
                    if total_size > 0:
                        percent = ((start_pos + f.tell() if mode == 'ab' else f.tell()) / total_size) * 100
                        print(f"\r  Progress: {percent:.1f}%", end='', flush=True)

        print()  # Newline after progress
        return True

    except urllib.error.HTTPError as e:
        print(f"\n  HTTP Error {e.code}: {e.reason}", file=sys.stderr)
        if start_pos > 0 and e.code == 416:
            # Range not satisfiable - file may be complete
            print("  Range not satisfiable, checking existing file...")
            return dest_path.exists()
        return False

    except urllib.error.URLError as e:
        print(f"\n  URL Error: {e.reason}", file=sys.stderr)
        return False

    except Exception as e:
        print(f"\n  Download error: {e}", file=sys.stderr)
        return False


def verify_checksum(filepath, expected_hash, algorithm='sha256'):
    """Verify the checksum of a downloaded file."""
    if not expected_hash or expected_hash.strip() == '':
        print("  Checksum value not set, skipping verification")
        return True

    actual_hash = calculate_checksum(filepath, algorithm)
    if actual_hash.lower() == expected_hash.lower():
        print(f"  Checksum OK ({algorithm}: {actual_hash[:16]}...)")
        return True
    else:
        print(f"  Checksum MISMATCH!", file=sys.stderr)
        print(f"    Expected: {expected_hash}", file=sys.stderr)
        print(f"    Actual:   {actual_hash}", file=sys.stderr)
        return False


def process_package(package_name, categories=None, download_dir=None, env_vars=None, check_only=False):
    """Process a single package: find source, download, verify."""
    if download_dir is None:
        download_dir = DEFAULT_DOWNLOAD_DIR

    if env_vars is None:
        env_vars = {}

    # Get package info
    pkg = get_package_info(package_name, categories, env_vars=env_vars)
    if not pkg:
        print(f"Error: Package '{package_name}' not found in manifests", file=sys.stderr)
        return False

    source = pkg.get('source', {})
    if isinstance(source, str):
        url = source
    elif isinstance(source, dict):
        url = source.get('url', '')
    else:
        url = ''

    if not url:
        print(f"Error: No source URL for package '{package_name}'", file=sys.stderr)
        return False

    # Get checksum info
    checksum_info = {}
    if isinstance(source, dict):
        cs = source.get('checksum', {})
        if isinstance(cs, dict):
            checksum_info = cs
        else:
            checksum_info = {}

    checksum_type = checksum_info.get('type', 'sha256')
    checksum_value = checksum_info.get('value', '')

    # Determine filename
    filename = get_filename_from_url(url)
    dest_path = os.path.join(download_dir, filename)

    # Print status
    version = pkg.get('version', '')
    version_str = f"-{version}" if version else ""
    print(f"Downloading {package_name}{version_str}: {filename}")

    if check_only:
        # Just check if URL is accessible
        try:
            req = urllib.request.Request(url)
            req.add_header('User-Agent', USER_AGENT)
            with urllib.request.urlopen(req, timeout=10) as response:
                status = response.status
                print(f"[OK] {package_name}{version_str} (HTTP {status})")
                return True
        except urllib.error.HTTPError as e:
            print(f"[FAIL] {package_name}{version_str} (HTTP {e.code})")
            return False
        except urllib.error.URLError as e:
            print(f"[FAIL] {package_name}{version_str} ({e.reason})")
            return False

    # Download if file doesn't exist
    if not os.path.exists(dest_path):
        if not download_file(url, dest_path, resume=True):
            print(f"Error: Failed to download {filename}", file=sys.stderr)
            return False
    else:
        print(f"  Using existing: {filename}")

    # Verify checksum
    if checksum_value:
        if not verify_checksum(dest_path, checksum_value, checksum_type):
            return False
    else:
        print("  Checksum not configured, skipping verification")

    print(f"OK: {package_name}{version_str}")
    return True


def main():
    parser = argparse.ArgumentParser(
        description='Gozjaro Bootstrap Source Downloader',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    parser.add_argument('package', nargs='?', help='Package name to download')
    parser.add_argument('--download-all', action='store_true',
                        help='Download all packages in specified categories')
    parser.add_argument('--check-only', action='store_true',
                        help='Only check if sources are available')
    parser.add_argument('--categories', '-c', nargs='*',
                        help='Categories to process (e.g., base system kernel)')
    parser.add_argument('--download-dir', '-d', default=DEFAULT_DOWNLOAD_DIR,
                        help=f'Download directory (default: {DEFAULT_DOWNLOAD_DIR})')
    parser.add_argument('--manifest-dir', default="config/packages",
                        help='Manifest directory')
    parser.add_argument('--env', nargs='*', default=[],
                        help='Environment variable overrides (e.g., GOZJARO_KERNEL_VERSION=6.12)')
    parser.add_argument('--no-resume', action='store_true',
                        help='Do not resume interrupted downloads')

    args = parser.parse_args()

    # Load environment overrides
    env_vars = {}
    for item in args.env:
        if '=' in item:
            k, v = item.split('=', 1)
            env_vars[k.strip()] = v.strip()

    categories = args.categories
    if not categories:
        categories = ['base', 'system', 'kernel', 'development', 'live']

    download_dir = args.download_dir
    os.makedirs(download_dir, exist_ok=True)

    if args.package:
        # Single package mode
        success = process_package(
            args.package,
            categories=categories,
            download_dir=download_dir,
            env_vars=env_vars,
            check_only=args.check_only
        )
        sys.exit(0 if success else 1)

    elif args.download_all or args.check_only:
        # Download/check all packages
        # First, collect all package names
        all_packages = []
        for cat in categories:
            for ext in ('.yaml', '.yml'):
                fpath = os.path.join(args.manifest_dir, cat + ext)
                if os.path.exists(fpath):
                    data = load_yaml_simple(fpath)
                    if data:
                        for pkg in data.get('packages', []):
                            name = pkg.get('name', '')
                            if name and name not in all_packages:
                                all_packages.append(name)

        if not all_packages:
            print("No packages found in specified categories.")
            sys.exit(1)

        print(f"Processing {len(all_packages)} packages...")
        print()

        success_count = 0
        fail_count = 0

        for pkg_name in sorted(all_packages):
            if process_package(pkg_name, categories=categories,
                             download_dir=download_dir, env_vars=env_vars,
                             check_only=args.check_only):
                success_count += 1
            else:
                fail_count += 1

        print()
        print(f"Results: {success_count} succeeded, {fail_count} failed")
        sys.exit(0 if fail_count == 0 else 1)

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == '__main__':
    main()