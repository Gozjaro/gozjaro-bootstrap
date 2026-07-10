#!/usr/bin/env python3
"""
Gozjaro Bootstrap Source Availability Checker

Checks HTTP status of all source URLs in package manifests.
Detects broken URLs and reports unavailable sources.

Usage:
    python3 tools/source-check.py [categories...]
    python3 tools/source-check.py --package <name> [categories...]
    python3 tools/source-check.py --json [categories...]

Examples:
    # Check all packages in default categories
    python3 tools/source-check.py

    # Check only base category
    python3 tools/source-check.py base

    # Check specific package
    python3 tools/source-check.py --package gcc

    # Output as JSON for CI integration
    python3 tools/source-check.py --json
"""

import argparse
import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path


# Default categories to check
DEFAULT_CATEGORIES = ['base', 'system', 'kernel', 'development', 'live']

# HTTP timeout for checks (seconds)
_CHECK_TIMEOUT_DEFAULT = 30

# User agent for requests
USER_AGENT = "Gozjaro-Bootstrap/1.0"


def load_yaml_simple(filepath):
    """Minimal YAML loader for manifest files."""
    try:
        import yaml
        with open(filepath, 'r') as f:
            return yaml.safe_load(f)
    except ImportError:
        pass

    with open(filepath, 'r') as f:
        content = f.read()

    packages = []
    current_pkg = {}
    in_packages = False
    in_source = False
    in_checksum = False

    for line in content.split('\n'):
        if line.startswith('packages:'):
            in_packages = True
            in_source = in_checksum = False
            continue

        if not in_packages:
            continue

        # Track indentation level for nested structures
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue

        indent = len(line) - len(line.lstrip())

        if line.startswith('  - name:'):
            if current_pkg:
                packages.append(current_pkg)
            current_pkg = {'name': line.split(':', 1)[1].strip().strip('"').strip("'")}
            in_source = in_checksum = False
            continue

        if current_pkg is None:
            continue

        if stripped.startswith('- ') and indent >= 6:
            # List item under a key (like patches)
            if ':' in stripped[2:]:
                key = stripped[2:].split(':')[0].strip()
                if key == 'name':
                    current_pkg.setdefault('patches', []).append({
                        'name': stripped[5:].strip().strip('"').strip("'")
                    })
            continue

        if ':' in stripped and indent >= 4:
            key, _, value = stripped.partition(':')
            key = key.strip()
            value = value.strip().strip('"').strip("'")

            if key == 'url' and indent == 6:
                current_pkg.setdefault('source', {})['url'] = value
                in_source = True
                in_checksum = False
            elif key == 'checksum' and indent == 6:
                current_pkg.setdefault('source', {})['checksum'] = {}
                in_source = False
                in_checksum = True
            elif key == 'type' and (indent == 8 or in_checksum):
                current_pkg.setdefault('source', {}).setdefault('checksum', {})['type'] = value
            elif key == 'value' and (indent == 8 or in_checksum):
                current_pkg.setdefault('source', {}).setdefault('checksum', {})['value'] = value
            elif key == 'name' and not in_source and not in_checksum and indent == 6:
                # Could be patches section at package level
                pass

    if current_pkg:
        packages.append(current_pkg)

    return {'packages': packages}


def find_manifests(manifest_dir="config/packages"):
    """Find all YAML manifest files."""
    manifests = []
    dir_path = Path(manifest_dir)
    if dir_path.exists():
        for f in sorted(dir_path.glob("*.yaml")):
            manifests.append(str(f))
        for f in sorted(dir_path.glob("*.yml")):
            manifests.append(str(f))
    return manifests


def load_all_packages(categories=None, manifest_dir="config/packages"):
    """Load all packages from specified categories."""
    if categories is None:
        categories = DEFAULT_CATEGORIES

    manifest_files = []
    for cat in categories:
        for ext in ('.yaml', '.yml'):
            fpath = os.path.join(manifest_dir, cat + ext)
            if os.path.exists(fpath):
                manifest_files.append(fpath)

    if not manifest_files:
        manifest_files = find_manifests(manifest_dir)

    all_packages = {}

    for mfile in manifest_files:
        data = load_yaml_simple(mfile)
        if data is None:
            continue

        pkg_list = data.get('packages', [])
        if isinstance(pkg_list, list):
            for pkg in pkg_list:
                name = pkg.get('name', '')
                if name:
                    all_packages[name] = pkg

    return all_packages


def check_url(url, timeout=_CHECK_TIMEOUT_DEFAULT):
    """
    Check if a URL is accessible.
    Returns: (status_code, error_message)
    """
    try:
        req = urllib.request.Request(url)
        req.add_header('User-Agent', USER_AGENT)

        # Use HEAD request first, fall back to GET
        try:
            opener = urllib.request.build_opener()
            opener.addheaders = [('User-Agent', USER_AGENT)]
            with opener.open(url, timeout=timeout) as response:
                return response.status, None
        except urllib.error.HTTPError as e:
            # Some servers don't support HEAD
            if e.code in (405, 501):
                # Try GET instead
                try:
                    with urllib.request.urlopen(url, timeout=timeout) as response:
                        return response.status, None
                except urllib.error.HTTPError as e2:
                    return e2.code, f"HTTP {e2.code}"
            return e.code, f"HTTP {e.code}"
        except urllib.error.URLError as e:
            return 0, str(e.reason)
        except TimeoutError:
            return 0, "Timeout"
        except Exception as e:
            return 0, str(e)

    except Exception as e:
        return 0, str(e)


def get_source_url(pkg):
    """Extract source URL from a package definition."""
    source = pkg.get('source', {})
    if isinstance(source, str):
        return source
    elif isinstance(source, dict):
        return source.get('url', '')
    return ''


def check_package(pkg_name, pkg, timeout=None):
    """Check a single package's source URL."""
    url = get_source_url(pkg)

    if timeout is None:
        timeout = _CHECK_TIMEOUT_DEFAULT

    if not url:
        return {
            'name': pkg_name,
            'status': 'SKIP',
            'message': 'No source URL defined'
        }

    status_code, error = check_url(url, timeout=timeout)

    if status_code and 200 <= status_code < 400:
        return {
            'name': pkg_name,
            'version': pkg.get('version', ''),
            'status': 'OK',
            'http_status': status_code,
            'url': url
        }
    elif status_code == 0:
        return {
            'name': pkg_name,
            'version': pkg.get('version', ''),
            'status': 'FAIL',
            'error': error,
            'url': url
        }
    else:
        return {
            'name': pkg_name,
            'version': pkg.get('version', ''),
            'status': 'ERROR',
            'http_status': status_code,
            'url': url
        }


def main():
    parser = argparse.ArgumentParser(
        description='Gozjaro Bootstrap Source Availability Checker',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    parser.add_argument('--package', '-p', help='Check only specific package')
    parser.add_argument('--json', action='store_true', dest='output_json',
                        help='Output results as JSON')
    parser.add_argument('--categories', '-c', nargs='*',
                        help='Categories to check (default: all)')
    parser.add_argument('--manifest-dir', default="config/packages",
                        help='Manifest directory')
    parser.add_argument('--timeout', '-t', type=int, default=_CHECK_TIMEOUT_DEFAULT,
                        help=f'HTTP timeout in seconds (default: {_CHECK_TIMEOUT_DEFAULT})')
    parser.add_argument('--quiet', '-q', action='store_true',
                        help='Only show failed checks')

    args = parser.parse_args()

    # Load packages
    categories = args.categories
    if not categories:
        categories = DEFAULT_CATEGORIES

    all_packages = load_all_packages(categories, args.manifest_dir)

    if not all_packages:
        print("No packages found in specified categories.")
        sys.exit(0)

    # Filter if specific package requested
    if args.package:
        if args.package in all_packages:
            all_packages = {args.package: all_packages[args.package]}
        else:
            print(f"Package '{args.package}' not found.")
            print(f"Available packages: {', '.join(sorted(load_all_packages(categories, args.manifest_dir).keys()))}")
            sys.exit(1)

    # Check all packages
    results = []
    ok_count = 0
    fail_count = 0
    skip_count = 0

    # Store timeout in module scope for check_package to access
    import __main__
    __main__.CHECK_TIMEOUT = args.timeout

    for pkg_name in sorted(all_packages.keys()):
        pkg = all_packages[pkg_name]
        result = check_package(pkg_name, pkg, timeout=__main__.CHECK_TIMEOUT)
        results.append(result)

        if result['status'] == 'OK':
            ok_count += 1
        elif result['status'] == 'SKIP':
            skip_count += 1
        else:
            fail_count += 1

    # Output results
    if args.output_json:
        output = {
            'total': len(results),
            'ok': ok_count,
            'fail': fail_count,
            'skip': skip_count,
            'results': results
        }
        print(json.dumps(output, indent=2))
    else:
        # Text output
        if not args.quiet:
            print(f"Checking {len(results)} packages...")
            print("-" * 60)

        for result in results:
            if args.quiet and result['status'] == 'OK':
                continue

            if result['status'] == 'OK':
                print(f"[OK] {result['name']}-{result.get('version', '')} (HTTP {result.get('http_status', '')})")
            elif result['status'] == 'SKIP':
                print(f"[SKIP] {result['name']}: {result.get('message', '')}")
            elif result['status'] == 'ERROR':
                print(f"[ERROR] {result['name']}-{result.get('version', '')}: HTTP {result.get('http_status', '')}")
            else:
                print(f"[FAIL] {result['name']}-{result.get('version', '')}: {result.get('error', 'Unknown error')}")

        if not args.quiet:
            print("-" * 60)
            print(f"Results: {ok_count} OK, {fail_count} FAIL, {skip_count} SKIP")

    # Exit code: non-zero if any failures
    sys.exit(1 if fail_count > 0 else 0)


if __name__ == '__main__':
    main()