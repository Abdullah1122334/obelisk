# Obelisk live root profile.
#
# The marker below is how scripts/test-qemu.sh proves the Phase 1 acceptance criterion:
# that the medium boots all the way to an interactive shell, under both BIOS and UEFI.
#
# It is emitted from inside the guest rather than scraped from the bootloader, which
# means the test does not depend on kernel console arguments, on the boot loader
# configuration, or on any file we inherit from upstream. Reaching this line requires
# firmware, boot loader, kernel, initramfs, squashfs, systemd and agetty all to have
# worked, so it is a genuine end-to-end assertion and not a proxy for one.
#
# Writing to the serial port is best-effort: on real hardware there may be no ttyS0,
# and a live session must never fail to give the user a shell because of a test hook.

# The write is attempted unconditionally rather than guarded by a [[ -w ]] test. If the
# guard were wrong -- no serial driver loaded, a device node that exists but is not
# writable -- the marker would silently never appear and a perfectly good boot would look
# identical to a broken one. Attempting and discarding the failure fails safe in the
# other direction: on real hardware without a serial port, the redirect simply fails and
# the user still gets their shell.
{
    printf 'OBELISK_BOOT_MARKER_OK\n'
    printf 'obelisk-version: %s\n' "$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-rolling}")"
    printf 'obelisk-firmware: %s\n' "$([[ -d /sys/firmware/efi ]] && printf 'uefi' || printf 'bios')"
    printf 'obelisk-kernel: %s\n' "$(uname -r)"
    printf 'obelisk-boot-seconds: %s\n' "$(cut -d' ' -f1 /proc/uptime 2>/dev/null || printf 'unknown')"
    printf 'OBELISK_BOOT_MARKER_END\n'
} > /dev/ttyS0 2>/dev/null || true

# /etc/motd is deliberately NOT printed here. agetty --autologin hands off to
# login(1), whose PAM stack already prints it before the shell starts, so doing it
# again produced the banner twice on the live console.
