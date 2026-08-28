# Building Obelisk

Obelisk is built on Linux. If you are on Windows, read
[BUILDING-ON-WINDOWS.md](BUILDING-ON-WINDOWS.md) instead — this page still explains what
the build does, but you will not run it locally.

## What builds where

| Path | Runs on | Purpose |
|---|---|---|
| GitHub Actions | reference | The build path Obelisk is designed around. Everything is verified here. |
| An Arch Linux host or container | optional | Faster iteration. Never a prerequisite. |
| Windows | never | `mkarchiso` needs an Arch host, root, and loop devices. This is by design, not a gap. |

## Prerequisites

An Arch Linux system (or `archlinux:latest` container) with root:

```sh
pacman -S --needed archiso qemu-base edk2-ovmf curl rsync
```

The container must be privileged. `mkarchiso` creates device nodes and mounts loop
devices, and neither works in an unprivileged container:

```sh
docker run --rm --privileged -v "$PWD:/build" -w /build archlinux:latest bash
```

## Configure

```sh
cp config.env.example config.env
```

Only one value is required to build: `OBELISK_ARCHIVE_DATE`. Everything else is either
optional or belongs to a later phase, and any unset value is **omitted** rather than
replaced with a placeholder — no invented URL or key ever reaches a built artifact.

`OBELISK_ARCHIVE_DATE` pins Arch to a dated snapshot on the Arch Linux Archive. This is
how Obelisk stays 7 to 14 days behind Arch without operating a mirror (decision D2 in
[ARCHITECTURE.md](ARCHITECTURE.md)). Confirm a candidate date exists before using it:

```sh
curl -sfI https://archive.archlinux.org/repos/2026/08/14/core/os/x86_64/core.db
```

## Build

```sh
sudo ./scripts/build-iso.sh
```

Useful options:

```sh
sudo ./scripts/build-iso.sh --dry-run     # assemble and validate the profile, build nothing
sudo ./scripts/build-iso.sh --keep-work   # keep the scratch tree for inspection
sudo ./scripts/build-iso.sh --out dist    # write the ISO somewhere else
```

Output lands in `out/`: the ISO, its `.sha256`, and `profile-manifest.txt`.

## What the build script does that `mkarchiso` alone does not

1. **Verifies boot modes against reality.** The valid `bootmodes` strings have changed
   across archiso releases and the documentation, the wiki, and tutorials disagree. The
   script reads the boot modes the *installed* `mkarchiso` actually implements and fails
   with the real supported list if `iso/profiledef.sh` has drifted.
2. **Assembles the profile in layers and records them.** Boot loader configuration is
   inherited from the installed releng profile so it always matches the archiso doing the
   build, then rebranded, then overlaid with `iso/`, which wins every conflict.
   `out/profile-manifest.txt` states exactly which file came from where, so inherited
   configuration is visible in review rather than invisible. Phase 2 replaces the
   inherited boot loader files with output generated from `design/tokens.yaml`.
3. **Solves the bootstrap ordering problem.** See below.
4. **Enforces the size ceiling as a failure**, not a warning.

## Bootstrapping: building before any package repository exists

Obelisk needs packages Arch does not carry — Calamares above all, which is
[not in any official Arch repository](ARCHITECTURE.md). Those packages come from the
Obelisk repository, which is itself built by CI. That is circular, and the circle is
broken deliberately:

- **The ISO build never requires a published repository.** If
  `repo/build-packages.sh` has produced a local repository at `$OBELISK_LOCAL_REPO`
  (default `out/repo`) containing an `obelisk.db`, `build-iso.sh` appends it to the
  build-time `pacman.conf` **as the last repository**, so an Obelisk package can never
  shadow an upstream one.
- **If it has not, the build proceeds from Arch alone** and simply produces an ISO
  without our packages. This is the expected state during bootstrap and in Phase 1.
- A completely fresh clone on a machine that has never seen this project must be able to
  build. There is no external dependency and no manual priming step.

The full sequence, once Phase 2 lands `repo/build-packages.sh`, is one job:

```sh
sudo ./repo/build-packages.sh    # clean devtools chroot -> out/repo/obelisk.db
sudo ./scripts/build-iso.sh      # picks up out/repo automatically
```

## Test

```sh
./scripts/test-qemu.sh                 # BIOS and UEFI
./scripts/test-qemu.sh --mode uefi     # one firmware only
```

The test boots the medium headlessly and waits for `OBELISK_BOOT_MARKER_OK` on the
serial port. That marker is written by `/root/.bash_profile` inside the image, so seeing
it proves firmware, boot loader, kernel, initramfs, squashfs, systemd, and agetty all
worked end to end. It needs no KVM.

**Timings from this script are not performance measurements.** GitHub-hosted runners
expose no `/dev/kvm`, so this runs under TCG emulation. Absolute boot numbers are
measured on real hardware and recorded in `docs/PERFORMANCE.md`; CI never publishes a
number it did not measure.

## Line endings

`scripts/check-line-endings.sh` runs first in CI and can be run at any time:

```sh
./scripts/check-line-endings.sh
```

A single CRLF in a shell script makes Linux report `bad interpreter: No such file or
directory`, which names the interpreter rather than the cause. `.gitattributes` prevents
it; this check proves it.
