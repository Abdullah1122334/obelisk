#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# Obelisk archiso profile definition.
#
# This file is OURS. Boot loader configuration under efiboot/, syslinux/, and grub/ is
# inherited from the installed archiso releng profile at build time and rebranded — see
# scripts/build-iso.sh, which writes a manifest of exactly what was inherited. Phase 2
# replaces those inherited files with configuration generated from design/tokens.yaml.
#
# Nothing here may contain a hard-coded URL or a maintainer-specific value. Anything of
# that kind arrives through the environment from config.env, and is simply omitted when
# unset rather than replaced with a placeholder.

iso_name="obelisk"

# Volume label. Must be uppercase, <= 32 chars, and stable within a month so that
# written USB sticks keep working. SOURCE_DATE_EPOCH keeps CI builds reproducible.
iso_label="OBELISK_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"

# Appended only when OBELISK_URL is exported. No invented domain ever appears here.
iso_publisher="Obelisk${OBELISK_URL:+ <${OBELISK_URL}>}"
iso_application="Obelisk Live/Install Medium"

iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"

# Max 8 lowercase alphanumeric characters. "obelisk" is 7.
install_dir="obelisk"

buildmodes=('iso')

# BIOS via syslinux, UEFI via GRUB.
#
# GRUB rather than systemd-boot is a deliberate, load-bearing choice: the installed
# system needs GRUB anyway so that grub-btrfs can publish every Btrfs snapshot as a
# boot entry (Phase 6). Using GRUB on the live medium too means the bilingual boot
# menu and the snapshot recovery menu are the same component, themed once.
#
# scripts/build-iso.sh verifies these strings against the boot modes the INSTALLED
# mkarchiso actually implements, and fails with the real supported list if they drift.
# We do not trust documentation or tutorials for these values.
bootmodes=('bios.syslinux' 'uefi.grub')

pacman_conf="pacman.conf"

airootfs_image_type="squashfs"

# Matches upstream releng for now. Phase 3 measures xz against zstd for the real
# trade-off (ISO size versus boot time) and changes this on evidence, not preference.
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')

bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')

# ---------------------------------------------------------------------------
# File permissions
# ---------------------------------------------------------------------------
# NTFS carries no POSIX mode bits, so the maintainer's checkout cannot be trusted to
# hold an executable bit. Every mode that matters is declared here. If a file needs to
# be executable inside the ISO, it MUST appear in this array; nothing is inherited
# from the filesystem the build was launched from.
#
# Format: ["/path"]="UID:GID:MODE"
#
# declare -A is REQUIRED and is not decoration. Without it bash treats this as an
# INDEXED array and evaluates ["/etc/shadow"] as an arithmetic expression, failing with
# "syntax error: operand expected". mkarchiso happens to declare this associative in its
# own scope before sourcing, so upstream profiles get away with omitting it — but that
# makes this file unsourceable by anything else, including our own tooling and tests.
# `bash -n` does NOT catch it: the file parses cleanly and only fails when executed.
declare -A file_permissions
file_permissions=(
  ["/etc/shadow"]="0:0:0400"
  ["/etc/gshadow"]="0:0:0400"
  ["/root"]="0:0:0750"
  ["/root/.bash_profile"]="0:0:0644"
)
