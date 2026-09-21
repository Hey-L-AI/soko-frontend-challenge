---
title: Figma Design Tokens
domain: [ui]
status: living
last_verified: 2026-09-15
---

# Figma Design Tokens

> **Partial re-verification (2026-07-08)**: pulled `get_variable_defs` against the
> canonical file `d4BCnyUHe2705J7ecQtaIH` ("Soko--shared-"), palette node `2763:8327`.
> That node is the designer's new but **incomplete** palette (8 colours only — no
> shades/pink/dark). Three values drifted and were reconciled into `AppColors`:
> **Lilac `#C588F2`→`#E08EFB`, Purple `#8D88FB`→`#A597FF` (reinstated), Yellow `#F0F288`→`#EDE77D`**.
> Shade/pink/dark rows below were NOT re-verified (absent from that node) and remain as of 2026-04-27.
> A fuller "all colours" palette node is being prepared by the designer — re-pull when it lands.
>
> Earlier extraction (2026-04-27) via `get_variable_defs` on `6PzD8oz32CQA0isCo2KZYp`
> (Soko -- Copy), reference node `3989:6268`. First extraction (2026-03-03):
> `bJgbKsRd1tOe381U4UO4Mw` node `3278:2895`. See the dated "Changes since …" sections below.

## Color Tokens

### Soko palette

| Token | Hex | Usage |
|-------|-----|-------|
| Soko/Paper | `#F9F0F0` | Card bg (light), light surfaces, paper-tone backgrounds |
| Soko/Ink | `#3B0F18` | Primary text on light surfaces, input placeholder. **Corrected 2026-08-28** — this table said `#44131D`, which is the live value of a *different* variable, `Soko/Ink 10`. See the note below. |
| Soko/Ink 8 | `#3B0F18` (8% opacity) | Subtle ink overlays, dividers |
| Soko/Ink 30 | `#3B0F18` (30% opacity) | Secondary text, muted UI |
| Soko/Dark | `#170408` | Darkest tone, send button tint, dark accents |
> **Why `#44131D` persisted so long.** It is not a stale copy of Soko/Ink — it is the current value
> of a **different** Figma variable, `Soko/Ink 10`. `get_variable_defs` on any feed frame returns
> both: `{"Soko/Ink": "#3B0F18", "Soko/Ink 10": "#44131D"}`. So every spot-check against Figma found
> the hex *somewhere* in the palette and passed. Corrected in `AppColors` on 2026-08-28 (Zé
> confirmed `#3B0F18` as the live value). ⚠️ Roughly ten `0x..44131D` literals are still hardcoded
> outside `AppColors` (map, product tour, spotlight, lists) — several labelled "sokoInk @ N%" in
> their own comments. They now name a colour that is no longer Soko/Ink; sweeping them is a
> mechanical follow-up, deliberately not bundled into the feed PR that found this.

> **The conflict is still live in at least one component (2026-09-15).** Rebuilding the Library
> calendar against Figma `6453:11699` (Soko -- shared) hit the other side of this: sampling the
> rendered frame gives day numbers at **`#44131D`**, and `get_design_context` on that node reports
> the style list as `Soko/Ink: #44131D` — under the name `Soko/Ink`, not `Soko/Ink 10`. So the
> component either binds `Soko/Ink 10`, or its local copy of `Soko/Ink` predates the correction.
> The calendar shipped on `AppColors.sokoInk` (`#3B0F18`) regardless, so it stays consistent with
> every other surface rather than becoming the only one on a different ink — the visible cost is
> a 1-2 unit drift when diffing a screenshot against the frame. **Unresolved:** worth asking Zé
> whether that component is on a stale variable, because a designer reading the frame will keep
> reporting `#44131D` as Soko/Ink until it is rebound.

| Soko/Pink | `#FFB8CB` | Avatar border, pink accents; calendar "has events" cell fill (2-event density) |
| Soko/Pink-Middle | `#EF8EA8` | Deeper pink; calendar cell fill for 3+-event density (PROD-2018). Replaced an earlier `Color.lerp(sokoPink, sokoInk, 0.3)` that read muddy. |
| Soko/Lilac | `#E08EFB` | Lilac accents; event detail page bg; IG share button fill |
| Soko/Purple | `#A597FF` | Purple accents; venue type tag, History button (reinstated in Figma — see note) |
| Soko/Blue | `#8BDFFF` | Blue accents |
| Soko/Green | `#B0EF8B` | Green accents |
| Soko/Yellow | `#EDE77D` | Yellow accents, "Daily Drop" pill |
| Soko/Red | `#F68686` | Red accents |

### Soko shade scale

| Token | Hex | Usage |
|-------|-----|-------|
| Soko/Shade1 | `#312228` | Darkest shade — active nav pill bg (desktop) |
| Soko/Shade2 | `#534B4D` | Dark shade |
| Soko/Shade3 | `#947C81` | Mid shade |
| Soko/Shade4 | `#C1B2B5` | Light shade |
| Soko/Shade4.5 | `#E7DBDE` | Lighter shade (in-between) |
| Soko/Shade5 | `#F1E5E6` | Lightest shade |

### SDS foundation tokens (Figma defaults — likely not used in app)

These are Simple Design System library defaults. They appear when components reference unbound variables. Soko variables are the source of truth.

| Token | Value |
|-------|-------|
| `var(--sds-color-icon-default-default)` | `#1e1e1e` |
| `var(--sds-size-space-150)` | `6` |
| `var(--sds-size-space-200)` | `8` |
| `var(--sds-size-space-400)` | `16` |
| `var(--sds-size-stroke-border)` | `1` |
| `var(--sds-size-radius-200)` | `8` |
| `var(--sds-typography-scale-06)` | `32` |
| `var(--sds-typography-body-size-medium)` | `16` |
| `var(--sds-typography-body-font-family)` | `Inter` |
| `var(--sds-typography-body-font-weight-regular)` | `400` |

## Typography Tokens

### Mobile typography scale (used across Discovery & redesigned screens)

| Token | Family | Style | Size | Weight | Line Height | Letter Spacing |
|-------|--------|-------|------|--------|-------------|----------------|
| Mobile/H1 | Season Mix TRIAL | Light | 42 | 300 | 0.94 | -2 |
| Mobile/H2 | Season Mix TRIAL | Regular | 32 | 420 | 1.0 | **0** |
| Mobile/B1 Bold | Zalando Sans | Medium | 18 | 500 | 1.0 | -2 |
| Mobile/B1 Reg | Zalando Sans | Light | 18 | 300 | 1.0 | -2 |
| Mobile/B2 Bold | Zalando Sans | Medium | 14 | 500 | 1.2 | -1 |
| Mobile/B2 Reg | Zalando Sans | Light | 14 | 300 | 1.2 | -1 |

> ⚠️ **Tracking is per token, not per family — don't reach for `AppTheme.body` / `displayPrimary`
> and assume.** Those two *derive* tracking from the size (−1 % and −2 %), which happens to be right
> for B2 and H1 and wrong for the rest. **B1 is −2 %** (not −1) and **H2 is 0** (not −2).
>
> For B1 and B2 use the ready-made `AppTheme.mobileB1Reg()` / `AppTheme.mobileB2Reg()` — they carry
> the correct size, weight, leading and tracking together. For H2, pass `letterSpacing: 0`
> explicitly. Found on the `bundle` block, whose H2 title shipped with −0.56 and whose row title
> shipped as a `body(17, w600)` — the wrong size, weight and tracking at once, when `mobileB1Reg()`
> was sitting there (PROD-3998, 2026-08-28).
>
> H2 added 2026-08-28 from `get_design_context` on Figma `7304-23653`; the row above it is the only
> place it is in use so far.

### SDS foundation typography (Figma defaults — likely not used)

| Token | Definition |
|-------|------------|
| Body Base | Inter Regular 16 / lh 1.4 / ls 0 |
| Text/Extra Small | Geist Regular 12 / lh 20 / ls 0 |
| Fonts/Font Sans | `Geist` |
| Size/Text Xs | `12` |
| Size/Text Sm | `14` |
| Leading/Leading Tight | `20` |
| Weight/Font Normal | `400` |

## Raw JSON

```json
{
  "Soko/Paper": "#F9F0F0",
  "Soko/Ink": "#3B0F18",
  "Soko/Ink 8": "#3B0F18",
  "Soko/Ink 30": "#3B0F18",
  "Soko/Dark": "#170408",
  "Soko/Pink": "#FFB8CB",
  "Soko/Lilac": "#E08EFB",
  "Soko/Purple": "#A597FF",
  "Soko/Blue": "#8BDFFF",
  "Soko/Green": "#B0EF8B",
  "Soko/Yellow": "#EDE77D",
  "Soko/Red": "#F68686",
  "Soko/Shade1": "#312228",
  "Soko/Shade2": "#534B4D",
  "Soko/Shade3": "#947C81",
  "Soko/Shade4": "#C1B2B5",
  "Soko/Shade4.5": "#E7DBDE",
  "Soko/Shade5": "#F1E5E6",
  "Mobile/H1": "Season Mix TRIAL Light 42/0.94/-2",
  "Mobile/B1 Bold": "Zalando Sans Medium 18/1.0/-2",
  "Mobile/B1 Reg": "Zalando Sans Light 18/1.0/-2",
  "Mobile/B2 Bold": "Zalando Sans Medium 14/1.2/-1",
  "Mobile/B2 Reg": "Zalando Sans Light 14/1.2/-1"
}
```

## Flutter Mapping (AppColors)

| Figma Token | Flutter Constant | Notes |
|-------------|------------------|-------|
| Soko/Paper | `AppColors.sokoPaper` (`#F9F0F0`) | Aligned with Figma in PROD-1738 (was `#FEEFEF`). |
| Soko/Pink | `AppColors.sokoPink` (`#FFB8CB`) | Unchanged |
| Soko/Ink | `AppColors.sokoInk` (`#3B0F18`) | **Corrected 2026-09-15** — this row still read `#44131D` after the 2026-08-28 correction landed in the table above and in `app_colors.dart`, so the same document gave two different values for one token. The code has been `0xFF3B0F18` since 2026-08-28. |
| Soko/Dark | `AppColors.sokoDark` (`#170408`) | Unchanged |
| Soko/Green | `AppColors.sokoGreen` (`#B0EF8B`) | Unchanged |
| Soko/Yellow | `AppColors.sokoYellow` (`#EDE77D`) | Reconciled 2026-07-08 (was `#F0F288`). |
| Soko/Shade1 | `AppColors.sokoShade1` (`#312228`) | Unchanged |
| Soko/Shade2..5 | `AppColors.sokoShade2`, `sokoShade3`, `sokoShade4`, `sokoShade45`, `sokoShade5` | ✅ Added (resolved 2026-07-20). |
| Soko/Lilac | `AppColors.sokoLilac` (`#E08EFB`) | Reconciled 2026-07-08 (was `#C588F2`). |
| Soko/Purple | `AppColors.sokoPurple` (`#A597FF`) | **Reinstated in Figma** and reconciled 2026-07-08 (was `#8D88FB`). The 2026-04-27 "removed from Figma" note below no longer holds — both Lilac and Purple now exist as distinct tokens. |
| Soko/Blue | `AppColors.sokoBlue` (`#8BDFFF`) | ✅ Added (resolved 2026-07-20). |
| Soko/Red | `AppColors.sokoRed` (`#F68686`) | ✅ Added (resolved 2026-07-20). |
| Soko/Pink-Middle | `AppColors.sokoPinkMiddle` (`#EF8EA8`) | ✅ Added (PROD-2018). |
| Soko/Ink 8 | `AppColors.sokoInk8` (`0x14_3B0F18`) | ✅ Added (resolved 2026-07-20). 8% alpha of Soko/Ink. Base hex corrected 2026-09-15 to match the code and the Soko/Ink row. |
| Soko/Ink 30 | `AppColors.sokoInkSecondary` (`0x4D_3B0F18`) | ✅ Added (resolved 2026-07-20). 30% alpha of Soko/Ink. Base hex corrected 2026-09-15. **Note the name does not match the token** — it is `sokoInkSecondary`, not `sokoInk30`. |
| Soko/Ink 10 | `AppColors.sokoInk10` (`0x1A_44131D`) | The one token that really is based on `#44131D`. Do not substitute `sokoInk8` — different base *and* different alpha, and over paper it is visibly lighter. |

## Changes since 2026-04-27

Re-pulled `get_variable_defs` against the canonical file `d4BCnyUHe2705J7ecQtaIH`
("Soko--shared-"), palette node `2763:8327` (the designer's new but partial
8-colour palette). Reconciled into `AppColors` and the Figma cache
(`docs/ui/figma-cache/screens/design-system/_overview.md`).

| Token | Before | After | Action |
|-------|--------|-------|--------|
| Soko/Lilac | `#C588F2` | `#E08EFB` | ✅ Updated `AppColors.sokoLilac`. |
| Soko/Purple | (was "removed" per 2026-04-27) | `#A597FF` | ✅ **Reinstated** — Purple is back in Figma as a distinct token; updated `AppColors.sokoPurple` (was legacy `#8D88FB`). |
| Soko/Yellow | `#F0F288` | `#EDE77D` | ✅ Updated `AppColors.sokoYellow`. |

Unchanged, re-confirmed against the new node: Paper `#F9F0F0`, Blue `#8BDFFF`,
Green `#B0EF8B`, Red `#F68686`, Ink `#44131D`. Shades/Pink/Dark were **not** present
in the new node and are unverified since 2026-04-27.

> **Note:** the old canonical palette node `6144:3690` (the source the Figma cache was
> built from) no longer exists — it was replaced by `2763:8327`. The "removed from Figma"
> guidance for Soko/Purple in the 2026-03-03 section below is superseded here — both
> Lilac and Purple now exist in Figma as distinct tokens.

## Changes since 2026-03-03

| Token | Before | After | Action |
|-------|--------|-------|--------|
| Soko/Paper | `#FEEFEF` | `#F9F0F0` | ✅ Aligned in PROD-1738 (commit `db461b4`). |
| Soko/Purple | `#8D88FB` | (removed) | Replace usages with Soko/Lilac (`#C588F2`) where appropriate, or keep legacy if old screens still use it |
| Soko/Lilac | (new) | `#C588F2` | Add |
| Soko/Blue | (new) | `#8BDFFF` | ✅ Added |
| Soko/Red | (new) | `#F68686` | ✅ Added |
| Soko/Shade2..5, Shade4.5 | (new) | shade scale | ✅ Added |
| Soko/Ink 8, Ink 30 | (new) | opacity variants | ✅ Added (`sokoInk8`, `sokoInkSecondary`) |
| Mobile/H1, B1 Bold/Reg, B2 Bold/Reg | (new) | typography tokens | ✅ Added — wired via `AppTheme.displayPrimary(...)` / `AppTheme.body(...)` |

> Adoption is staged: introduce the new tokens first, migrate legacy usages as redesigned screens land. Don't delete `Soko/Purple` from Flutter constants until no screens reference it.

> **Status 2026-07-20**: every "Add" row above is now resolved — all Soko palette,
> shade-scale and ink-opacity tokens exist in `app_colors.dart`. The remaining gap
> is the reverse direction: `AppColors` still carries a large **pre-design-system
> layer** derived from the retired Lovable mockups (`primary`, `background`,
> `surface`, `textPrimary`, …) which has no Figma origin. See
> [`brand-color-visualizer.html`](../ideation/wireframes/brand-color-visualizer.html)
> for the full inventory with live usage counts.
