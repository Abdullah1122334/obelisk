# TODO-VERIFY

Things assumed but not proven against upstream. Nothing here may be treated as fact.

Format: `[ ] (phase) claim — how to verify`. Closed items move to the bottom with the
evidence that closed them, so a later reader can tell what was checked from what was
merely believed.

## Blocking Phase 2

- [ ] **(2) Plasma 6 colour-scheme file format.** Confirm the current `[Colors:*]` group
      and key names against the installed `plasma-workspace`, not Plasma 5 documentation.
      Several keys were renamed in Plasma 6. **Blocking:** `generate.py` cannot emit a
      colour scheme without them, and a wrong key fails silently — the scheme loads and
      simply ignores it, which looks like a design bug rather than a config bug.
- [ ] **(2) Plasma 6 look-and-feel package layout** — `metadata.json` versus the older
      `metadata.desktop`. **Blocking:** the package will not be detected at all if wrong.
- [ ] **(2) SDDM theme metadata keys and Qt6 QML import versions.** **Blocking:** an SDDM
      theme that fails to load drops the user to a black screen with no greeter, which is
      indistinguishable from a broken boot.
- [ ] **(2) GRUB `theme.txt` supported properties** for the GRUB version in `extra`.
      **Blocking for the Phase 2 acceptance test**, which requires all five surfaces to
      change from a single token edit.
- [ ] **(2) Plymouth theme `.plymouth` keys** for whichever module we choose
      (`two-step` or `script`). **Blocking** for the same reason.
- [ ] **(2) fontconfig family name for IBM Plex Sans Arabic.** The package is confirmed
      to contain the fonts; what is not confirmed is the family string fontconfig
      registers them under. Verify with `fc-list | grep -i plex` in the container, not by
      assumption. **Blocking:** `tokens.yaml` names the family, and a wrong string means
      silent fallback to a default Arabic font on every surface.
- [ ] **(2) Whether `namcap` and a clean `devtools` chroot work inside a privileged
      container on a GitHub runner.** **Blocking:** `repo/build-packages.sh` moved into
      Phase 2 precisely because Calamares must be built, and if chroot builds do not work
      in CI, the whole packaging approach needs rethinking before Phase 4.

## Blocking Phase 4

- [ ] **(4) Whether the Calamares configuration surface alone can produce the six screens
      in the brief — without touching Calamares source.** This is a hard constraint, not
      a preference: the project does not fork upstream. Specifically unverified: can the
      Install-type and Disk screens be built as card layouts using QML view modules and
      branding, or do they require C++ view modules? **If the answer is no, stop and
      report before writing anything** — the fallback is to redesign those screens around
      stock modules, and that is a product decision, not an implementation detail.
- [ ] **(4) Calamares upstream version, and whether the AUR PKGBUILD builds against
      current Qt/KF6 in a clean chroot.** The AUR package has a history of orphaning and
      of non-fatal build warnings on new Python releases. We vendor and pin the PKGBUILD
      unmodified.
- [ ] **(4) Calamares `packagechooser` / `netinstall` module schema** for Standard versus
      Minimal.
- [ ] **(4) How Calamares consumes translations** — whether the `i18n/` generator must
      emit `.ts`/`.qm`, or can supply JSON directly.
- [ ] **(4) Ventoy persistence plugin format**, and whether it works with an
      archiso-derived image without patching initramfs hooks.

## Later phases

- [ ] **(3) squashfs `xz` versus `zstd`:** measure ISO size against boot time and decide
      on evidence. The profile currently matches upstream releng.
- [ ] **(5) `dxvk-bin` availability** — not confirmed in official repos; likely AUR, so
      we would rebuild it. Check whether `dxvk` is now packaged officially.
- [ ] **(5) `bottles` channel** — the brief specifies Flatpak; confirm Flathub is the
      source, and that it is not in the ISO (decision D1).
- [ ] **(5) Proton-GE management** — no official Arch package; decide between an
      `obeliskctl` helper and a packaged fetcher.
- [ ] **(5) `waydroid` packaging status** and kernel requirements.
- [ ] **(5) Registering Arabic fonts inside a Wine prefix** — the correct registry keys
      and `FontSubstitutes` entries, verified by rendering a real Arabic Windows app.
- [ ] **(6) `snapper` behaviour against our subvolume layout** — specifically that
      excluding `@log` and `@pkg` does not confuse `snapper-rollback`.
- [ ] **(7) The current default Arabic fontconfig behaviour on Arch**, so `obelisk-i18n`
      fixes a real defect rather than an imagined one. Capture before/after renderings.
- [ ] **(7) fcitx5 under Wayland** — which of `fcitx5-qt`, `fcitx5-gtk`, and the Plasma
      integration package are needed for a working panel indicator in Plasma 6.
- [ ] **(9) Every hardened sysctl value against Wine, Steam, and Flatpak.** No value
      ships without a written justification and a test proving it broke none of them.
- [ ] **(9) Arch Linux Archive rate limits and retention** for sustained use as our
      pinned mirror.

## Known limitations, accepted rather than pending

- **The Linux text console cannot render Arabic.** It has no shaping, no bidirectional
  layout, and no console font with Arabic coverage. `/etc/motd` is therefore English
  only, and says so in the file itself. Bilingual support begins at the graphical
  session. This is a property of the kernel console, not something Obelisk can fix, and
  it is not a reason to weaken the bilingual requirement anywhere it can be met.
- **Secure Boot ships as MOK enrollment via `sbctl`,** documented. A Microsoft-signed
  shim is out of scope until the project has a stable identity.

## Closed

- [x] **(1) Exact `bootmodes` strings.** Closed by mechanism rather than by lookup:
      `scripts/build-iso.sh` reads the boot modes the installed `mkarchiso` actually
      implements, and fails with the real supported list on drift. Documentation, the
      wiki, and the GitHub mirror disagreed here, so no static answer was trusted.
- [x] **(1) archiso supports GRUB for UEFI.** Confirmed by the archiso profile
      documentation and the ArchWiki archiso page: syslinux for BIOS, GRUB or
      systemd-boot for UEFI. The boot chain in ARCHITECTURE.md section 6 stands.
- [x] **(1) `archiso` version** — `89` in `extra`.
- [x] **(1) Arch Linux Archive URL layout and availability.** Verified live:
      `https://archive.archlinux.org/repos/YYYY/MM/DD/$repo/os/$arch` exists and serves
      `core`, `extra`, and `multilib` with `.db` files. `build-iso.sh` probes the pinned
      date before building and fails early if it is unreachable.
- [x] **(1) GitHub-hosted runners expose no KVM.** Confirmed: the CPU on standard
      Azure-backed runners does not expose hardware virtualisation, and `/dev/kvm` does
      not exist. Larger, paid runners do offer it. Consequence: `test-qemu.sh` runs under
      TCG emulation, and its timings are correctness evidence only, never performance
      measurements. This is exactly why the Phase 3 budget is split.
- [x] **(1) `ttf-ibm-plex` contains IBM Plex Sans Arabic** — 8 weights, alongside Sans,
      Serif, Mono and others, in one official `extra` package. The whole harmonised
      bilingual pairing costs one package and no AUR dependency.
- [x] **(1) Every package name in `iso/packages.x86_64`** was checked individually
      against `archlinux.org/packages`. Note for future sessions: the search API returns
      only the last `name=` parameter when several are passed, which silently produces
      false "not found" results. Query one name at a time.
- [x] **(1) Calamares is in no official Arch repository.** AUR only. This is what moved
      package building from Phase 10 into Phase 2.
