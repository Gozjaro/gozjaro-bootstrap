#!/usr/bin/env bash
# Publish the versioned live ISO as a GitHub release.
# Runs on the HOST after stage 90 produces the ISO.
# Requires: gh (GitHub CLI), authenticated with push rights to the repo.
#
# The release tag is derived from DISTRO_VERSION and the ISO timestamp so
# multiple releases of the same version (e.g. nightly builds) never collide.
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

start_log 91-release
require_root

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not installed or not in PATH"

# Locate the ISO produced by stage 90.
shopt -s nullglob
isos=( "$GOZJARO_ROOT"/gozjaro-*-live.iso )
shopt -u nullglob

[ "${#isos[@]}" -gt 0 ] || die "no gozjaro-*-live.iso found under $GOZJARO_ROOT (run stage 90 first)"

# Use the newest ISO if somehow multiple exist.
ISO=$(printf '%s\n' "${isos[@]}" | sort | tail -n1)
ISO_FILE=$(basename "$ISO")
log "ISO to publish: $ISO_FILE"

# Derive a release tag from the filename.
#   gozjaro-0.1-20260420-143022-live.iso  →  v0.1-20260420-143022
TAG=$(printf '%s' "$ISO_FILE" | sed 's/^gozjaro-/v/' | sed 's/-live\.iso$//')
log "release tag: $TAG"

ISO_SIZE=$(du -h "$ISO" | cut -f1)

RELEASE_NOTES="## Gozjaro Linux ${DISTRO_VERSION} live ISO

**Build:** \`${ISO_FILE}\`
**Size:** ${ISO_SIZE}

### What's included
- Linux kernel (LFS 12.3 base)
- systemd 256 as init
- GRUB 2.12 (BIOS i386-pc + UEFI x86_64-efi)
- Live tools: curl, wget, git, rsync, openssh, nano, parted, dosfstools
- pacman 6.1.0 package manager
- linux-firmware (broad hardware support)
- \`gozjaro-install\` CLI installer

### Boot
\`\`\`
qemu-system-x86_64 -m 2G -cdrom ${ISO_FILE}
\`\`\`

### Install to disk
Boot the live ISO, then run:
\`\`\`
gozjaro-install --target /dev/sdX
\`\`\`
"

log "creating GitHub release $TAG"
gh release create "$TAG" \
    --title "Gozjaro Linux ${DISTRO_VERSION} (${TAG#v*})" \
    --notes "$RELEASE_NOTES" \
    --latest \
    "$ISO"

log "release published: $TAG"
log "upload: $ISO_FILE (${ISO_SIZE})"
mark_done 91-release
