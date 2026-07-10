#!/usr/bin/env python3
"""
Gozjaro Bootstrap Checksum Utility

Compute and verify checksums for package source files.
Integrates with the manifest system for automated verification.

Usage:
    python3 tools/checksum.py compute <filename> [algorithm]
    python3 tools/checksum.py verify <filename> <expected-hash> [algorithm]
    python3 tools/checksum.py verify-package <package-name> [categories...]
    python3 tools/checksum.py batch-verify [categories...]

Examples:
    # Compute SHA256 of a file
    python3 tools/checksum.py compute bash-5.2.37.tar.gz

    # Verify against known hash
    python3 tools/checksum.py verify bash-5.2.37.tar.gz abc123... sha256

    # Verify using manifest checksum
    python3 tools/checksum.py verify-package bash base

    # Batch verify all downloaded sources
    python3 tools/checksum.py batch-verify base system kernel
"""

import argparse
import hashlib
import os
import sys
from pathlib import Path


# Supported algorithms
SUPPORTED_ALGORITHMS = ['md5', 'sha1', 'sha256', 'sha512']

# Default algorithm
DEFAULT_ALGORITHM = 'sha256'

# Chunk size for hashing (1MB)
HASH_CHUNK_SIZE = 1024 * 1024


def calculate_hash(filepath, algorithm=DEFAULT_ALGORITHM):
    """Calculate the hash of a file."""
    if algorithm not in SUPPORTED_ALGORITHMS:
        print(f"Error: Unsupported algorithm '{algorithm}'", file=sys.stderr)
        print(f"Supported: {', '.join(SUPPORTED_ALGORITHMS)}", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(filepath):
        print(f"Error: File not found: {filepath}", file=sys.stderr)
        sys.exit(1)

    hash_func = hashlib.new(algorithm)
    with open(filepath, 'rb') as f:
        while True:
            chunk = f.read(HASH_CHUNK_SIZE)
            if not chunk:
                break
            hash_func.update(chunk)

    return hash_func.hexdigest()


def format_hash_output(hash_value, algorithm, filename):
    """Format hash output in standard format."""
    return f"{hash_value}  {filename}"


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

    if current_pkg:
        packages.append(current_pkg)

    return {'packages': packages}


def find_package_in_manifests(pkg_name, manifest_dir="config/packages", categories=None):
    """Find package definition in manifest files."""
    if categories is None:
        categories = ['base', 'system', 'kernel', 'development', 'live']

    manifest_files = []
    for cat in categories:
        for ext in ('.yaml', '.yml'):
            fpath = os.path.join(manifest_dir, cat + ext)
            if os.path.exists(fpath):
                manifest_files.append(fpath)

    for mfile in manifest_files:
        data = load_yaml_simple(mfile)
        if data is None:
            continue

        for pkg in data.get('packages', []):
            if pkg.get('name') == pkg_name:
                return pkg

    return None


def get_checksum_from_manifest(pkg_name, categories=None):
    """Get checksum info from package manifest."""
    pkg = find_package_in_manifests(pkg_name, categories=categories)
    if not pkg:
        return None, None

    source = pkg.get('source', {})
    if isinstance(source, dict):
        checksum = source.get('checksum', {})
        if isinstance(checksum, dict):
            return checksum.get('type', DEFAULT_ALGORITHM), checksum.get('value', '')

    return None, None


def cmd_compute(args):
    """Handle the 'compute' subcommand."""
    filepath = args.filename
    algorithm = args.algorithm or DEFAULT_ALGORITHM

    if not os.path.exists(filepath):
        print(f"Error: File not found: {filepath}", file=sys.stderr)
        sys.exit(1)

    filename = os.path.basename(filepath)
    hash_value = calculate_hash(filepath, algorithm)

    if args.json:
        import json
        print(json.dumps({
            "file": filename,
            "algorithm": algorithm,
            "hash": hash_value
        }, indent=2))
    else:
        print(format_hash_output(hash_value, algorithm, filename))


def cmd_verify(args):
    """Handle the 'verify' subcommand."""
    filepath = args.filename
    expected = args.expected_hash
    algorithm = args.algorithm or DEFAULT_ALGORITHM

    actual = calculate_hash(filepath, algorithm)

    if actual.lower() == expected.lower():
        print(f"OK: {os.path.basename(filepath)} ({algorithm}: {actual[:16]}...)")
        sys.exit(0)
    else:
        print(f"FAIL: {os.path.basename(filepath)}", file=sys.stderr)
        print(f"  Expected ({algorithm}): {expected}", file=sys.stderr)
        print(f"  Actual ({algorithm}):   {actual}", file=sys.stderr)
        sys.exit(1)


def cmd_verify_package(args):
    """Handle the 'verify-package' subcommand."""
    pkg_name = args.package
    categories = args.categories or ['base', 'system', 'kernel', 'development', 'live']

    algorithm, expected_hash = get_checksum_from_manifest(pkg_name, categories)

    if not expected_hash:
        print(f"No checksum configured for package '{pkg_name}' in manifests", file=sys.stderr)
        sys.exit(1)

    # Find the file in sources directory
    sources_dir = getattr(args, 'sources_dir', 'sources')
    if not os.path.isdir(sources_dir):
        print(f"Sources directory not found: {sources_dir}", file=sys.stderr)
        sys.exit(1)

    # Try to find the file by pattern matching
    found_files = list(Path(sources_dir).glob(f"{pkg_name}-*"))
    if not found_files:
        # Try partial match
        for f in Path(sources_dir).iterdir():
            if f.is_file() and pkg_name.lower() in f.name.lower():
                found_files.append(f)

    if not found_files:
        print(f"No source file found for '{pkg_name}' in {sources_dir}", file=sys.stderr)
        sys.exit(1)

    # Use first matching file
    filepath = str(found_files[0])
    actual = calculate_hash(filepath, algorithm)

    if actual.lower() == expected_hash.lower():
        print(f"[OK] {pkg_name} ({algorithm}: {actual[:16]}...)")
        sys.exit(0)
    else:
        print(f"[FAIL] {pkg_name}", file=sys.stderr)
        print(f"  Expected ({algorithm}): {expected_hash}", file=sys.stderr)
        print(f"  Actual ({algorithm}):   {actual}", file=sys.stderr)
        sys.exit(1)


def cmd_batch_verify(args):
    """Handle the 'batch-verify' subcommand."""
    categories = args.categories or ['base', 'system', 'kernel', 'development', 'live']
    sources_dir = getattr(args, 'sources_dir', 'sources')

    if not os.path.isdir(sources_dir):
        print(f"Sources directory not found: {sources_dir}", file=sys.stderr)
        sys.exit(1)

    # Collect all packages from manifests
    all_packages = {}
    for cat in categories:
        for ext in ('.yaml', '.yml'):
            fpath = os.path.join("config/packages", cat + ext)
            if os.path.exists(fpath):
                data = load_yaml_simple(fpath)
                if data:
                    for pkg in data.get('packages', []):
                        name = pkg.get('name', '')
                        if name:
                            all_packages[name] = pkg

    if not all_packages:
        print("No packages found in specified categories.")
        sys.exit(0)

    ok_count = 0
    fail_count = 0
    skip_count = 0

    for pkg_name in sorted(all_packages.keys()):
        pkg = all_packages[pkg_name]
        algorithm, expected_hash = get_checksum_from_manifest(pkg_name, categories)

        if not expected_hash:
            skip_count += 1
            if not args.quiet:
                print(f"[SKIP] {pkg_name}: No checksum configured")
            continue

        # Find file in sources
        found_files = list(Path(sources_dir).glob(f"{pkg_name}-*"))
        if not found_files:
            for f in Path(sources_dir).iterdir():
                if f.is_file() and pkg_name.lower() in f.name.lower():
                    found_files.append(f)

        if not found_files:
            skip_count += 1
            if not args.quiet:
                print(f"[SKIP] {pkg_name}: Source file not found")
            continue

        filepath = str(found_files[0])
        try:
            actual = calculate_hash(filepath, algorithm)
            if actual.lower() == expected_hash.lower():
                ok_count += 1
                if not args.quiet:
                    print(f"[OK] {pkg_name} ({algorithm}: {actual[:16]}...)")
            else:
                fail_count += 1
                print(f"[FAIL] {pkg_name}", file=sys.stderr)
                print(f"  Expected ({algorithm}): {expected_hash}", file=sys.stderr)
                print(f"  Actual ({algorithm}):   {actual}", file=sys.stderr)
        except Exception as e:
            fail_count += 1
            print(f"[ERROR] {pkg_name}: {e}", file=sys.stderr)

    if not args.quiet:
        print("-" * 60)
        print(f"Results: {ok_count} OK, {fail_count} FAIL, {skip_count} SKIP")

    sys.exit(1 if fail_count > 0 else 0)


def main():
    parser = argparse.ArgumentParser(
        description='Gozjaro Bootstrap Checksum Utility',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    subparsers = parser.add_subparsers(dest='command', help='Available commands')

    # compute subcommand
    compute_parser = subparsers.add_parser('compute', help='Compute file hash')
    compute_parser.add_argument('filename', help='File to hash')
    compute_parser.add_argument('-a', '--algorithm', choices=SUPPORTED_ALGORITHMS,
                                help=f'Hash algorithm (default: {DEFAULT_ALGORITHM})')
    compute_parser.add_argument('--json', action='store_true', help='Output as JSON')

    # verify subcommand
    verify_parser = subparsers.add_parser('verify', help='Verify file hash')
    verify_parser.add_argument('filename', help='File to verify')
    verify_parser.add_argument('expected_hash', help='Expected hash value')
    verify_parser.add_argument('-a', '--algorithm', choices=SUPPORTED_ALGORITHMS,
                               help=f'Hash algorithm (default: {DEFAULT_ALGORITHM})')

    # verify-package subcommand
    verify_pkg_parser = subparsers.add_parser('verify-package', help='Verify package using manifest checksum')
    verify_pkg_parser.add_argument('package', help='Package name')
    verify_pkg_parser.add_argument('-c', '--categories', nargs='*',
                                   help='Categories to search')
    verify_pkg_parser.add_argument('-d', '--sources-dir', default='sources',
                                   help='Sources directory (default: sources)')

    # batch-verify subcommand
    batch_parser = subparsers.add_parser('batch-verify', help='Batch verify all packages')
    batch_parser.add_argument('-c', '--categories', nargs='*',
                              help='Categories to verify')
    batch_parser.add_argument('-d', '--sources-dir', default='sources',
                              help='Sources directory (default: sources)')
    batch_parser.add_argument('-q', '--quiet', action='store_true',
                              help='Only show failures')

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(1)

    # Dispatch to subcommand handlers
    commands = {
        'compute': cmd_compute,
        'verify': cmd_verify,
        'verify-package': cmd_verify_package,
        'batch-verify': cmd_batch_verify,
    }

    commands[args.command](args)


if __name__ == '__main__':
    main()