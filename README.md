# Gozjaro LFS Bootstrap

Scripts that build a Linux From Scratch base system (LFS book 12.3) as the
foundation for the Gozjaro distribution.

The build runs end-to-end from a prepared host to a configured LFS system in
`/mnt/lfs` via a single orchestrator (`build.sh`). Every stage is idempotent:
interrupt at any point and re-run — completed work is skipped via marker files
under `$LFS/var/gozjaro/state/`.

Scope: LFS chapters 2 – 9 (host prep through system configuration).
Out of scope: kernel build, bootloader, bootable ISO — perform manually.

## Repo layout

```
build.sh              Orchestrator (usage: ./build.sh <stage>|all|--list|--status)
config/
  lfs.env             LFS, LFS_TGT, distro identity, book version
  packages.txt        Tarball and patch URLs (LFS 12.3)
lib/
  common.sh           Logging, markers, privilege guards
  pkg.sh              Extract / patch / build_pkg helpers
stages/
  00-host-check.sh    Validate host toolchain versions
  10-partition.sh     Mount (or optionally create) the LFS partition
  20-fetch-sources.sh Download tarballs + patches into $LFS/sources
  21-layout.sh        FHS skeleton under $LFS
  22-lfs-user.sh      Create 'lfs' user, hand over ownership
  23-env.sh           Write ~lfs/.bash_profile and ~lfs/.bashrc
  30-cross-toolchain.sh  Chapter 5 (as 'lfs'): binutils-1, gcc-1, headers, glibc, libstdc++
  40-temp-tools.sh    Chapter 6 (as 'lfs'): m4, ncurses, bash, coreutils, ... gcc-2
  50-chroot-prep.sh   Chapter 7.2–7.4: chown, bind mounts, enter chroot, re-run 51/60/70
  51-chroot-tools.sh  Chapter 7.5–7.13: skeleton, gettext, bison, perl, python, util-linux, cleanup
  60-final-system.sh  Chapter 8: ~70 final-system packages
  70-system-config.sh Chapter 9: /etc config (fstab, inittab, profile, …)
```

## Prerequisites

- A 64-bit Linux host (Debian 12 / Arch / Fedora work well).
- Root access (`sudo`).
- Build tools: `gcc`, `g++`, `make`, `bison`, `gawk`, `texinfo`, `python3`, `wget`, `parted`, `e2fsprogs`. Optional: `parallel` for faster downloads.
- 40 GB free disk and ≥ 4 GB RAM (8 GB+ recommended).
- An empty partition (or empty disk) to dedicate to `/mnt/lfs`.

## Usage

```sh
# 1. Validate your host
sudo ./build.sh 00-host-check

# 2. Mount an existing partition as /mnt/lfs
sudo LFS_PART=/dev/sdXN ./build.sh 10-partition
# OR create a new one (DESTRUCTIVE):
sudo LFS_CREATE=1 LFS_DISK=/dev/sdX LFS_SIZE=40GiB ./build.sh 10-partition

# 3. Run everything; resume anywhere on failure
sudo ./build.sh all
```

Useful commands:

```sh
sudo ./build.sh --list       # list stages
sudo ./build.sh --status     # [x]/[ ] per stage
sudo ./build.sh 40           # run only stage 40-temp-tools
sudo ./build.sh --force 40   # re-run it from scratch
```

## Design notes

- **One user, one shell, one env**: stages 30 and 40 are re-invoked as user
  `lfs` via `su -l`. Inside chroot (51/60/70) `$LFS=""` so all paths resolve
  correctly at `/` while the marker directory stays at `/var/gozjaro/state`.
- **Idempotency**: each package builder writes a marker
  (`$STATE_DIR/<stage>.<pkg>.done`) after success. `build_pkg` in `lib/pkg.sh`
  skips when present; `--force` clears markers.
- **No interactive prompts in the build path**: `22-lfs-user.sh` locks the
  `lfs` password instead of calling `passwd`, and never drops into a shell.
- **Patches** are downloaded once into `$LFS/sources` during stage 20 and
  applied from there by `lib/pkg.sh::apply_patch`.
- **Logs**: every stage tees full output to `$LFS/var/gozjaro/log/…`.

## Verification

After stage 30: `$LFS/tools/bin/$LFS_TGT-gcc --version` works and a one-line
C program cross-compiles.
After stage 40: `$LFS/usr/bin/bash --version` runs; all ~16 temp tools present.
After stage 51: inside chroot, `bash`, `coreutils`, `perl`, `python3` usable.
After stage 60: inside chroot, `gcc hello.c && ./a.out` works.
After stage 70: `/etc/{hostname,fstab,inittab,os-release}` populated.

Resume test: interrupt any stage with Ctrl-C, then re-run `./build.sh all` —
the runner should pick up at the failed package.

## Refreshing packages

`config/packages.txt` is a hand-maintained copy of the LFS 12.3 wget-list.
To bump versions:

1. Update `LFS_BOOK_VERSION` in `config/lfs.env`.
2. Regenerate the list from upstream:
   ```sh
   curl -s "$LFS_WGET_LIST_URL" > config/packages.txt
   ```
3. Review patch filenames referenced in `stages/` (`grep -R apply_patch stages/`)
   and update them to match the new book.
4. Adjust hardcoded version strings in build flags (e.g. `--docdir=...`,
   `--with-gxx-include-dir=...14.2.0`, perl `5.40`).

## What's not here

- Kernel `.config` and kernel build (use the LFS book's chapter 10 against
  your hardware).
- GRUB / systemd-boot install.
- Network manager choice (inetutils provides basic tools; configure
  `/etc/sysconfig/ifconfig.*` per the LFS book).

## License

MIT — see `LICENSE`.
