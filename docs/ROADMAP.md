# Obelisk — Roadmap

Each phase ends with a file tree, a summary, and a commit. Work does not start on the next
phase until the maintainer confirms.

## Two proposed deviations from the original phase order

Both follow from a verified fact rather than a preference, and both are recorded here so
the change is deliberate and reviewable.

**1. Package building moves from Phase 10 to Phase 2.** Calamares is not in any official
Arch repository, so the installer cannot exist until Obelisk can build and serve packages.
Phase 2 already needs to build `obelisk-branding` as a real package. Phase 2 therefore
gains a minimal `repo/build-packages.sh` (clean `devtools` chroot, dependency order, local
unsigned repository). Phase 10 keeps everything that is genuinely release engineering:
GPG signing, publishing, hosting, and the release checklist.

**2. The performance budget splits into a measurable half and an honest half.** CI runners
have no KVM and no SSD, so an absolute boot time measured there would be fiction. Phase 3
delivers CI enforcement of ISO size, idle RAM, and relative regression in a fixed QEMU
configuration, plus a `benchmark.sh` the maintainer runs on real hardware for the absolute
numbers. `docs/PERFORMANCE.md` states which numbers came from which, every release.

## Phases

| # | Phase | Delivers | Acceptance |
|---|---|---|---|
| 1 | Skeleton, line-ending safety, CI | `.gitattributes` and `check-line-endings.sh` first; adapted releng archiso profile; `build-iso.sh`; `test-qemu.sh`; `build-iso.yml`; `BUILDING.md` + `BUILDING-ON-WINDOWS.md` | CI produces an ISO that boots to a TTY in QEMU under **both** BIOS and UEFI, and the CRLF check passes |
| 2 | Design system, branding, package pipeline | `tokens.yaml` and `generate.py` **first**, then all five themes generated from it; `obelisk-branding`; ASCII logo; minimal `repo/build-packages.sh` | GRUB → Plymouth → SDDM → desktop identical in color, type, and logo, zero Arch branding. Changing one hex in `tokens.yaml` visibly changes all five surfaces. **Plus the carried-forward items below.** |
| 3 | Performance budget | `obelisk-performance`: baloo off, ZRAM 50% zstd with `vm.swappiness=180`, systemd-oomd, `systemd-analyze blame` audit, blur off on integrated graphics; `benchmark.sh` | Idle RAM ≤ 700 MB and ISO ≤ 3.5 GB enforced in CI; boot times measured on real hardware and published. A missed target is reported with a proposed cut, never lowered |
| 4 | Live session and installer | Bilingual five-entry boot menu; live desktop with Install icon; persistence incl. Ventoy; Calamares built, themed, bilingual; the six installer screens | Burn to USB, boot, browse the web, switch language, then install — all without reading documentation |
| 5 | Windows application compatibility | `obelisk-compat-layer`; pre-configured Wine prefix with Arabic fonts registered **inside** the prefix; `.exe`/`.msi` MIME handling with a bilingual prefix-choice dialog; `obeliskctl run`; virt-manager/libvirt guided VM path; optional Waydroid | A `.exe` double-click works; an Arabic-language Windows app renders Arabic correctly; `docs/COMPATIBILITY.md` is honest in three columns |
| 6 | Unbreakable system | Btrfs subvolume layout; snapper + snap-pac + grub-btrfs; `obeliskctl rollback` and a GUI entry; pre-flight free-space check | Break the system deliberately, reboot, pick the previous snapshot in GRUB, land in a working desktop, make it permanent in one command |
| 7 | Full bilingual support | `obelisk-i18n`: Arabic font set; tuned fontconfig fixing Arch Arabic rendering (fallback order, no synthetic bolding); fcitx5 under Wayland and XWayland with a panel indicator; `ar_EG`/`ar_SA`/`en_US` locales; Hijri calendar; `audit-rtl.sh` | `audit-rtl.sh` screenshots every default app under RTL and logs failures to `docs/RTL-STATUS.md` |
| 8 | First-run wizard | `obelisk-welcome` in QML on the design tokens: language → GPU drivers → Windows compatibility → software presets with download size shown → performance → privacy and security → finish | Prominent "Skip and use defaults" on every screen; closing mid-way reopens at the same step and never leaves the system half-configured |
| 9 | Security and delayed mirror | firewalld inbound-denied; AppArmor with upstream profiles; systemd-resolved with DNS-over-TLS; documented hardened sysctl verified against Wine, Steam, and Flatpak; LUKS prominent in the installer; `mirror-sync.sh`; `docs/KEYRING.md` with rotation schedule and expiry alarm | Every sysctl value carries a written justification; the keyring cannot expire silently |
| 10 | Repository and release engineering | `sign-and-publish.sh` (GPG-signs packages and database, emits a static-hostable directory); hosting docs for GitHub Pages, Cloudflare R2, and a VPS; `docs/RELEASING.md` | Our repository is ordered after `core`/`extra` and provably cannot shadow upstream |
| 11 | Testing and polish | `lint.sh`: shellcheck, namcap, QML/XML validation, CRLF check, Arch-branding scan; CI headless smoke test asserting key services and running `benchmark.sh`; `docs/TESTING.md` manual matrix | CI fails on any performance regression; the manual matrix covers BIOS/UEFI, Secure Boot, NVIDIA/AMD/Intel, Wi-Fi firmware, HiDPI, suspend/resume, LUKS+Btrfs, install alongside Windows, snapshot rollback, USB persistence, and a 4 GB machine |

## Phase 2 definition of done — carried forward from Phase 1

These are obligations Phase 1 deliberately deferred. They are listed separately because a
deferred check that nobody promotes is the same as no check at all.

**1. Promote the Arch branding scan from a warning to a hard failure.**

Phase 1 gated its own CI on a de-branding requirement that Phase 2 is the phase
responsible for satisfying. The result was a build that failed in 11 seconds without
testing a single one of Phase 1's actual acceptance criteria — strictly worse than not
having run the check. It was downgraded to a `::warning::` in
`.github/workflows/build-iso.yml`, and Phase 2 must restore it to `::error::` with a
non-zero exit.

**2. Narrow that scan's scope at the same time.**

As written it matches any occurrence of the string in any tracked file under
`iso/airootfs/`, including source comments. It currently trips on exactly one line:

```
iso/airootfs/etc/pacman.conf:12:
# The Arch repositories are pinned to a dated Arch Linux Archive snapshot, ...
```

That is not branding. "Arch Linux Archive" is the real name of the upstream service
Obelisk pins its mirror to, it appears in a comment, and Obelisk will reference it for as
long as decision D2 stands. `docs/LEGAL.md` additionally *requires* Obelisk to state that
it is based on Arch Linux, so a scan that forbids the phrase outright contradicts the
legal obligation it exists to enforce.

The Phase 2 version must therefore target **user-visible strings** — boot menu entries,
`os-release` fields, desktop files, greeter and installer text, window titles — and not
source comments or documentation. Narrowing the scope is part of promoting it, not a
separate task: a check that is broadened into a hard failure without being scoped first
will simply be disabled again by the next person it blocks.

**3. Replace the inherited boot loader configuration.**

Phase 1 inherits `efiboot/`, `syslinux/`, and `grub/` from the installed releng profile
and applies a rebranding pass, which is why Arch branding is expected to be present right
now. Phase 2 generates these files from `design/tokens.yaml`, at which point the
inherited layer in `scripts/build-iso.sh` shrinks to nothing, the rebranding pass is
deleted, and `out/profile-manifest.txt` should list no inherited files.

## Standing rules across all phases

- Every script begins with `set -euo pipefail` and fails with a message that names what
  went wrong and what to do about it.
- No invented package names, paths, or config keys. Anything unverifiable goes to
  `TODO-VERIFY.md` rather than being guessed.
- No placeholder values inside working files. Maintainer-supplied values live in
  `config.env.example` with comments explaining each one.
- Package prefix `obelisk-`. CLI `obeliskctl`, alias `obk`. Paths `/usr/share/obelisk/`
  and `~/.local/share/obelisk/`.
- Every file in `docs/` has an `.ar.md` twin.
- Conventional commits, one per phase.
