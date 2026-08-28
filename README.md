<div align="center">

# Obelisk

**Cut from one stone.**

An Arch-based Linux distribution: bilingual Arabic and English, hard to break,
and built to run Windows software on hardware Windows 11 rejects.

[العربية](README.ar.md) · [Architecture](docs/ARCHITECTURE.md) · [Roadmap](docs/ROADMAP.md) · [Building](docs/BUILDING.md)

</div>

---

> **Status: Phase 1 of 11.** The ISO builds and boots. There is no desktop, no installer,
> and no branding yet. Phases are listed in [docs/ROADMAP.md](docs/ROADMAP.md).

## What Obelisk is for

An obelisk is cut from one block of granite, capped with electrum to catch the first
light, and has stood for three and a half thousand years. That is the product thesis:
**monolithic, precise, and it does not fall over.**

Four claims, and everything in this repository exists to serve one of them:

1. **Runs Windows software with minimal friction.** A pre-configured Wine prefix that
   already has Arabic fonts registered inside it, `.exe` handling that works on a double
   click, and an honest compatibility table that tells you what does *not* work.
2. **Cannot be permanently broken by an update.** Btrfs subvolumes, a snapshot on every
   pacman transaction, and every snapshot as a GRUB entry. Recovery needs no working
   userspace and no documentation: reboot, pick the previous entry.
3. **Fully bilingual, with neither language a translation of the other.** Arabic and
   English are the top two options at every language decision point, from the boot menu
   onward. One source of truth for every string. Switching language is a toggle.
4. **Runs well on hardware Windows 11 refuses to install on.** A performance budget that
   is enforced in CI rather than aspired to, and measured on real hardware rather than
   estimated.

## Technical baseline

| | Choice | Why |
|---|---|---|
| Base | Arch Linux, archiso | Rolling: the newest Wine, Mesa, and kernel, which Windows compatibility depends on |
| Desktop | KDE Plasma 6, Wayland default, X11 available | Best RTL support, deepest theming, lighter than GNOME |
| Installer | Calamares | Modular and themeable. Note: **not in any Arch repository** — Obelisk builds it |
| Filesystem | Btrfs, subvolumes, zstd | Required for snapshots |
| Kernel | `linux`, with `linux-lts` as a GRUB fallback | `linux-zen` is opt-in: it costs laptop battery and is never forced |
| Audio | PipeWire + WirePlumber | Low latency, works with Wine and Proton |
| Network | NetworkManager + systemd-resolved, DNS over TLS | Private by default |
| Updates | Arch, pinned 7-14 days behind | Protection from rolling-release breakage |

## Build it

Obelisk is built by CI, not on a workstation — see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 2 for why that is a design decision
rather than a limitation.

```sh
cp config.env.example config.env    # set OBELISK_ARCHIVE_DATE
sudo ./scripts/build-iso.sh
./scripts/test-qemu.sh              # boots it under BIOS and UEFI
```

On Windows, read [docs/BUILDING-ON-WINDOWS.md](docs/BUILDING-ON-WINDOWS.md) first. There
is one setup step there that matters more than all the others, and skipping it corrupts
the project silently.

## Repository layout

| Path | Contents |
|---|---|
| `design/` | `tokens.yaml`, the single source of truth for the entire look |
| `i18n/` | `en.json` and `ar.json`, the single source of truth for every string |
| `iso/` | The archiso profile: packages, pacman configuration, live root filesystem |
| `packages/` | Obelisk's own packages, all prefixed `obelisk-` |
| `repo/` | Package building, signing, and publishing |
| `installer/` | Calamares configuration and branding — never a fork of Calamares |
| `scripts/` | Build, test, benchmark, and audit tooling |
| `docs/` | Documentation. Every file has an `.ar.md` twin |

## Licence and attribution

Obelisk's own code is [GPL-3.0](LICENSE).

Obelisk is **based on Arch Linux** and is **not affiliated with, endorsed by, or
supported by the Arch Linux project**. Arch trademarks and branding are removed from
every user-visible surface. See `docs/LEGAL.md`.
