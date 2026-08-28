# Obelisk — Brand Guidelines

> Phase 1 scope: the colour-role rules, because they constrain everything built after
> them. Logo construction, wallpaper, iconography, and voice arrive in Phase 2.

## The object

An obelisk is cut from a single block of granite, tapered, and capped with a pyramidion
sheathed in electrum so it catches the sunrise before anything else does. It has stood
for three and a half thousand years.

Everything in the identity comes from that: **one stone, one form, no ornament.** The
gold is a single point at the top, not a finish applied all over. A design that spreads
gold across a surface has misunderstood the object.

## The colour-role rule

Obelisk has two colours that draw the eye — lapis and electrum — and a system with two
competing attention colours reads as noisy no matter how good the contrast numbers are.
The following rule is what keeps them from fighting. It is not a guideline.

### lapis is affordance

**If the user can act on it, it is lapis.** Links, buttons, selected rows, checked
checkboxes, slider handles and their filled track, active tabs, progress fill, toggles
in the on position, text selection.

Lapis is the colour of *this responds to you*.

### electrum is identity and framing, never affordance

**Electrum is never the colour of a thing the user acts on.** It is used for exactly
three purposes:

1. **Identity.** The logo, the pyramidion, the boot splash mark, brand moments in the
   installer and the welcome wizard.
2. **The focus indicator.** Drawn *around* a component, never as part of one.
3. **Attention that carries no affordance.** A "you are here" marker, a completion
   flourish, a decorative rule. Nothing clickable.

Electrum is the colour of *this is Obelisk* and *look here* — never *press this*.

### The two never colour the same component

A component gets its colour from lapis or from neutral granite. Electrum may frame that
component with a focus ring, or sit near it as brand furniture, but electrum and lapis
must never both be applied *within* one control. A gold-bordered blue button, a blue
button with a gold label, or a gold icon inside a blue chip are all violations.

### Why the focus ring is offset

The focus ring is electrum in both light and dark themes, because focus means the same
thing in both and a role that changes colour between themes is not a role.

But measured directly against the components it surrounds, electrum and lapis are almost
the same luminance:

| Pair | Contrast |
|---|---|
| `electrum-700` against `lapis-600` (light) | **1.06:1** |
| `electrum-400` against `lapis-400` (dark) | **1.55:1** |

A gold ring painted flush against a blue button is therefore effectively invisible to
anyone who cannot rely on hue alone. So the ring is drawn with a **2px offset in the
background colour**, which guarantees the indicator is always measured against the
background — where it clears 3:1 comfortably in both themes — rather than against the
component fill, where it does not.

| Ring against background | Contrast | Required |
|---|---|---|
| `electrum-400` on `granite-950` (dark) | 10.54:1 | 3.0 |
| `electrum-700` on `granite-0` (light) | 5.84:1 | 3.0 |

This is encoded in `design/tokens.yaml` under `focus:` as `width`, `offset`, and
`min_contrast_vs_background`. No surface may draw its own focus indicator.

### granite carries everything else

Backgrounds, surfaces, text, borders, and every component that is neither interactive
nor brand furniture. If a decision is hard, the answer is granite: the stone is the
product, and the two accent colours are the exception rather than the palette.

### patina is a rationing device

`patina` exists for the rare case that genuinely needs a third emphasis — a secondary
action that must be visually separable from the primary one. If it appears more than
once on a screen, the screen has too many priorities and the fix is in the layout, not
in the palette.

## Quick reference

| Element | Colour | Never |
|---|---|---|
| Primary button fill | lapis | electrum |
| Link | lapis | electrum |
| Selected list row | lapis | electrum |
| Progress fill | lapis | electrum |
| Focus ring (offset 2px) | electrum | lapis |
| Logo and pyramidion | electrum | lapis |
| Boot splash mark | electrum | lapis |
| Body text, surfaces, borders | granite | either accent |
| Secondary action, used sparingly | patina | more than once per screen |

## Enforcement

`design/generate.py` computes every foreground/background pair from `tokens.yaml` and
writes the ratios to `docs/DESIGN-CONTRAST.md` on every run. CI fails when a non-exempt
pair drops below its requirement.

Contrast is necessary but not sufficient: the rule above exists precisely because a
palette can pass every ratio and still be incoherent. Reviewers should check the rule
by eye, and any deliberate exception must be written down here with its reasoning.
