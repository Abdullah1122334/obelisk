#!/usr/bin/env python3
"""Generate every Obelisk surface from design/tokens.yaml.

Nothing in this repository hand-writes a colour, a font size, a radius or a duration.
This script is the only writer. If a surface does not change when a token changes, that
surface is hand-written and it is a bug.

It also enforces two policies that a palette can violate while still looking fine:

  * WCAG 2.2 AA contrast for every foreground/background role pair, with a named and
    justified exemption list rather than silent omissions.

  * The affordance/identity separation from design/brand-guidelines.md: interactive
    roles may never resolve to electrum, and identity roles may never resolve to lapis.
    A rule nothing enforces is a comment.

Exit status: 0 generated, 1 policy violation, 2 usage or environment error.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("generate.py: error: PyYAML is required (pacman -S python-yaml)")

REPO_ROOT = Path(__file__).resolve().parent.parent
TOKENS = REPO_ROOT / "design" / "tokens.yaml"


# ---------------------------------------------------------------------------
# Token resolution
# ---------------------------------------------------------------------------
class Tokens:
    """Loads tokens.yaml and resolves {group.step} references."""

    def __init__(self, path: Path) -> None:
        self.path = path
        with path.open(encoding="utf-8") as fh:
            self.data = yaml.safe_load(fh)
        self.palette = self.data["palette"]

    def resolve(self, value: str) -> str:
        """Follow {group.step} references to a literal hex colour."""
        seen = set()
        while isinstance(value, str) and value.startswith("{"):
            if value in seen:
                raise ValueError(f"circular token reference: {value}")
            seen.add(value)
            group, step = value.strip("{}").split(".")
            table = self.palette[group]
            key = int(step) if step.isdigit() else step
            if key not in table:
                raise KeyError(f"{value} does not exist in tokens.yaml")
            value = table[key]
        if not (isinstance(value, str) and value.startswith("#")):
            raise ValueError(f"token did not resolve to a colour: {value!r}")
        return value.upper()

    def origin(self, role_value: str) -> str:
        """Which palette group a role points at, or 'literal' for a raw hex value."""
        if isinstance(role_value, str) and role_value.startswith("{"):
            return role_value.strip("{}").split(".")[0]
        return "literal"

    def theme(self, name: str) -> dict:
        return self.data["themes"][name]


# ---------------------------------------------------------------------------
# Contrast
# ---------------------------------------------------------------------------
def _linear(channel: int) -> float:
    c = channel / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(hex_colour: str) -> float:
    h = hex_colour.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * _linear(r) + 0.7152 * _linear(g) + 0.0722 * _linear(b)


def contrast(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# ---------------------------------------------------------------------------
# Policy: the affordance / identity separation
# ---------------------------------------------------------------------------
# From design/brand-guidelines.md. Roles are classified, and a role in NEITHER list is a
# failure rather than a default-permit -- an unclassified role is exactly where the rule
# erodes first.
#
# The check is symmetric on purpose. Gold drifting onto buttons and blue drifting onto
# the logo are the same mistake in opposite directions; checking only one direction lets
# the palette rot from the other side.

INTERACTIVE_ROLES = {
    "primary", "on_primary", "selection_bg", "selection_fg", "secondary",
}
IDENTITY_ROLES = {
    "accent", "accent_solid", "on_accent", "focus_ring",
}
NEUTRAL_ROLES = {
    "background", "surface", "surface_raised",
    "text_primary", "text_secondary", "text_muted", "text_disabled",
    "border_subtle", "border_strong", "focus_ring_offset_color",
}

INTERACTIVE_ALLOWED = {"lapis", "patina", "granite", "semantic", "literal"}
IDENTITY_ALLOWED = {"electrum", "granite", "literal"}
NEUTRAL_ALLOWED = {"granite", "literal"}


def check_role_policy(tokens: Tokens) -> list[str]:
    """Return a list of violations. Empty means the palette obeys the rule."""
    violations: list[str] = []

    for theme_name in ("dark", "light"):
        theme = tokens.theme(theme_name)
        for role, value in theme.items():
            group = tokens.origin(value)

            if role in INTERACTIVE_ROLES:
                allowed, kind = INTERACTIVE_ALLOWED, "interactive"
            elif role in IDENTITY_ROLES:
                allowed, kind = IDENTITY_ALLOWED, "identity"
            elif role in NEUTRAL_ROLES:
                allowed, kind = NEUTRAL_ALLOWED, "neutral"
            else:
                violations.append(
                    f"{theme_name}.{role} is not classified in generate.py. "
                    f"Add it to INTERACTIVE_ROLES, IDENTITY_ROLES or NEUTRAL_ROLES and "
                    f"record the decision in design/brand-guidelines.md. An unclassified "
                    f"role is not permitted by default."
                )
                continue

            if group not in allowed:
                if kind == "interactive" and group == "electrum":
                    why = ("electrum is the identity colour and must never mark something "
                           "the user can act on. Use lapis.")
                elif kind == "identity" and group == "lapis":
                    why = ("lapis is the affordance colour and must never carry brand "
                           "identity or framing. Use electrum.")
                else:
                    why = f"a {kind} role may only use: {', '.join(sorted(allowed))}."
                violations.append(f"{theme_name}.{role} -> {group}: {why}")

    return violations


# ---------------------------------------------------------------------------
# Contrast policy
# ---------------------------------------------------------------------------
# (foreground role, background role, required ratio, description)
PAIRS = [
    ("text_primary", "background", 4.5, "body text"),
    ("text_primary", "surface", 4.5, "body text on a card"),
    ("text_secondary", "background", 4.5, "secondary text"),
    ("text_secondary", "surface", 4.5, "secondary text on a card"),
    ("text_muted", "background", 4.5, "muted but meaningful text"),
    ("text_muted", "surface", 4.5, "muted text on a card"),
    ("primary", "background", 4.5, "link and interactive text"),
    ("primary", "surface", 4.5, "link on a card"),
    ("accent", "background", 4.5, "accent text"),
    ("accent", "surface", 4.5, "accent text on a card"),
    ("secondary", "background", 4.5, "secondary emphasis"),
    ("on_primary", "primary", 4.5, "label on a primary button"),
    ("on_accent", "accent_solid", 4.5, "label on a solid accent fill"),
    ("selection_fg", "selection_bg", 4.5, "selected text"),
    ("border_strong", "background", 3.0, "input outline (WCAG 1.4.11)"),
    ("border_strong", "surface", 3.0, "input outline on a card"),
    ("focus_ring", "background", 3.0, "focus ring against the background"),
    ("focus_ring", "surface", 3.0, "focus ring against a card"),
]

SEMANTIC = ["success", "warning", "danger"]

# Named, justified, and PUBLISHED. Anything omitted from the report without appearing
# here would let "zero failures" quietly mean "we did not look".
EXEMPTIONS = [
    ("text_disabled", "background", "WCAG 2.2, 1.4.3 Contrast (Minimum)",
     "Incidental text: part of an inactive user interface component, which the success "
     "criterion explicitly excludes. Deliberately low so that disabled genuinely reads "
     "as disabled rather than as merely quiet."),
    ("border_subtle", "background", "WCAG 2.2, 1.4.11 Non-text Contrast",
     "A decorative separator that conveys no state and is not a control boundary. "
     "Boundaries that DO convey state use border_strong, which is checked at 3:1."),
]


def evaluate_contrast(tokens: Tokens):
    """Return (rows, failures). rows are tuples ready for the report."""
    rows, failures = [], []
    for theme_name in ("dark", "light"):
        theme = tokens.theme(theme_name)
        for fg, bg, need, note in PAIRS:
            f, b = tokens.resolve(theme[fg]), tokens.resolve(theme[bg])
            ratio = contrast(f, b)
            ok = ratio >= need
            rows.append((theme_name, f"{fg} / {bg}", f, b, ratio, need, ok, note))
            if not ok:
                failures.append(
                    f"{theme_name}: {fg} on {bg} is {ratio:.2f}:1, needs {need}:1 "
                    f"({f} on {b})"
                )
        key = "on_dark" if theme_name == "dark" else "on_light"
        for name in SEMANTIC:
            f = tokens.resolve(tokens.palette["semantic"][name][key])
            b = tokens.resolve(theme["background"])
            ratio = contrast(f, b)
            ok = ratio >= 4.5
            rows.append((theme_name, f"{name} / background", f, b, ratio, 4.5, ok,
                         "semantic colour"))
            if not ok:
                failures.append(
                    f"{theme_name}: {name} on background is {ratio:.2f}:1, needs 4.5:1"
                )
    return rows, failures


def write_contrast_report(tokens: Tokens, rows, out_path: Path) -> None:
    lines = [
        "# Obelisk — measured contrast",
        "",
        "> Generated by `design/generate.py` from `design/tokens.yaml`. Do not edit.",
        "> Every number here is computed from the tokens, never asserted by hand.",
        "",
        "Standard: **WCAG 2.2 AA**. Body text 4.5:1, large text 3:1, user interface "
        "components and focus indicators 3:1 (1.4.11).",
        "",
    ]

    total = len(rows)
    passing = sum(1 for r in rows if r[6])
    aaa = sum(1 for r in rows if r[5] >= 4.5 and r[4] >= 7.0)
    worst = min((r for r in rows if r[5] >= 4.5), key=lambda r: r[4])

    lines += [
        "## Summary",
        "",
        f"- **{total} role pairs checked**, {passing} passing, {total - passing} failing.",
        f"- {aaa} pairs reach AAA (7:1 or better).",
        f"- Worst passing text pair: `{worst[1]}` in the {worst[0]} theme at "
        f"**{worst[4]:.2f}:1**.",
        "",
        "This summary covers the pairs listed below and **nothing else**. The exemptions "
        "in the next section are excluded from it by design, and are stated in full so "
        "that \"zero failures\" cannot be read as \"everything was checked\".",
        "",
    ]

    lines += ["## Exemptions", "",
              "These pairs are deliberately not required to meet a ratio. Each names the "
              "clause that permits it and why it applies here. They are excluded from "
              "the counts above.",
              ""]
    for fg, bg, clause, reason in EXEMPTIONS:
        lines.append(f"### `{fg}` on `{bg}`")
        lines.append("")
        lines.append(f"**Clause:** {clause}")
        lines.append("")
        lines.append(f"**Reason:** {reason}")
        lines.append("")
        for theme_name in ("dark", "light"):
            theme = tokens.theme(theme_name)
            f, b = tokens.resolve(theme[fg]), tokens.resolve(theme[bg])
            lines.append(f"- {theme_name}: `{f}` on `{b}` — measured "
                         f"{contrast(f, b):.2f}:1 (not required to pass)")
        lines.append("")

    for theme_name in ("dark", "light"):
        lines += [f"## {theme_name.capitalize()} theme", "",
                  "| role pair | foreground | background | ratio | required | result | note |",
                  "|---|---|---|---|---|---|---|"]
        for t, pair, f, b, ratio, need, ok, note in rows:
            if t != theme_name:
                continue
            if not ok:
                verdict = "**FAIL**"
            elif need >= 4.5 and ratio >= 7.0:
                verdict = "AAA"
            else:
                verdict = "pass"
            lines.append(f"| `{pair}` | `{f}` | `{b}` | {ratio:.2f}:1 | {need} | "
                         f"{verdict} | {note} |")
        lines.append("")

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate Obelisk surfaces from design/tokens.yaml")
    parser.add_argument("--check", action="store_true",
                        help="run the policies and report, but write nothing")
    parser.add_argument("--tokens", type=Path, default=TOKENS)
    args = parser.parse_args()

    if not args.tokens.is_file():
        print(f"generate.py: error: no tokens file at {args.tokens}", file=sys.stderr)
        return 2

    try:
        tokens = Tokens(args.tokens)
    except (ValueError, KeyError, yaml.YAMLError) as exc:
        print(f"generate.py: error: cannot load {args.tokens}: {exc}", file=sys.stderr)
        return 2

    failed = False

    # Policy 1: affordance / identity separation.
    violations = check_role_policy(tokens)
    if violations:
        failed = True
        print("\ngenerate.py: error: colour role policy violated\n", file=sys.stderr)
        for v in violations:
            print(f"  {v}", file=sys.stderr)
        print("\n  The rule is stated in design/brand-guidelines.md under"
              "\n  'The rule as machine-checkable policy'. It is not advisory.\n",
              file=sys.stderr)
    else:
        print(f"role policy: OK — "
              f"{len(INTERACTIVE_ROLES)} interactive, {len(IDENTITY_ROLES)} identity, "
              f"{len(NEUTRAL_ROLES)} neutral roles classified, no crossings")

    # Policy 2: contrast.
    rows, contrast_failures = evaluate_contrast(tokens)
    if contrast_failures:
        failed = True
        print("\ngenerate.py: error: contrast policy violated\n", file=sys.stderr)
        for f in contrast_failures:
            print(f"  {f}", file=sys.stderr)
        print("\n  Fix the token, or add a justified entry to EXEMPTIONS with the WCAG"
              "\n  clause that permits it. Do not lower the requirement.\n",
              file=sys.stderr)
    else:
        aaa = sum(1 for r in rows if r[5] >= 4.5 and r[4] >= 7.0)
        worst = min((r for r in rows if r[5] >= 4.5), key=lambda r: r[4])
        print(f"contrast:    OK — {len(rows)} pairs, 0 failures, {aaa} at AAA, "
              f"worst {worst[4]:.2f}:1 ({worst[1]}, {worst[0]})")
        print(f"exemptions:  {len(EXEMPTIONS)} named and published in the report")

    if failed:
        return 1

    if args.check:
        print("check only: nothing written")
        return 0

    report = REPO_ROOT / "docs" / "DESIGN-CONTRAST.md"
    write_contrast_report(tokens, rows, report)
    print(f"wrote {report.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
