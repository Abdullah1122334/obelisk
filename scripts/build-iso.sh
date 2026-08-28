#!/usr/bin/env bash
#
# Obelisk — ISO builder.
#
# Runs on an Arch Linux host (or an archlinux:latest container) with root privileges
# and working loop devices. It cannot run on the maintainer's Windows machine; that is
# expected and is why GitHub Actions is the reference build path. See docs/BUILDING.md
# and docs/BUILDING-ON-WINDOWS.md.
#
# What this script does that a bare mkarchiso invocation does not:
#
#   1. Verifies our bootmodes against the boot modes the INSTALLED mkarchiso actually
#      implements, instead of trusting documentation.
#   2. Assembles the build profile by taking the installed releng profile as a base for
#      boot loader configuration only, rebranding it, and overlaying ours on top — then
#      writing a manifest of exactly which files came from where.
#   3. Injects the local Obelisk package repository when one exists, and proceeds
#      without it when it does not, so the very first ISO can be built before anything
#      has ever been published.
#   4. Enforces the ISO size ceiling as a build failure rather than a warning.
#
# Exit status: 0 success, 1 build or policy failure, 2 usage or environment error.

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
readonly REPO_ROOT

die()  { printf '\n%s: error: %s\n\n' "$SCRIPT_NAME" "$1" >&2; exit "${2:-2}"; }
info() { printf '[%s] %s\n' "$SCRIPT_NAME" "$1"; }
warn() { printf '[%s] warning: %s\n' "$SCRIPT_NAME" "$1" >&2; }

# Under `set -e` a non-zero return terminates this script with NO output at all. That
# turns a one-line bug into a blind investigation, so every abort explains itself. This
# trap is the backstop for any failure that slips past an explicit guard.
on_err() {
    local exit_code=$? line=$1 cmd=$2
    printf '\n%s: FAILED\n' "$SCRIPT_NAME" >&2
    printf '  exit code : %s\n' "$exit_code" >&2
    printf '  line      : %s\n' "$line" >&2
    printf '  command   : %s\n' "$cmd" >&2
    printf '  function  : %s\n' "${FUNCNAME[1]:-main}" >&2
    printf '\n  If this message is the only diagnostic, the failing command wrote nothing\n  to stderr. That is a bug in this script, not in your environment.\n\n' >&2
    exit "$exit_code"
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

usage() {
    cat <<'USAGE'
Usage: sudo ./scripts/build-iso.sh [OPTIONS]

Options:
  -o, --out DIR     output directory for the ISO      (default: out)
  -w, --work DIR    scratch build directory           (default: work)
  -k, --keep-work   do not delete the work directory on success
  -n, --dry-run     assemble and validate the profile, then stop before mkarchiso
  -h, --help        this message

Reads config.env if present. See config.env.example for every variable.
USAGE
}

OUT_DIR="out"
WORK_DIR="work"
KEEP_WORK=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--out)       OUT_DIR="${2:?--out requires a directory}"; shift 2 ;;
        -w|--work)      WORK_DIR="${2:?--work requires a directory}"; shift 2 ;;
        -k|--keep-work) KEEP_WORK=1; shift ;;
        -n|--dry-run)   DRY_RUN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "unknown option: $1" ;;
    esac
done

cd -- "$REPO_ROOT" || die "cannot enter repository root: $REPO_ROOT"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
if [[ -f config.env ]]; then
    info "loading config.env"
    # shellcheck disable=SC1091
    set -a; . ./config.env; set +a
else
    info "no config.env found — using documented defaults (see config.env.example)"
fi

: "${OBELISK_ARCHIVE_DATE:=}"
: "${OBELISK_LOCAL_REPO:=out/repo}"
: "${OBELISK_MAX_ISO_MIB:=3584}"

[[ -n "$OBELISK_ARCHIVE_DATE" ]] || die \
"OBELISK_ARCHIVE_DATE is not set.

  Obelisk pins Arch to a dated Arch Linux Archive snapshot; without a date there is no
  mirror to build from. Copy config.env.example to config.env and set it, for example:

      OBELISK_ARCHIVE_DATE=2026/08/14

  Choose a date 7 to 14 days in the past (decision D2, docs/ARCHITECTURE.md)."

[[ "$OBELISK_ARCHIVE_DATE" =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]] || die \
"OBELISK_ARCHIVE_DATE must be formatted YYYY/MM/DD, got: ${OBELISK_ARCHIVE_DATE}"

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die \
"must run as root.

  mkarchiso needs to create device nodes and mount loop devices. Re-run with:

      sudo ./scripts/build-iso.sh"

command -v mkarchiso >/dev/null 2>&1 || die \
"mkarchiso not found.

  This host is not set up to build an Arch ISO. Install the tooling with:

      pacman -S --needed archiso

  If you are on Windows, this script cannot run here at all — that is by design.
  Use GitHub Actions, or an Arch VM. See docs/BUILDING-ON-WINDOWS.md."

for tool in pacman rsync sed find du awk; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found in PATH: $tool"
done

readonly RELENG_BASE="/usr/share/archiso/configs/releng"
[[ -d "$RELENG_BASE" ]] || die \
"the archiso releng profile is missing at ${RELENG_BASE}.

  Obelisk inherits boot loader configuration from it. Reinstall the archiso package."

ARCHISO_VERSION="$(pacman -Q archiso 2>/dev/null | awk '{print $2}' || echo unknown)"
readonly ARCHISO_VERSION
info "archiso ${ARCHISO_VERSION}"

# ---------------------------------------------------------------------------
# Verify bootmodes against what mkarchiso actually implements
# ---------------------------------------------------------------------------
# Documentation, the ArchWiki, and the GitHub mirror disagree about the valid bootmode
# strings, and they have changed across archiso releases. Rather than trust any of them,
# read the truth out of the installed mkarchiso.
#
# HISTORY, so this is not reintroduced: the first version of this function sourced
# profiledef.sh with `>/dev/null 2>&1`. profiledef.sh could not be sourced standalone
# because file_permissions is an associative array literal with no `declare -A`, so the
# source failed, the redirect swallowed the error, and the function silently compared
# against an EMPTY list -- it verified nothing for its entire existence, while errexit
# killed the whole script with no output at all. Two rules came out of that:
#   1. never redirect the stderr of something whose failure can abort the run;
#   2. print what a check found even when it passes, so one run answers the question.

read_declared_bootmodes() {
    # Prints the declared bootmodes, one per line. Returns non-zero on failure and
    # writes the reason to stderr.
    #
    # NOTE: this runs in the caller's shell via command substitution, which is itself a
    # subshell -- so this function must RETURN a status rather than call die(). An exit
    # inside a subshell cannot abort the parent, and an earlier version of this code got
    # that wrong: it printed an error and then carried on regardless.
    local err rc=0
    err="$(
        set +u
        declare -A file_permissions
        # shellcheck source=../iso/profiledef.sh
        . "${REPO_ROOT}/iso/profiledef.sh" 2>&1 >/dev/null
    )" || rc=$?

    if [[ $rc -ne 0 ]]; then
        printf 'source failed with exit %s
' "$rc" >&2
        printf '%s
' "${err:-(the source wrote nothing to stderr, which is itself a bug)}" >&2
        return "$rc"
    fi

    (
        set +u
        declare -A file_permissions
        # shellcheck source=../iso/profiledef.sh
        . "${REPO_ROOT}/iso/profiledef.sh" >/dev/null
        printf '%s
' "${bootmodes[@]}"
    )
}

detect_supported_bootmodes() {
    # Several strategies, because we do not know which one archiso 89 satisfies. Each
    # reports what it found so a single CI run answers the question for good.
    local mkarchiso_path="$1"
    local -a found=()

    mapfile -t found < <(
        grep -oE '^[[:space:]]*_make_bootmode_[A-Za-z0-9._-]+[[:space:]]*\(\)' "$mkarchiso_path" 2>/dev/null \
            | sed -E 's/^[[:space:]]*_make_bootmode_//; s/[[:space:]]*\(\)$//' | sort -u
    )
    if [[ ${#found[@]} -gt 0 ]]; then
        printf 'function-definitions\t%s\n' "${found[*]}"
        return 0
    fi

    mapfile -t found < <(
        grep -oE '_make_bootmode_[A-Za-z0-9._-]+' "$mkarchiso_path" 2>/dev/null \
            | sed -E 's/^_make_bootmode_//' | sort -u
    )
    if [[ ${#found[@]} -gt 0 ]]; then
        printf 'function-references\t%s\n' "${found[*]}"
        return 0
    fi

    # Last resort: whatever the installed releng profile declares is, by definition,
    # supported by the mkarchiso shipped alongside it.
    if [[ -f "${RELENG_BASE}/profiledef.sh" ]]; then
        mapfile -t found < <(
            sed -n '/^bootmodes=(/,/)/p' "${RELENG_BASE}/profiledef.sh" \
                | grep -oE "'[^']+'" | tr -d "'" | sort -u
        )
        if [[ ${#found[@]} -gt 0 ]]; then
            printf 'releng-profile\t%s\n' "${found[*]}"
            return 0
        fi
    fi

    printf 'none\t\n'
    return 0
}

verify_bootmodes() {
    local mkarchiso_path detection method supported_str
    local -a supported=() declared=() missing=()

    mkarchiso_path="$(command -v mkarchiso)"
    info "mkarchiso: ${mkarchiso_path}"

    local declared_raw
    if ! declared_raw="$(read_declared_bootmodes)"; then
        die "cannot read bootmodes from iso/profiledef.sh.

  The reason is printed immediately above this message. This file must be sourceable on
  its own, because this script and the lint suite both read it. Note that 'bash -n' will
  NOT catch the usual cause: an associative array literal such as file_permissions needs
  a prior 'declare -A', or bash evaluates the subscript as arithmetic." 1
    fi

    # Blank lines are stripped deliberately. printf on an unset array emits one empty
    # line, which an earlier version counted as a valid bootmode -- so the emptiness
    # check passed while verifying nothing at all.
    mapfile -t declared < <(printf '%s
' "$declared_raw" | sed '/^[[:space:]]*$/d')

    if [[ ${#declared[@]} -eq 0 ]]; then
        die "iso/profiledef.sh sourced cleanly but declared no bootmodes.

  The bootmodes array is empty or missing. Without it mkarchiso produces a medium that
  cannot boot on any firmware." 1
    fi
    info "bootmodes declared in iso/profiledef.sh: ${declared[*]}"

    detection="$(detect_supported_bootmodes "$mkarchiso_path")"
    method="${detection%%$'\t'*}"
    supported_str="${detection#*$'\t'}"
    read -r -a supported <<< "$supported_str"

    # Printed unconditionally. A passing run must still answer "what does this archiso
    # actually support", because that is the question that cost us a CI cycle.
    info "bootmode detection method: ${method}"
    if [[ ${#supported[@]} -gt 0 ]]; then
        info "bootmodes supported by archiso ${ARCHISO_VERSION}: ${supported[*]}"
    fi

    if [[ "$method" == none || ${#supported[@]} -eq 0 ]]; then
        warn "could not determine the supported bootmodes from ${mkarchiso_path}"
        warn "or from ${RELENG_BASE}/profiledef.sh."
        warn "proceeding: mkarchiso itself will reject an invalid mode with its own error."
        return 0
    fi

    local mode
    for mode in "${declared[@]}"; do
        [[ -n "$mode" ]] || continue
        if ! printf '%s\n' "${supported[@]}" | grep -qxF -- "$mode"; then
            missing+=("$mode")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        printf '\n%s: error: unsupported bootmode(s) in iso/profiledef.sh\n\n' "$SCRIPT_NAME" >&2
        printf '  declared but unsupported : %s\n' "${missing[*]}" >&2
        printf '  declared (all)           : %s\n' "${declared[*]}" >&2
        printf '  supported by archiso %-4s: %s\n' "$ARCHISO_VERSION" "${supported[*]}" >&2
        printf '  detected via             : %s\n' "$method" >&2
        printf '\n  Update bootmodes in iso/profiledef.sh to values from the supported list.\n' >&2
        printf '  Obelisk needs GRUB for UEFI so that grub-btrfs can publish snapshots as\n' >&2
        printf '  boot entries (Phase 6); pick the GRUB-based UEFI mode, not systemd-boot.\n' >&2
        printf '  If the boot chain has to change, record it in docs/ARCHITECTURE.md.\n\n' >&2
        exit 1
    fi

    info "bootmodes verified: all declared modes are supported"
}
verify_bootmodes

# ---------------------------------------------------------------------------
# Assemble the build profile
# ---------------------------------------------------------------------------
# Layer 1: the installed releng profile, for boot loader configuration only. We take it
#          from the installed package rather than vendoring a copy, so it always matches
#          the archiso version doing the build.
# Layer 2: rebranding of the inherited files.
# Layer 3: our iso/ directory, which wins every conflict.
#
# A manifest records which files survived from upstream, so inherited configuration is
# visible in review instead of invisible. Phase 2 replaces these inherited boot loader
# files with configuration generated from design/tokens.yaml, at which point this base
# layer shrinks to nothing.

readonly PROFILE_DIR="${WORK_DIR}/profile"
readonly MANIFEST="${OUT_DIR}/profile-manifest.txt"

info "assembling build profile in ${PROFILE_DIR}"
rm -rf -- "$PROFILE_DIR"
mkdir -p -- "$PROFILE_DIR" "$OUT_DIR"

# Layer 1 — boot loader configuration only. We deliberately do NOT inherit releng's
# airootfs: it carries Arch branding, an Arch installation guide, and a mirror chooser,
# all of which docs/LEGAL.md requires us not to ship.
for d in efiboot syslinux grub; do
    if [[ -d "${RELENG_BASE}/${d}" ]]; then
        cp -r -- "${RELENG_BASE}/${d}" "${PROFILE_DIR}/"
        info "inherited ${d}/ from releng"
    else
        info "releng has no ${d}/ — skipping"
    fi
done

: > "$MANIFEST"
{
    printf '# Obelisk build profile manifest\n'
    printf '# archiso: %s\n' "$ARCHISO_VERSION"
    printf '# generated: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '## inherited from %s\n' "$RELENG_BASE"
} >> "$MANIFEST"
if [[ -n "$(ls -A "$PROFILE_DIR" 2>/dev/null)" ]]; then
    find "$PROFILE_DIR" -type f -printf '%P\n' | sort >> "$MANIFEST"
fi

# Layer 2 — rebranding. Phase 1 inherits Arch's boot loader menus to get a booting ISO
# without guessing at mkarchiso's placeholder syntax, so every user-visible Arch string
# in them must be replaced. Phase 11's branding scan is the backstop that proves none
# survived anywhere in the image.
info "rebranding inherited boot loader configuration"
while IFS= read -r -d '' f; do
    sed -i \
        -e 's/Arch Linux/Obelisk/g' \
        -e 's/archlinux/obelisk/g' \
        -e 's/ARCH_/OBELISK_/g' \
        -- "$f"
done < <(find "$PROFILE_DIR" -type f \
            \( -name '*.cfg' -o -name '*.conf' -o -name '*.txt' \) -print0)

# Layer 3 — ours, and ours wins.
info "overlaying iso/"
rsync -a --exclude='.gitkeep' -- "${REPO_ROOT}/iso/" "${PROFILE_DIR}/"

{
    printf '\n## provided by obelisk (iso/, overrides the above)\n'
    find "${REPO_ROOT}/iso" -type f -printf '%P\n' | sort
} >> "$MANIFEST"
info "profile manifest written to ${MANIFEST}"

# ---------------------------------------------------------------------------
# Pin the Arch snapshot date
# ---------------------------------------------------------------------------
info "pinning Arch repositories to archive snapshot ${OBELISK_ARCHIVE_DATE}"
for f in "${PROFILE_DIR}/pacman.conf" "${PROFILE_DIR}/airootfs/etc/pacman.conf"; do
    [[ -f "$f" ]] || die "expected file missing from assembled profile: $f"
    sed -i "s|@ARCHIVE_DATE_PATH@|${OBELISK_ARCHIVE_DATE}|g" -- "$f"
    if grep -q '@ARCHIVE_DATE_PATH@' "$f"; then
        die "failed to substitute the archive date in $f"
    fi
done

# Fail early and clearly if the pinned snapshot does not exist, rather than letting
# pacman fail deep inside mkarchiso with a less obvious message.
readonly ARCHIVE_PROBE="https://archive.archlinux.org/repos/${OBELISK_ARCHIVE_DATE}/core/os/x86_64/core.db"
if command -v curl >/dev/null 2>&1; then
    if ! curl -sfI --max-time 30 -- "$ARCHIVE_PROBE" >/dev/null; then
        die \
"the pinned Arch Linux Archive snapshot is not reachable:

  ${ARCHIVE_PROBE}

  Either the date does not exist in the archive, or the network is unavailable.
  Pick a different OBELISK_ARCHIVE_DATE (7-14 days in the past) and try again." 1
    fi
    info "archive snapshot reachable"
else
    warn "curl not available — skipping archive reachability probe"
fi

# ---------------------------------------------------------------------------
# Bootstrap ordering: inject the local Obelisk repository if one exists
# ---------------------------------------------------------------------------
# This is what resolves the chicken-and-egg problem. Obelisk needs packages that Arch
# does not carry — Calamares above all — but those packages come from a repository that
# does not exist until we have built it.
#
# The rule: the ISO build NEVER requires a published repository. If
# repo/build-packages.sh has produced a local repository, it is added here as the LAST
# entry so it can never shadow Arch. If it has not, the build proceeds from Arch alone
# and simply produces an ISO without our packages. A completely empty checkout on a
# machine that has never seen this project must be able to build.
inject_local_repo() {
    local repo_dir="${OBELISK_LOCAL_REPO}"
    [[ "$repo_dir" = /* ]] || repo_dir="${REPO_ROOT}/${repo_dir}"

    if [[ ! -f "${repo_dir}/obelisk.db" ]]; then
        info "no local package repository at ${repo_dir} — building from Arch alone"
        info "(this is the expected state during bootstrap; see docs/BUILDING.md)"
        return 0
    fi

    local count
    count="$(find "$repo_dir" -name '*.pkg.tar.*' -not -name '*.sig' | wc -l)"
    info "local package repository found: ${count} package(s) in ${repo_dir}"

    # Appended LAST, after [core], [extra] and [multilib], so an Obelisk package can
    # never take precedence over an upstream one. Unsigned during bootstrap: the
    # database is only signed once obelisk-keyring exists in Phase 10.
    cat >> "${PROFILE_DIR}/pacman.conf" <<REPOEOF

[obelisk]
SigLevel = Optional TrustAll
Server = file://${repo_dir}
REPOEOF
    info "injected [obelisk] as the last repository in the build-time pacman.conf"
}
inject_local_repo

if [[ $DRY_RUN -eq 1 ]]; then
    info "dry run: profile assembled and validated, stopping before mkarchiso"
    info "profile is at ${PROFILE_DIR}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
readonly MKARCHISO_WORK="${WORK_DIR}/mkarchiso"
mkdir -p -- "$MKARCHISO_WORK" "$OUT_DIR"

# Report free space before starting. An ISO build that dies from ENOSPC halfway through
# leaves a confusing mess, and CI runners are tight enough that this is a real risk.
AVAIL_MIB="$(df -Pm -- "$WORK_DIR" | awk 'NR==2 {print $4}')"
info "free space on the work filesystem: ${AVAIL_MIB} MiB"
if [[ "$AVAIL_MIB" -lt 12000 ]]; then
    warn "less than 12 GiB free; an ISO build may fail with ENOSPC."
    warn "on a GitHub runner, free space first — see .github/workflows/build-iso.yml"
fi

info "running mkarchiso (this takes a while)"
if ! mkarchiso -v -w "$MKARCHISO_WORK" -o "$OUT_DIR" -- "$PROFILE_DIR"; then
    die \
"mkarchiso failed.

  Its own output above is the authoritative error. Common causes:
    - no loop devices available   (the container needs --privileged)
    - out of disk space           (free space was ${AVAIL_MIB} MiB at start)
    - a package name in iso/packages.x86_64 does not exist in the pinned snapshot

  The assembled profile is preserved at ${PROFILE_DIR} for inspection." 1
fi

# ---------------------------------------------------------------------------
# Verify the artifact and enforce the size ceiling
# ---------------------------------------------------------------------------
ISO_PATH="$(find "$OUT_DIR" -maxdepth 1 -name '*.iso' -newer "$PROFILE_DIR" -print -quit)"
[[ -n "$ISO_PATH" ]] || ISO_PATH="$(find "$OUT_DIR" -maxdepth 1 -name '*.iso' -print -quit)"
[[ -n "$ISO_PATH" && -f "$ISO_PATH" ]] || die "mkarchiso reported success but no ISO was produced in ${OUT_DIR}" 1

ISO_MIB="$(( $(stat -c '%s' -- "$ISO_PATH") / 1024 / 1024 ))"
info "built: ${ISO_PATH} (${ISO_MIB} MiB)"

info "writing checksum"
( cd -- "$(dirname -- "$ISO_PATH")" && sha256sum -- "$(basename -- "$ISO_PATH")" > "$(basename -- "$ISO_PATH").sha256" )

if [[ "$ISO_MIB" -gt "$OBELISK_MAX_ISO_MIB" ]]; then
    die \
"ISO size ceiling exceeded: ${ISO_MIB} MiB > ${OBELISK_MAX_ISO_MIB} MiB.

  This is a gate, not a warning (docs/ARCHITECTURE.md section 10). The correct response
  is to decide what to remove from iso/packages.x86_64, not to raise the ceiling.
  Record the decision in docs/PERFORMANCE.md." 1
fi
info "size within ceiling (${ISO_MIB} / ${OBELISK_MAX_ISO_MIB} MiB)"

if [[ $KEEP_WORK -eq 0 ]]; then
    info "removing work directory (use --keep-work to preserve it)"
    rm -rf -- "$MKARCHISO_WORK"
fi

printf '\n[%s] SUCCESS\n  ISO:      %s\n  Size:     %s MiB\n  Checksum: %s.sha256\n  Manifest: %s\n\n' \
    "$SCRIPT_NAME" "$ISO_PATH" "$ISO_MIB" "$ISO_PATH" "$MANIFEST"
