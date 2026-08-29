#!/usr/bin/env bash
#
# Obelisk — reject a shell function defined more than once in the same file.
#
# CI run #11 failed on a function this project had accidentally defined twice, after a
# refactor duplicated a fifty-line block. Both copies were identical, so the script still
# behaved correctly and nothing else noticed.
#
# It was caught only by accident: the shellcheck installed in CI happened to be an older
# build than the one used locally, and reported SC2218 where 0.11.0 reports nothing at
# all for that shape, even when the check is requested explicitly. A bug found because
# two machines disagreed is not a check. This looks for the defect directly, so it is
# found the same way every time, on every tracked script.
#
# Exit status: 0 clean, 1 duplicates found, 2 usage or environment error.

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"

die() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2; }

on_err() {
    local code=$? line=$1 cmd=$2
    printf '\n%s: FAILED  exit=%s line=%s cmd=%s\n\n' "$SCRIPT_NAME" "$code" "$line" "$cmd" >&2
    exit "$code"
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
readonly REPO_ROOT
cd -- "$REPO_ROOT" || die "cannot enter repository root: $REPO_ROOT"

declare -a FILES=()
if [[ $# -gt 0 ]]; then
    FILES=("$@")
elif command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files '*.sh')
else
    while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find . -name '*.sh' -type f -print0)
fi

[[ ${#FILES[@]} -gt 0 ]] || { printf '%s: no shell scripts to check\n' "$SCRIPT_NAME"; exit 0; }

status=0
checked=0

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue
    checked=$((checked + 1))

    # Top-level definitions only: `name() {` at column zero. Nested or indented helpers
    # are a different question and not what broke us.
    declare -a dupes=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && dupes+=("$name")
    done < <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' -- "$f" | sed 's/()$//' | sort | uniq -d)

    [[ ${#dupes[@]} -eq 0 ]] && continue

    status=1
    for name in "${dupes[@]}"; do
        local_lines="$(grep -nE "^${name}\(\)" -- "$f" | cut -d: -f1 | paste -sd, -)"
        printf '%s: %s is defined %s times, at lines %s\n' \
            "$f" "$name" "$(grep -cE "^${name}\(\)" -- "$f")" "$local_lines" >&2
    done
done

if [[ $status -eq 0 ]]; then
    printf '%s: OK — no duplicate function definitions in %d script(s)\n' "$SCRIPT_NAME" "$checked"
    exit 0
fi

cat >&2 <<'REMEDY'

Why this matters
  A function defined twice silently uses the last definition. If the copies ever drift,
  the behaviour changes with no diff at the call site, and some shellcheck versions do
  not report it at all. Delete the redundant copy.
REMEDY
exit 1
