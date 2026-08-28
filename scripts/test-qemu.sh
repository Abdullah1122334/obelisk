#!/usr/bin/env bash
#
# Obelisk — boot the built ISO in QEMU and prove it reaches an interactive shell.
#
# This is the Phase 1 acceptance test. It boots the medium twice, once with the SeaBIOS
# legacy firmware and once with OVMF UEFI firmware, and in each case waits for the guest
# to emit OBELISK_BOOT_MARKER_OK on the serial port. That marker is written by
# /root/.bash_profile inside the image, so seeing it proves that firmware, boot loader,
# kernel, initramfs, squashfs, systemd and agetty all worked end to end.
#
# It needs no KVM. GitHub-hosted runners do not expose /dev/kvm, so this runs under TCG
# emulation there and is slow but correct. Timings from this script are NOT valid
# performance measurements and must never be published as such — see the split described
# in docs/ARCHITECTURE.md section 10.
#
# Exit status: 0 all requested firmware modes booted, 1 a boot failed, 2 usage/environment.

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
readonly REPO_ROOT

die()  { printf '\n%s: error: %s\n\n' "$SCRIPT_NAME" "$1" >&2; exit "${2:-2}"; }
info() { printf '[%s] %s\n' "$SCRIPT_NAME" "$1"; }
warn() { printf '[%s] warning: %s\n' "$SCRIPT_NAME" "$1" >&2; }

usage() {
    cat <<'USAGE'
Usage: ./scripts/test-qemu.sh [OPTIONS] [ISO]

Boots the ISO headlessly and asserts it reaches an interactive shell.

Options:
  -m, --mode MODE     bios | uefi | both        (default: both)
  -r, --ram MiB       guest memory              (default: 4096)
  -c, --cpus N        guest vCPUs               (default: 2)
  -t, --timeout SEC   per-boot timeout          (default: 420)
  -f, --ovmf PATH     explicit OVMF firmware image
  -l, --logdir DIR    where to write serial logs (default: out/qemu)
  -h, --help          this message

If ISO is omitted, the newest *.iso under out/ is used.

Notes:
  - Requires qemu-system-x86_64. UEFI mode additionally requires an OVMF firmware image
    (package "edk2-ovmf" on Arch).
  - No KVM is required or used. Timings here are not performance measurements.
USAGE
}

MODE="both"
RAM_MIB=4096
CPUS=2
TIMEOUT=420
OVMF_PATH=""
LOG_DIR="out/qemu"
ISO_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode)    MODE="${2:?--mode requires bios|uefi|both}"; shift 2 ;;
        -r|--ram)     RAM_MIB="${2:?--ram requires MiB}"; shift 2 ;;
        -c|--cpus)    CPUS="${2:?--cpus requires a count}"; shift 2 ;;
        -t|--timeout) TIMEOUT="${2:?--timeout requires seconds}"; shift 2 ;;
        -f|--ovmf)    OVMF_PATH="${2:?--ovmf requires a path}"; shift 2 ;;
        -l|--logdir)  LOG_DIR="${2:?--logdir requires a directory}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           usage >&2; die "unknown option: $1" ;;
        *)            ISO_PATH="$1"; shift ;;
    esac
done

case "$MODE" in
    bios|uefi|both) ;;
    *) die "--mode must be one of: bios, uefi, both (got: ${MODE})" ;;
esac

cd -- "$REPO_ROOT" || die "cannot enter repository root: $REPO_ROOT"

command -v qemu-system-x86_64 >/dev/null 2>&1 || die \
"qemu-system-x86_64 not found.

  On Arch:     pacman -S --needed qemu-base edk2-ovmf
  On Windows:  install QEMU from https://qemu.weilnetz.de/ and add it to PATH,
               then run this script from Git Bash. See docs/BUILDING-ON-WINDOWS.md."

if [[ -z "$ISO_PATH" ]]; then
    ISO_PATH="$(find out -maxdepth 1 -name '*.iso' -printf '%T@ %p\n' 2>/dev/null \
                 | sort -rn | head -n1 | cut -d' ' -f2-)"
    [[ -n "$ISO_PATH" ]] || die \
"no ISO given and none found under out/.

  Build one first:   sudo ./scripts/build-iso.sh
  Or pass a path:    ./scripts/test-qemu.sh path/to/obelisk.iso"
fi
[[ -f "$ISO_PATH" ]] || die "ISO not found: ${ISO_PATH}"
info "testing: ${ISO_PATH}"

mkdir -p -- "$LOG_DIR"

# ---------------------------------------------------------------------------
# Locate OVMF for the UEFI run
# ---------------------------------------------------------------------------
# Distributions disagree about where OVMF lives and what it is called, so search the
# known locations rather than hard-coding one and failing mysteriously elsewhere.
find_ovmf() {
    [[ -n "$OVMF_PATH" ]] && { printf '%s' "$OVMF_PATH"; return 0; }
    local candidates=(
        /usr/share/edk2/x64/OVMF_CODE.4m.fd
        /usr/share/edk2/x64/OVMF_CODE.fd
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd
        /usr/share/OVMF/OVMF_CODE_4M.fd
        /usr/share/OVMF/OVMF_CODE.fd
        /usr/share/qemu/edk2-x86_64-code.fd
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# One boot attempt
# ---------------------------------------------------------------------------
readonly MARKER='OBELISK_BOOT_MARKER_OK'

boot_once() {
    local firmware="$1"
    local serial_log="${LOG_DIR}/boot-${firmware}.log"
    local -a qemu_args=(
        -machine q35
        -m "$RAM_MIB"
        -smp "$CPUS"
        -cdrom "$ISO_PATH"
        -boot d
        -display none
        -no-reboot
        -serial "file:${serial_log}"
        -device virtio-rng-pci
    )

    if [[ "$firmware" == uefi ]]; then
        local ovmf
        if ! ovmf="$(find_ovmf)"; then
            warn "OVMF firmware not found; cannot test UEFI boot."
            warn "install edk2-ovmf, or pass --ovmf PATH."
            return 3
        fi
        info "UEFI firmware: ${ovmf}"
        # Read-only pflash: we never write back to the shared firmware image.
        qemu_args+=(-drive "if=pflash,format=raw,readonly=on,file=${ovmf}")
    fi

    : > "$serial_log"
    info "booting (${firmware}) — up to ${TIMEOUT}s, no KVM, TCG emulation"

    qemu-system-x86_64 "${qemu_args[@]}" &
    local qemu_pid=$!

    local waited=0
    local found=1
    while [[ $waited -lt $TIMEOUT ]]; do
        if grep -qF "$MARKER" "$serial_log" 2>/dev/null; then
            found=0
            break
        fi
        if ! kill -0 "$qemu_pid" 2>/dev/null; then
            # QEMU exited before the marker appeared.
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if kill -0 "$qemu_pid" 2>/dev/null; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi

    if [[ $found -eq 0 ]]; then
        info "PASS (${firmware}) — reached an interactive shell in ~${waited}s of wall clock"
        sed -n '/OBELISK_BOOT_MARKER_OK/,/OBELISK_BOOT_MARKER_END/p' "$serial_log" \
            | sed 's/^/    /'
        return 0
    fi

    printf '\n%s: FAIL (%s) — %s never appeared within %ss\n\n' \
        "$SCRIPT_NAME" "$firmware" "$MARKER" "$TIMEOUT" >&2
    printf '  Serial log: %s\n' "$serial_log" >&2
    printf '  Last 40 lines:\n' >&2
    tail -n 40 -- "$serial_log" 2>/dev/null | sed 's/^/    /' >&2 || true
    printf '\n  The marker is written by /root/.bash_profile inside the image. Its absence\n' >&2
    printf '  means the guest did not reach an autologin shell on tty1. Check, in order:\n' >&2
    printf '    1. did the boot loader menu appear at all (firmware/boot mode problem)\n' >&2
    printf '    2. did the kernel and initramfs load (mkinitcpio-archiso problem)\n' >&2
    printf '    3. did the squashfs mount (iso_label / archisosearchuuid mismatch)\n' >&2
    printf '    4. did agetty autologin run (airootfs getty drop-in problem)\n\n' >&2
    return 1
}

# ---------------------------------------------------------------------------
# Run the requested modes
# ---------------------------------------------------------------------------
declare -a MODES=()
case "$MODE" in
    both) MODES=(bios uefi) ;;
    *)    MODES=("$MODE") ;;
esac

declare -a PASSED=() FAILED=() SKIPPED=()

for m in "${MODES[@]}"; do
    set +e
    boot_once "$m"
    rc=$?
    set -e
    case $rc in
        0) PASSED+=("$m") ;;
        3) SKIPPED+=("$m") ;;
        *) FAILED+=("$m") ;;
    esac
done

printf '\n[%s] summary\n' "$SCRIPT_NAME"
[[ ${#PASSED[@]}  -gt 0 ]] && printf '  passed:  %s\n' "${PASSED[*]}"
[[ ${#SKIPPED[@]} -gt 0 ]] && printf '  skipped: %s\n' "${SKIPPED[*]}"
[[ ${#FAILED[@]}  -gt 0 ]] && printf '  FAILED:  %s\n' "${FAILED[*]}"
printf '  logs:    %s\n\n' "$LOG_DIR"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    exit 1
fi

# A skipped UEFI run must not be mistaken for a passing acceptance test. Phase 1's
# criterion is BIOS *and* UEFI, so a missing OVMF in CI is a hard failure there.
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    if [[ -n "${CI:-}" ]]; then
        die "firmware mode(s) skipped in CI: ${SKIPPED[*]}. Phase 1 acceptance requires both BIOS and UEFI. Install edk2-ovmf in the workflow." 1
    fi
    warn "skipped: ${SKIPPED[*]} — acceptance is only met when both BIOS and UEFI pass"
fi

exit 0
