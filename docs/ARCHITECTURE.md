# Obelisk — Architecture

> Status: pre-Phase-1 design record. Decisions here are binding until superseded by a
> later entry in this file. Facts marked **verified** were checked against upstream on
> 2026-08-28; anything that could not be checked lives in [TODO-VERIFY.md](../TODO-VERIFY.md).

## 1. Thesis

An obelisk is cut from one block of granite, capped with electrum, and has stood for
three and a half thousand years. The product follows the object: **monolithic, precise,
and it does not fall over.**

Concretely, Obelisk is an Arch derivative that:

1. runs Windows software with minimal friction,
2. cannot be permanently broken by an update,
3. is fully bilingual Arabic/English with neither language a translation of the other,
4. runs well on hardware Windows 11 refuses to install on.

Everything below exists to serve one of those four claims. A component that serves none
of them is out of scope.

## 2. The constraint that shapes everything: the build host is Windows

Development happens on Windows. This is not an inconvenience to work around; it is a
structural constraint that dictates the architecture.

| Constraint | Architectural consequence |
|---|---|
| `mkarchiso` needs an Arch host, root, and loop devices | **CI is the only supported build path.** GitHub Actions running a privileged `archlinux:latest` container is the reference builder. A local Arch VM is a documented accelerator and must never become a prerequisite for any script. |
| Windows checkouts can introduce CRLF | `.gitattributes` with `* text=auto eol=lf` is the **first file in the repository**, backed by `scripts/check-line-endings.sh`, which fails CI on any CRLF. One CRLF in a shell script produces `bad interpreter` on Linux and is the highest-probability catastrophic failure in this project. |
| NTFS has no POSIX mode bits | Executable bits are **declared**, never inherited: the `file_permissions` array in `profiledef.sh` for ISO content, `install -Dm755` in every PKGBUILD for packaged content. Nothing may depend on a mode present on the maintainer disk. |
| The maintainer cannot boot the artifact natively | `scripts/test-qemu.sh` (BIOS + UEFI via OVMF) is the primary verification loop and must run on the Windows host through QEMU for Windows, not only in CI. |

No Windows path syntax, drive letter, or `%USERPROFILE%` reference may appear in any
tracked file. Windows-side operator instructions are PowerShell and live in
`docs/BUILDING-ON-WINDOWS.md`, isolated from everything the build consumes.

## 3. Verified upstream facts

Checked against `archlinux.org/packages` and upstream repositories. These are
load-bearing, and several overturn assumptions in the original brief.

| Fact | Value | Impact |
|---|---|---|
| **Calamares is in no official Arch repository** | AUR only (`calamares`, `calamares-git`) | **We must build and host Calamares ourselves.** This promotes `repo/` from a Phase 10 nicety to a Phase 4 blocker. See section 7. |
| `archiso` version | `89` (extra) | The profile targets archiso 89, not the older three-bootmode layout most tutorials show. |
| archiso supports GRUB as a boot mode | yes | The themed bilingual boot menu and `grub-btrfs` share one bootloader. No systemd-boot/GRUB split. |
| `ttf-ibm-plex` contains IBM Plex Sans Arabic | yes, 8 weights, alongside Sans/Serif/Mono | **One official package provides the entire harmonised Latin + Arabic pairing.** Validates the typography choice with zero AUR dependency. |
| `wine`, `wine-staging`, `wine-mono`, `wine-gecko`, `winetricks` | all `extra` | Phase 5 core needs no AUR. |
| `vkd3d` / `lib32-vkd3d` | `extra` / `multilib` | Phase 5 core needs no AUR. |
| `grub-btrfs` | `4.14` (extra) | Phase 6 core needs no AUR. |
| `snap-pac` | `3.0.1` (extra) | Phase 6 core needs no AUR. |

## 4. Decisions taken

### D1 — Lean ISO, payload fetched after install

The ISO carries KDE Plasma 6, Calamares, the Arabic font set, and Obelisk branding. The
Windows compatibility layer, the VM stack, graphics drivers, and codecs are **not** on the
ISO; the first-run wizard fetches them.

This is the only configuration that satisfies the 3.5 GB size budget and the legal
requirement that no proprietary redistributable ship in the image at the same time. It has
a real cost: a **Standard** install requires a working network connection. The installer
must say so plainly on the Network screen rather than failing later.

### D2 — Delayed mirror: Arch Linux Archive now, own mirror later

`pacman.conf` pins to a dated snapshot on `archive.archlinux.org`, advanced weekly by CI
only after the smoke test passes. This gives an exactly controlled 7-14 day delay at zero
hosting cost, and reduces an emergency security fast-track to a one-line commit.

To keep the later migration cheap, **every repository URL is generated into a single file**
from `config.env`. Moving to a self-hosted rsync mirror must be a configuration change, not
a refactor.

### D3 — Arabic UI register is Modern Standard Arabic

`i18n/ar.json` is written in clean, concise MSA, the register KDE, GNOME, and every serious
distribution use, and the one every Arabic speaker from Morocco to the Gulf reads without
friction. Colloquial Arabic in an operating system UI would read as unserious and would make
outside translation contributions harder to review.

### D4 — Public GitHub repository

Unmetered Actions minutes, free Releases hosting for ISOs, GitHub Pages for the pacman
repository and the documentation site. The owner/repo slug is supplied through `config.env`
and is never hard-coded.

## 5. Single sources of truth

Two files fan out to everything. Nothing downstream of them is hand-edited, and CI fails if
a generated file is committed out of date.

```
design/tokens.yaml ──> design/generate.py ──┬─> Plasma color schemes (light + dark)
                                            ├─> Plasma look-and-feel package
                                            ├─> SDDM QML variables
                                            ├─> Plymouth theme colors
                                            ├─> GRUB theme.txt
                                            ├─> Calamares stylesheet.qss + branding.desc
                                            ├─> obelisk-welcome QML variables
                                            └─> docs site CSS

i18n/{en,ar}.json ───> generator ───────────┬─> Calamares translations
                                            ├─> obelisk-welcome (Qt .ts/.qm)
                                            ├─> obeliskctl message catalog
                                            └─> GRUB and Plymouth boot strings
```

The Phase 2 acceptance test is mechanical: change one hex value in `tokens.yaml`, run
`generate.py`, and watch GRUB, Plymouth, SDDM, the desktop, and Calamares all move. Any
surface that does not move is hand-written, and that is a bug.

## 6. Boot chain

One bootloader end to end, so that the boot menu and the snapshot menu are the same menu.

```
firmware (BIOS or UEFI)
  └─ GRUB ── themed from tokens.yaml, menu bilingual AR/EN
       ├─ Obelisk (linux)              default
       ├─ Obelisk (linux-lts)          fallback kernel
       ├─ Obelisk snapshots ▸          injected by grub-btrfs
       └─ Firmware settings
            └─ Plymouth ── theme from tokens.yaml
                 └─ SDDM ── theme from tokens.yaml, language picker present
                      └─ Plasma 6 (Wayland default, X11 session offered)
```

On the live ISO the same GRUB serves the five-entry bilingual menu.

## 6a. What we forked away from, and when

Phase 1 inherited `efiboot/`, `syslinux/` and `grub/` from the installed releng profile
at build time, so every upstream fix arrived automatically. **Phase 2 stops doing that.**
The boot loader configuration is generated from `design/tokens.yaml` instead, because the
inherited files carried Arch trademarks -- `MENU TITLE Arch Linux` and, more seriously,
`splash.png`, a 45 KB image with the Arch logo and their registered tagline rendered into
it. `docs/LEGAL.md` does not permit shipping those, and no text rebranding pass can edit
a PNG.

That is a real trade and it is worth naming plainly: **we have taken on maintenance debt.**
Upstream boot fixes no longer reach us for free.

**Forked at archiso 89.** The files below are now ours. When archiso is upgraded, diff
these against the new releng profile before assuming nothing changed.

| Inherited until Phase 2 | Now | Why it had to become ours |
|---|---|---|
| `syslinux/syslinux.cfg` | generated | dispatch between PXE and ISO boot |
| `syslinux/archiso_head.cfg` | generated from tokens | held `MENU TITLE Arch Linux`, `MENU BACKGROUND splash.png`, and the menu colour scheme |
| `syslinux/archiso_sys.cfg` | generated | include order, `DEFAULT`, `TIMEOUT` |
| `syslinux/archiso_sys-linux.cfg` | generated | the kernel command lines |
| `syslinux/archiso_tail.cfg` | generated | chain-boot, memtest, HDT, reboot, poweroff entries |
| `syslinux/splash.png` | **deleted, replaced from `design/`** | Arch logo and registered tagline |
| `grub/grub.cfg` | generated from tokens | menu entries and theming |
| `efiboot/` | **not used** | archiso documents `efiboot/` as mandatory only for the `uefi.systemd-boot` bootmode. Obelisk declares `uefi.grub`, so it was inherited in Phase 1 and never consumed. Dropped rather than generated. |

**What we lose by owning them.** Upstream changes to boot parameters, new hooks, syslinux
module renames, and fixes for firmware quirks. Anything archiso learns about booting on
awkward hardware, we now have to learn separately.

**How the debt is serviced.** `scripts/build-iso.sh` records the archiso version it built
with in `out/profile-manifest.txt`. On every archiso major version bump, the maintainer
diffs `/usr/share/archiso/configs/releng/` against the generator's output and decides
deliberately what to adopt. This is written into the release checklist in
`docs/RELEASING.md` rather than left to memory, and tracked in `TODO-VERIFY.md`.

The alternative -- keeping the inheritance and stripping trademarks afterwards -- was
rejected. It failed once already: the Phase 1 rebranding pass matched `Arch Linux` and
`archlinux` but not the tagline, and could not touch the PNG at all. A subtractive
approach to trademark removal fails open, and for a legal control that is the wrong
default.

### Secure Boot: what the fork changed

**Nothing.** Recorded here before Phase 4 rather than discovered during install testing.

The official Arch installation image has not supported Secure Boot since
`archlinux-2016.06.01-dual.iso`, when prebootloader was replaced with efitools and the
signed path was dropped. The image contains no shim, no signed boot loader, and no MOK
infrastructure. Secure Boot is not mentioned anywhere in archiso's profile documentation.

So there was nothing to inherit and nothing has been lost. Obelisk's position is what it
already was: Secure Boot must be turned off to boot the medium, or the user enrols their
own keys.

Two consequences worth having on the record:

- **The fork slightly helps rather than hurts here.** Obelisk boots UEFI through GRUB,
  not systemd-boot, and GRUB plus shim is the well-trodden path that other distributions
  already sign. Owning the boot configuration means a future signed chain is a change we
  can make, rather than one we would have to fight the inherited profile to make.
- **The installed system and the medium are separate problems.** Phase 4 targets MOK
  enrolment via `sbctl` for the *installed* system. Making the *medium* itself bootable
  under Secure Boot needs a signed shim, which needs either a Microsoft signing
  submission or the user enrolling a key before first boot. That remains out of scope
  until the project has a stable identity, as section 10 already states.

## 7. Package and repository architecture

Because Calamares is AUR-only (section 3), Obelisk needs its own binary repository before
the installer can ship. That repository serves three classes of package and no others:

1. **Obelisk packages** — everything under `packages/`, prefix `obelisk-`.
2. **Rebuilt AUR dependencies** — Calamares above all, plus any AUR package the ISO needs.
   Built in a clean `devtools` chroot, never with `makepkg -si` on a live system.
3. **Nothing else.** The repository is ordered *after* `core` and `extra` in `pacman.conf`
   so it can never shadow an upstream package. A lint check enforces the ordering; we do
   not rely on convention.

`obelisk-keyring` signs the database. Key rotation is scheduled and alarmed
(`docs/KEYRING.md`), because a silently expired keyring is the single failure that has most
often stranded users of other Arch derivatives.

## 8. Unbreakability model

| Mount point | Subvolume | Snapshotted | Reason |
|---|---|---|---|
| `/` | `@` | yes | The thing we roll back. |
| `/home` | `@home` | yes, separate timeline | User data must not roll back with the system. |
| `/var/log` | `@log` | **no** | A rollback must not erase the evidence of what broke. |
| `/var/cache/pacman/pkg` | `@pkg` | **no** | High churn, large, worthless inside a snapshot. |
| `/.snapshots` | `@snapshots` | n/a | Snapshot store. |

Mount options: `noatime,compress=zstd:3,space_cache=v2`.

`snap-pac` snapshots every pacman transaction; `grub-btrfs` publishes each snapshot as a
GRUB entry. Recovery therefore needs no working userspace and no documentation: the user
reboots and picks the previous entry. `obeliskctl rollback` makes it permanent.

A pre-flight free-space check runs before large upgrades, because a Btrfs filesystem that
hits ENOSPC mid-transaction is the one failure mode snapshots cannot rescue.

## 9. Bilingual model

Arabic and English are peers. The rules are structural, not editorial.

- Both appear as the **top two options** at every language decision point: GRUB, live
  session, installer, SDDM, wizard.
- One source of truth (`i18n/`), many consumers. No component owns its own strings.
- Language switching is a runtime toggle. It must never require reinstalling or editing a
  file.
- **Mirroring rule.** Direction-carrying elements mirror in RTL: arrows, back and forward,
  progress, indentation, panel order. Identity and physical-metaphor elements do not: the
  logo, shadows, media transport controls, clocks. Codified in `docs/RTL-RULES.md`,
  enforced by `scripts/audit-rtl.sh`.
- Arabic needs more vertical room than Latin at the same point size. `tokens.yaml` carries
  an explicit Arabic size adjustment and a larger Arabic line height, rather than letting
  each surface improvise.

## 10. Known risks

| Risk | Mitigation |
|---|---|
| CI runner disk (~14 GB usable) is tight for an ISO build | Aggressive pre-build cleanup, build on the larger scratch mount, fail loudly on ENOSPC rather than emit a truncated ISO. Verified in Phase 1. |
| Boot-time targets cannot be measured honestly in CI: no KVM, no SSD | Split the budget. CI enforces ISO size, idle RAM, and **relative** regression in a fixed QEMU configuration. Absolute boot times are measured by the maintainer on real hardware and recorded per release in `docs/PERFORMANCE.md`. CI must never publish a number it did not measure. |
| Calamares AUR churn breaks our installer | We pin and vendor the PKGBUILD. Upstream bumps are a deliberate, tested action. |
| Secure Boot | v1 ships MOK enrollment via `sbctl` plus documentation. A Microsoft-signed shim is out of scope until the project has a stable identity. |
| ISO size creeps past 3.5 GB as Plasma grows | Size is a CI-enforced gate, not a guideline. Exceeding it fails the build and forces an explicit cut. |
