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

# Same rule as build-iso.sh: under `set -e` a bare non-zero return kills this script
# silently. Nothing here is allowed to fail without saying where.
on_err() {
    local exit_code=$? line=$1 cmd=$2
    printf '\n%s: FAILED\n' "$SCRIPT_NAME" >&2
    printf '  exit code : %s\n' "$exit_code" >&2
    printf '  line      : %s\n' "$line" >&2
    printf '  command   : %s\n\n' "$cmd" >&2
    exit "$exit_code"
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

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
TIMEOUT=1800
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

# OVMF needs a WRITABLE variable store as a second pflash unit. Attaching only the
# read-only CODE image, as this script first did, leaves the firmware unable to persist
# a boot variable. It commonly then falls through to the EDK2 shell or the setup menu
# and WAITS FOR A KEYPRESS -- on the VGA console, invisible over serial. That is an
# unbounded interactive wait inside an automated test, and a prime suspect for the two
# hour hang in CI run #9.
#
# Paths confirmed against the Arch edk2-ovmf file list.
find_ovmf_vars() {
    local code="$1" guess
    # Same directory, same generation: OVMF_CODE.4m.fd -> OVMF_VARS.4m.fd
    guess="${code/OVMF_CODE/OVMF_VARS}"
    [[ -f "$guess" ]] && { printf '%s' "$guess"; return 0; }
    local candidates=(
        /usr/share/edk2/x64/OVMF_VARS.4m.fd
        /usr/share/edk2/x64/OVMF_VARS.fd
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd
        /usr/share/OVMF/OVMF_VARS_4M.fd
        /usr/share/OVMF/OVMF_VARS.fd
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
readonly POLL_INTERVAL=5
readonly NL=$'
'
ACCEL_USED=""

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

    # Hardware acceleration when it exists. GitHub-hosted standard runners are backed by
    # Azure VMs whose CPUs do not expose virtualisation, so /dev/kvm is absent and this
    # falls through to TCG. TCG is roughly an order of magnitude slower, which is why the
    # default timeout here is generous and why nothing timed from this script may be
    # published as a performance number.
    local accel="tcg"
    if [[ -w /dev/kvm ]]; then
        accel="kvm"
        qemu_args+=(-enable-kvm -cpu host)
    fi
    ACCEL_USED="$accel"

    if [[ "$firmware" == uefi ]]; then
        local ovmf
        if ! ovmf="$(find_ovmf)"; then
            warn "OVMF firmware not found; cannot test UEFI boot."
            warn "install edk2-ovmf, or pass --ovmf PATH."
            return 3
        fi
        local vars_src vars_copy
        if ! vars_src="$(find_ovmf_vars "$ovmf")"; then
            warn "found OVMF code at ${ovmf} but no matching VARS image."
            warn "without a writable variable store the firmware can stop at an"
            warn "interactive prompt and never boot. Refusing to run a test that"
            warn "can hang instead of failing."
            return 3
        fi
        # A fresh private copy per run: the shared image must never be written to, and
        # a stale variable store from a previous run must never influence this one.
        vars_copy="${LOG_DIR}/OVMF_VARS.${firmware}.fd"
        cp -f -- "$vars_src" "$vars_copy"
        chmod u+w -- "$vars_copy"
        info "UEFI firmware: ${ovmf}"
        info "UEFI variables: ${vars_src} -> ${vars_copy} (writable copy)"
        qemu_args+=(
            -drive "if=pflash,unit=0,format=raw,readonly=on,file=${ovmf}"
            -drive "if=pflash,unit=1,format=raw,file=${vars_copy}"
        )
    fi

    : > "$serial_log"
    info "booting (${firmware}) — accel=${accel}, up to ${TIMEOUT}s"
    if [[ "$accel" == tcg ]]; then
        info "  no /dev/kvm: full software emulation, expect roughly 10-20x native"
    fi

    # stdin closed, so neither QEMU nor anything it starts can ever block on a terminal
    # that does not exist. In testing, this alone turned a firmware sitting at an
    # interactive "press any key" prompt from an unbounded hang into an immediate exit.
    #
    # Deliberately NOT wrapped in `timeout`. That was tried and made things worse: this
    # script kills the PID it holds, which would be the timeout wrapper, leaving the real
    # QEMU orphaned and still running with the log pipe open. The bounds that matter are
    # the poll loop below, the SIGTERM-then-SIGKILL escalation after it, and the
    # step-level timeout-minutes in the workflow as the outer guardrail.
    qemu-system-x86_64 "${qemu_args[@]}" </dev/null &
    local qemu_pid=$!

    # Progress tracking. The question after a timeout is always the same -- was it slow
    # or was it stuck -- and it is only answerable if we watched. Serial log growth is
    # the signal: a booting kernel keeps writing, a hung one stops.
    local waited=0 found=1 last_size=0 size stalled_for=0 qemu_self_exited=0

    # How long without output before we call it hung. Absolute thresholds are wrong at
    # both ends: 120s is far too long to wait out a 30s test, and far too twitchy for a
    # 40-minute TCG run where a single xz-compressed squashfs read can stall output.
    # A quarter of the timeout, clamped to a sane band, is right at both scales.
    local stall_threshold=$(( TIMEOUT / 4 ))
    [[ $stall_threshold -lt 10  ]] && stall_threshold=10
    [[ $stall_threshold -gt 180 ]] && stall_threshold=180
    local -i report_every=60 since_report=0

    while [[ $waited -lt $TIMEOUT ]]; do
        if grep -qF "$MARKER" "$serial_log" 2>/dev/null; then
            found=0
            break
        fi
        if ! kill -0 "$qemu_pid" 2>/dev/null; then
            warn "QEMU exited on its own after ${waited}s, before the marker appeared"
            qemu_self_exited=1
            break
        fi

        size="$(stat -c '%s' -- "$serial_log" 2>/dev/null || echo 0)"
        if [[ "$size" -gt "$last_size" ]]; then
            stalled_for=0
            last_size="$size"
        else
            stalled_for=$((stalled_for + POLL_INTERVAL))
        fi

        since_report=$((since_report + POLL_INTERVAL))
        if [[ $since_report -ge $report_every ]]; then
            since_report=0
            info "  ${waited}s: serial log ${size} bytes, last line: $(tail -n1 -- "$serial_log" 2>/dev/null | tr -d '' | cut -c1-70)"
        fi

        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))
    done

    # SIGTERM, then SIGKILL if it does not go. A `wait` on a process that ignores or
    # is slow to handle SIGTERM blocks this script forever, which turns a failed boot
    # test into a hung CI job -- a worse outcome than the failure it is reporting.
    if kill -0 "$qemu_pid" 2>/dev/null; then
        kill -TERM "$qemu_pid" 2>/dev/null || true
        local grace=0
        while kill -0 "$qemu_pid" 2>/dev/null && [[ $grace -lt 10 ]]; do
            sleep 1
            grace=$((grace + 1))
        done
        if kill -0 "$qemu_pid" 2>/dev/null; then
            warn "QEMU ignored SIGTERM after ${grace}s; sending SIGKILL"
            # Children first: a killed parent leaves orphans holding our log pipe open,
            # which stalls anything reading this script's output.
            pkill -KILL -P "$qemu_pid" 2>/dev/null || true
            kill -KILL "$qemu_pid" 2>/dev/null || true
        fi
        wait "$qemu_pid" 2>/dev/null || true
    fi

    if [[ $found -eq 0 ]]; then
        info "PASS (${firmware}) — reached an interactive shell after ~${waited}s of wall clock (accel=${accel})"
        sed -n "/${MARKER}/,/OBELISK_BOOT_MARKER_END/p" "$serial_log" | sed 's/^/    /'
        return 0
    fi

    printf '%s%s: FAIL (%s) — %s never appeared within %ss%s%s'         "$NL" "$SCRIPT_NAME" "$firmware" "$MARKER" "$TIMEOUT" "$NL" "$NL" >&2

    # The verdict the maintainer actually needs, stated rather than left to inference.
    if [[ "$qemu_self_exited" -eq 1 ]]; then
        printf '  VERDICT: QEMU EXITED ON ITS OWN after %ss, before the marker.%s' "$waited" "$NL" >&2
        printf '           The emulator quit rather than timing out, so this is not a slow%s' "$NL" >&2
        printf '           boot. Likely causes: the firmware gave up and powered off, the%s' "$NL" >&2
        printf '           guest shut down or panicked with -no-reboot set, or QEMU itself%s' "$NL" >&2
        printf '           failed to start. Raising the timeout will change nothing.%s%s' "$NL" "$NL" >&2
    elif [[ "$last_size" -eq 0 ]]; then
        printf '  VERDICT: nothing was ever written to the serial port.%s' "$NL" >&2
        printf '           Either the kernel command line has no console=ttyS0 (build with%s' "$NL" >&2
        printf '           --serial-console) or the boot never reached the kernel at all.%s%s' "$NL" "$NL" >&2
    elif [[ "$stalled_for" -ge "$stall_threshold" ]]; then
        printf '  VERDICT: HUNG. Output stopped %ss before the timeout (threshold %ss), at %s bytes.%s' "$stalled_for" "$stall_threshold" "$last_size" "$NL" >&2
        printf '           Raising the timeout will not help. The last lines below are%s' "$NL" >&2
        printf '           where it stopped.%s%s' "$NL" "$NL" >&2
    else
        printf '  VERDICT: STILL PROGRESSING at the timeout (%s bytes, last write %ss ago).%s' "$last_size" "$stalled_for" "$NL" >&2
        printf '           This is a timeout that is too short, not a broken image.%s' "$NL" >&2
        printf '           Re-run with a larger --timeout.%s%s' "$NL" "$NL" >&2
    fi

    printf '  accel     : %s%s' "$accel" "$NL" >&2
    printf '  serial log: %s (%s bytes, kept as a CI artifact)%s%s' "$serial_log" "$last_size" "$NL" "$NL" >&2
    printf '  Full serial output follows.%s%s' "$NL" "$NL" >&2
    sed 's/^/    /' -- "$serial_log" 2>/dev/null >&2 || true
    printf '%s' "$NL" >&2
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

# --timeout is PER FIRMWARE. Saying so out loud, because "--mode both --timeout 2400"
# quietly meant an eighty minute worst case in CI, which is how run #9 was allowed to
# run for two hours before anyone stopped it.
info "budget: ${#MODES[@]} boot(s) x ${TIMEOUT}s = $(( ${#MODES[@]} * TIMEOUT ))s worst case"

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
printf '  accel:   %s\n' "${ACCEL_USED:-unknown}"
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
