#!/usr/bin/env python3
"""
Gozjaro Bootstrap Manifest Parser

Reads YAML package definitions, validates required fields,
and exports package metadata in JSON format for shell scripts.

Usage:
    python3 tools/manifest-parser.py <package-name> [categories...]
    python3 tools/manifest-parser.py --list [categories...]
    python3 tools/manifest-parser.py --validate [files...]
    python3 tools/manifest-parser.py --fields <package-name> field1,field2,...

Examples:
    # Get full JSON for gcc from default categories
    python3 tools/manifest-parser.py gcc

    # Get specific fields
    python3 tools/manifest-parser.py gcc url,version

    # List all packages in base category
    python3 tools/manifest-parser.py --list base

    # Validate manifest files
    python3 tools/manifest-parser.py --validate config/packages/base.yaml
"""

import argparse
import json
import os
import sys
from pathlib import Path


def load_yaml_simple(filepath):
    """
    Minimal YAML loader that handles the subset of YAML used by Gozjaro manifests.
    Does not require PyYAML dependency.
    """
    try:
        import yaml
        with open(filepath, 'r') as f:
            return yaml.safe_load(f)
    except ImportError:
        pass

    # Fallback: manual parsing for simple YAML structures
    with open(filepath, 'r') as f:
        content = f.read()

    # Try to parse using a simple approach
    try:
        return _parse_yaml_fallback(content)
    except Exception:
        print(f"Error: Cannot parse {filepath} without PyYAML", file=sys.stderr)
        print("Install it with: pip install pyyaml", file=sys.stderr)
        sys.exit(1)


def _parse_yaml_fallback(content):
    """
    Fallback YAML parser for simple structures.
    Handles the Gozjaro manifest format without external dependencies.
    """
    # Use json module with a pre-processed version
    lines = content.split('\n')
    result = {}
    current_list = None
    current_item = None
    current_sub = None
    indent_stack = []

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue

    # For robustness, delegate to a structured approach
    import re

    packages = []
    current_pkg = {}
    in_packages = False
    in_source = False
    in_checksum = in_patches = in_build = in_configure = in_deps = False

    for line in lines:
        if line.startswith('packages:'):
            in_packages = True
            continue

        if not in_packages:
            continue

        if line.startswith('  - name:'):
            if current_pkg:
                packages.append(current_pkg)
            current_pkg = {'name': line.split(':', 1)[1].strip().strip('"').strip("'")}
            in_source = in_checksum = in_patches = in_build = in_configure = in_deps = False
            continue

        if current_pkg is None:
            continue

        indent = len(line) - len(line.lstrip())

        if indent >= 6 and line.strip().startswith('- '):
            # List item under a key
            key_part = line.strip()[2:].split(':')[0]
            if key_part == 'url':
                current_pkg.setdefault('source', {})['url'] = line.strip()[5:].strip().strip('"').strip("'")
            elif key_part == 'name':
                current_pkg.setdefault('patches', []).append({'name': line.strip()[5:].strip().strip('"').strip("'")})
            elif key_part == 'type':
                current_pkg.setdefault('checksum', {})['type'] = line.strip()[5:].strip().strip('"').strip("'")
            elif key_part == 'value':
                current_pkg.setdefault('checksum', {})['value'] = line.strip()[5:].strip().strip('"').strip("'")
            continue

        if ':' in line:
            key, _, value = line.partition(':')
            key = key.strip()
            value = value.strip().strip('"').strip("'")

            if key == 'version':
                current_pkg['version'] = value
            elif key == 'category':
                current_pkg['category'] = value
            elif key == 'url' and indent == 6:
                current_pkg.setdefault('source', {})['url'] = value
            elif key == 'type' and indent == 8:
                current_pkg.setdefault('source', {}).setdefault('checksum', {})['type'] = value
            elif key == 'value' and indent == 8:
                current_pkg.setdefault('source', {}).setdefault('checksum', {})['value'] = value
            elif key == 'system' and indent == 6:
                current_pkg.setdefault('build', {})['system'] = value
            elif key == 'configure' and indent == 4:
                current_pkg.setdefault('build', {})['configure'] = []
                in_configure = True
            elif key == 'dependencies' and indent == 4:
                current_pkg['dependencies'] = []
                in_deps = True
            elif key == 'patches' and indent == 4:
                current_pkg['patches'] = []
                in_patches = True

    if current_pkg:
        packages.append(current_pkg)

    return {'packages': packages}


MANIFEST_DIR = "config/packages"
REQUIRED_FIELDS = ["name", "version", "source"]
SOURCE_REQUIRED = ["url"]


def find_manifests(manifest_dir):
    """Find all YAML manifest files in the directory."""
    manifests = []
    dir_path = Path(manifest_dir)
    if dir_path.exists():
        for f in sorted(dir_path.glob("*.yaml")):
            manifests.append(str(f))
        for f in sorted(dir_path.glob("*.yml")):
            manifests.append(str(f))
    return manifests


def load_all_packages(categories=None, manifest_dir=None):
    """Load all packages from specified categories (YAML files)."""
    if manifest_dir is None:
        manifest_dir = MANIFEST_DIR

    if categories:
        manifest_files = []
        for cat in categories:
            for ext in ('.yaml', '.yml'):
                fpath = os.path.join(manifest_dir, cat + ext)
                if os.path.exists(fpath):
                    manifest_files.append(fpath)
    else:
        manifest_files = find_manifests(manifest_dir)

    all_packages = {}
    all_patches = []

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

        patch_list = data.get('patches', [])
        if isinstance(patch_list, list):
            all_patches.extend(patch_list)

    return all_packages, all_patches


def validate_package(pkg):
    """Validate a single package definition. Returns list of errors."""
    errors = []

    for field in REQUIRED_FIELDS:
        if field not in pkg:
            errors.append(f"Missing required field: '{field}'")

    if 'source' in pkg:
        src = pkg['source']
        if isinstance(src, dict):
            for sfield in SOURCE_REQUIRED:
                if sfield not in src:
                    errors.append(f"Missing required source field: 'source.{sfield}'")

    return errors


def resolve_url(url_template, env_vars=None):
    """Resolve URL template variables like {{ GOZJARO_KERNEL_VERSION }}."""
    if env_vars is None:
        env_vars = {}

    result = url_template
    import re
    matches = re.findall(r'\{\{(\w+)\}\}', result)
    for var in matches:
        val = env_vars.get(var, '')
        if val:
            result = result.replace('{{' + var + '}}', val)

    return result


def main():
    parser = argparse.ArgumentParser(
        description='Gozjaro Bootstrap Manifest Parser',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    parser.add_argument('package', nargs='?', help='Package name to query')
    parser.add_argument('--list', action='store_true', help='List all package names')
    parser.add_argument('--validate', nargs='*', metavar='FILE', help='Validate manifest files')
    parser.add_argument('--fields', help='Comma-separated list of fields to output')
    parser.add_argument('--categories', nargs='*', default=None,
                        help='Categories to load (e.g., base system kernel)')
    parser.add_argument('--manifest-dir', default=MANIFEST_DIR,
                        help=f'Manifest directory (default: {MANIFEST_DIR})')
    parser.add_argument('--env', nargs='*', default=[],
                        help='Environment variable overrides (e.g., GOZJARO_KERNEL_VERSION=6.12)')

    args = parser.parse_args()

    # Handle --validate mode
    if args.validate:
        all_valid = True
        for fpath in args.validate:
            data = load_yaml_simple(fpath)
            errors = []
            if data:
                for pkg in data.get('packages', []):
                    errors.extend(validate_package(pkg))

            if errors:
                all_valid = False
                print(f"FAIL: {fpath}")
                for e in errors:
                    print(f"  - {e}")
            else:
                print(f"OK: {fpath}")

        sys.exit(0 if all_valid else 1)

    # Load environment overrides
    env_vars = {}
    for item in args.env:
        if '=' in item:
            k, v = item.split('=', 1)
            env_vars[k.strip()] = v.strip()

    # Load packages
    categories = args.categories
    if not categories and not args.package and not args.list:
        categories = ['base', 'system', 'kernel', 'development', 'live']

    all_packages, all_patches = load_all_packages(categories, args.manifest_dir)

    # Handle --list mode
    if args.list:
        for name in sorted(all_packages.keys()):
            print(name)
        sys.exit(0)

    # Handle specific package query
    if args.package:
        pkg = all_packages.get(args.package)
        if not pkg:
            print(json.dumps({"error": f"Package '{args.package}' not found"}))
            sys.exit(1)

        # Validate
        errors = validate_package(pkg)
        if errors:
            print(json.dumps({
                "error": "Validation failed",
                "package": args.package,
                "errors": errors
            }))
            sys.exit(1)

        # Build output
        output = {}
        output['name'] = pkg['name']
        output['version'] = pkg.get('version', '')
        output['category'] = pkg.get('category', '')

        # Source
        source = pkg.get('source', {})
        if isinstance(source, dict):
            url = source.get('url', '')
            resolved_url = resolve_url(url, env_vars)
            output['url'] = resolved_url
            output['raw_url'] = url
            checksum = source.get('checksum', {})
            if isinstance(checksum, dict):
                output['checksum'] = checksum
            else:
                output['checksum'] = {}
        else:
            output['url'] = str(source)
            output['checksum'] = {}

        # Patches
        patches = pkg.get('patches', [])
        if patches:
            resolved_patches = []
            for p in patches:
                rp = dict(p)
                if 'url' in rp:
                    rp['url'] = resolve_url(rp['url'], env_vars)
                resolved_patches.append(rp)
            output['patches'] = resolved_patches

        # Build info
        build = pkg.get('build', {})
        if build:
            output['build'] = build

        # Dependencies
        deps = pkg.get('dependencies', [])
        if deps:
            output['dependencies'] = deps

        # Global patches for this package
        global_patches = [p for p in all_patches if p.get('package') == args.package]
        if global_patches:
            output['global_patches'] = global_patches

        print(json.dumps(output, indent=2))
        sys.exit(0)

    # Default: show summary
    print(json.dumps({
        "total_packages": len(all_packages),
        "total_patches": len(all_patches),
        "packages": sorted(all_packages.keys()),
        "patches": [p.get('name', '') for p in all_patches]
    }, indent=2))


if __name__ == '__main__':
    main()