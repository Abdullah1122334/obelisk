#!/usr/bin/env bash
#
# Obelisk — line-ending and encoding gate.
#
# Obelisk is developed on Windows and built on Linux. Windows text tooling can silently
# introduce CRLF line endings or a UTF-8 byte-order mark. Either one, in a shell script,
# makes the Linux kernel fail to locate the interpreter and report:
#
#     bad interpreter: No such file or directory
#
# which points at the interpreter rather than at the real cause. This script makes that
# class of failure impossible to commit. It is the first gate in CI and it has no
# dependencies beyond coreutils, grep, and (optionally) git.
#
# Exit status: 0 clean, 1 violations found, 2 usage or environment error.

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"

die() {
    printf '%s: error: %s\n' "$SCRIPT_NAME" "$1" >&2
    exit 2
}

usage() {
    cat <<'USAGE'
Usage: scripts/check-line-endings.sh [PATH ...]

Scans for CRLF line endings, lone CR line endings, and UTF-8 byte-order marks in
text files. With no PATH given, scans every file tracked by git, or every file under
the repository root if git is unavailable.

Exit status:
  0  clean
  1  violations found
  2  usage or environment error
USAGE
}

case "${1-}" in
    -h|--help) usage; exit 0 ;;
esac

command -v grep >/dev/null 2>&1 || die "grep not found in PATH"
command -v od   >/dev/null 2>&1 || die "od not found in PATH"

# Resolve the repository root without depending on git being present.
REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
readonly REPO_ROOT
cd -- "$REPO_ROOT" || die "cannot enter repository root: $REPO_ROOT"

# ---------------------------------------------------------------------------
# Build the file list.
# ---------------------------------------------------------------------------
declare -a FILES=()

if [[ $# -gt 0 ]]; then
    while IFS= read -r -d '' f; do
        FILES+=("$f")
    done < <(find "$@" -type f -print0)
elif command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    # Tracked files only: untracked build output is not our problem.
    while IFS= read -r -d '' f; do
        FILES+=("$f")
    done < <(git ls-files -z)
else
    while IFS= read -r -d '' f; do
        FILES+=("$f")
    done < <(find . -type f -not -path './.git/*' -print0)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    printf '%s: no files to check\n' "$SCRIPT_NAME"
    exit 0
fi

# ---------------------------------------------------------------------------
# Classification helpers.
# ---------------------------------------------------------------------------

# A file is binary if grep -I refuses to treat it as text. An empty file is text.
is_binary() {
    [[ -s "$1" ]] || return 1
    ! LC_ALL=C grep -IqU . -- "$1" 2>/dev/null
}

has_crlf() {
    LC_ALL=C grep -qU $'\r$' -- "$1" 2>/dev/null
}

# A CR that is not part of a CRLF pair: classic Mac endings, or a stray CR mid-line.
has_lone_cr() {
    LC_ALL=C grep -qU $'\r[^\n]' -- "$1" 2>/dev/null
}

has_bom() {
    [[ "$(od -An -N3 -tx1 -- "$1" 2>/dev/null | tr -d ' \n')" == 'efbbbf' ]]
}

# ---------------------------------------------------------------------------
# Scan.
# ---------------------------------------------------------------------------
declare -a CRLF_FILES=() CR_FILES=() BOM_FILES=()
scanned=0
skipped_binary=0

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue
    if is_binary "$f"; then
        skipped_binary=$((skipped_binary + 1))
        continue
    fi
    scanned=$((scanned + 1))

    if has_crlf "$f"; then
        CRLF_FILES+=("$f")
    elif has_lone_cr "$f"; then
        CR_FILES+=("$f")
    fi

    if has_bom "$f"; then
        BOM_FILES+=("$f")
    fi
done

violations=$(( ${#CRLF_FILES[@]} + ${#CR_FILES[@]} + ${#BOM_FILES[@]} ))

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------
if [[ $violations -eq 0 ]]; then
    printf '%s: OK — %d text files clean (%d binary files skipped)\n' \
        "$SCRIPT_NAME" "$scanned" "$skipped_binary"
    exit 0
fi

printf '\n%s: FAILED — %d file(s) would break on Linux\n\n' "$SCRIPT_NAME" "$violations" >&2

if [[ ${#CRLF_FILES[@]} -gt 0 ]]; then
    printf 'CRLF line endings (%d):\n' "${#CRLF_FILES[@]}" >&2
    printf '  %s\n' "${CRLF_FILES[@]}" >&2
    printf '\n' >&2
fi

if [[ ${#CR_FILES[@]} -gt 0 ]]; then
    printf 'Lone CR line endings (%d):\n' "${#CR_FILES[@]}" >&2
    printf '  %s\n' "${CR_FILES[@]}" >&2
    printf '\n' >&2
fi

if [[ ${#BOM_FILES[@]} -gt 0 ]]; then
    printf 'UTF-8 byte-order mark (%d):\n' "${#BOM_FILES[@]}" >&2
    printf '  %s\n' "${BOM_FILES[@]}" >&2
    printf '\n' >&2
fi

cat >&2 <<'REMEDY'
Why this matters
  A shell script whose first line ends in CRLF, or which begins with a UTF-8 BOM,
  makes the kernel look for an interpreter path that does not exist. The reported
  error names the interpreter, not the line ending, so this is expensive to debug:

      /usr/bin/env: 'bash\r': No such file or directory
      bad interpreter: No such file or directory

How to fix
  Strip carriage returns and BOMs from the listed files, then re-run this check:

      sed -i 's/\r$//' FILE            # remove CRLF
      sed -i '1s/^\xEF\xBB\xBF//' FILE # remove BOM

  Then confirm your Git configuration is not re-introducing them:

      git config --get core.autocrlf   # must be false or unset for this repository

  .gitattributes already pins every text type to eol=lf. If a file still arrives with
  CRLF, an editor wrote it that way after checkout. Configure the editor to use LF.
REMEDY

exit 1
