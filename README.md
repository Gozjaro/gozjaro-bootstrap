# Gozjaro LFS Bootstrap

Scripts that build the [Gozjaro](https://github.com/Gozjaro) Linux distribution
from a Linux From Scratch (LFS 12.3) base.

Two build modes:

- **Source mode** (default) — compiles ~80 packages from source, LFS chapters 2-9
- **Binary mode** — installs pre-built packages from a [gozpak](https://github.com/Gozjaro/gozpak) repository (minutes instead of hours)

The build runs end-to-end from a prepared host to a bootable live ISO via a
single orchestrator (`build.sh`). Every stage is idempotent: interrupt at any
point and re-run — completed work is skipped via marker files under
`$LFS/var/gozjaro/state/`.

## Quick start

```sh
# 1. Validate your host
sudo ./build.sh 00-host-check

# 2. Mount a partition as /mnt/lfs
sudo LFS_PART=/dev/sdXN ./build.sh 10-partition

# 3a. Source mode (compile everything)
sudo ./build.sh all

# 3b. Binary mode (install from repo — requires a gozpak repo)
sudo GOZPAK_REPOS=https://repo.gozjaro.org/stable ./build.sh --mode binary all
```

## Build modes

### Source mode (default)

Compiles everything from source following LFS 12.3. Stages:

```
00-host-check → 10-partition → 20-fetch-sources → 21-layout →
22-lfs-user → 23-env → 30-cross-toolchain → 40-temp-tools →
50-chroot-prep → 51-chroot-tools → 60-final-system →
70-system-config → 75-live-tools → 76-pacman → 77-grub →
80-kernel → 85-initramfs → 90-live-iso → 91-release
```

### Binary mode

Installs pre-built packages from a gozpak repository. Skips source fetching,
cross-compilation, and the entire build chain:

```
00-host-check → 10-partition → 21-layout →
50-chroot-prep → 35-gozpak-bootstrap → 36-binary-install →
70-system-config → 80-kernel → 85-initramfs → 90-live-iso
```

Set `GOZPAK_REPOS` to point to your binary package repository.

## Repo layout

```
build.sh                  Orchestrator (./build.sh <stage>|all|--list|--status)
config/
  lfs.env                 LFS, LFS_TGT, distro identity, book version
  packages.txt            Tarball and patch URLs (LFS 12.3)
  base-packages.txt       Package list for binary mode
lib/
  common.sh               Logging, markers, privilege guards
  pkg.sh                  Extract / patch / build_pkg helpers
stages/
  00-host-check.sh        Validate host toolchain versions
  10-partition.sh         Mount (or create) the LFS partition
  20-fetch-sources.sh     Download tarballs + patches
  21-layout.sh            FHS skeleton under $LFS
  22-lfs-user.sh          Create 'lfs' user
  23-env.sh               Write ~lfs/.bash_profile and ~/.bashrc
  30-cross-toolchain.sh   Ch. 5: binutils-1, gcc-1, headers, glibc, libstdc++
  35-gozpak-bootstrap.sh  [binary] Install gozpak into chroot
  36-binary-install.sh    [binary] Install packages via gozpak get
  40-temp-tools.sh        Ch. 6: m4, ncurses, bash, coreutils, ... gcc-2
  50-chroot-prep.sh       Ch. 7: chown, bind mounts, enter chroot
  51-chroot-tools.sh      Ch. 7: skeleton, gettext, bison, perl, python
  60-final-system.sh      Ch. 8: ~70 final-system packages
  70-system-config.sh     Ch. 9: /etc config (fstab, hostname, profile)
  75-live-tools.sh        Live ISO utilities
  76-pacman.sh            Pacman package manager
  77-grub.sh              GRUB bootloader
  80-kernel.sh            Linux kernel (NVMe, EFI, squashfs built-in)
  85-initramfs.sh         Initramfs (dual-mode: live + real-disk boot)
  90-live-iso.sh          Bootable live ISO via grub-mkrescue
  91-release.sh           GitHub release publisher
```

## Usage

```sh
sudo ./build.sh --list           # list stages
sudo ./build.sh --status         # [x]/[ ] per stage
sudo ./build.sh --mode binary --list   # list binary-mode stages
sudo ./build.sh 40               # run only stage 40
sudo ./build.sh --force 40       # re-run from scratch
```

## Prerequisites

- A 64-bit Linux host (Debian 12 / Arch / Fedora)
- Root access (`sudo`)
- Build tools: `gcc`, `g++`, `make`, `bison`, `gawk`, `texinfo`, `python3`, `wget`
- For live ISO: `mksquashfs`, `xorriso`, `grub-mkrescue`, `cpio`
- 40 GB free disk, 4 GB+ RAM (8 GB+ recommended)
- An empty partition for `/mnt/lfs`

Binary mode additionally requires:
- Network access to the gozpak repository
- `curl` or `wget` in the chroot

## Design notes

- **Idempotency**: each package writes a marker file after success. Re-running
  skips completed work. `--force` clears markers.
- **Dual build mode**: `50-chroot-prep.sh` detects `BUILD_MODE` and runs
  either source stages (51/60/70/75/76/77/80/85) or binary stages
  (35/36/70/80/85) inside the chroot.
- **NVMe support**: kernel config enables `BLK_DEV_NVME` and `NVME_CORE`
  built-in. Initramfs loads nvme modules and scans all NVMe device paths.
- **Dual-mode initramfs**: the `/init` script parses `root=` from the kernel
  cmdline — supports `live:LABEL=`, `UUID=`, and `/dev/` paths.
- **No interactive prompts**: the build runs unattended.

## Verification

| After stage | Check |
|-------------|-------|
| 30 | `$LFS/tools/bin/$LFS_TGT-gcc --version` works |
| 40 | `$LFS/usr/bin/bash --version` runs |
| 51 | In chroot: `bash`, `coreutils`, `perl`, `python3` usable |
| 60 | In chroot: `gcc hello.c && ./a.out` works |
| 70 | `/etc/{hostname,fstab,os-release}` populated |
| 90 | `gozjaro-live.iso` boots in QEMU |

Test with:
```sh
qemu-system-x86_64 -m 2G -cdrom gozjaro-live.iso
# NVMe test:
qemu-system-x86_64 -m 2G -cdrom gozjaro-live.iso \
    -drive if=none,id=nvm,file=test.qcow2 -device nvme,serial=1234,drive=nvm
```

## License

MIT — see [LICENSE](LICENSE).
