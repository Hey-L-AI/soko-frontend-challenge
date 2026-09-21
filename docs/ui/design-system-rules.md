---
title: Figma-to-Flutter Design System Rules
domain: [ui]
status: living
last_verified: 2026-07-21
---

# Figma-to-Flutter Design System Rules

> Generated 2026-03-03 via `create_design_system_rules` analysis
> Project: HeyL/Soko Flutter app (Web, iOS, Android)

## 1. Token Definitions

### Color tokens
Defined in `lib/core/theme/app_colors.dart` as static `Color` constants.

**Figma Soko tokens → Flutter mapping:**

| Figma Token | Hex | Flutter Constant |
|-------------|-----|-----------------|
| Soko/Paper | `#F9F0F0` | `AppColors.sokoPaper` |
| Soko/Pink | `#FFB8CB` | `AppColors.sokoPink` |
| Soko/Shade1 | `#312228` | `AppColors.sokoShade1` |
| Soko/Light 2 | `#EFDFE4` | `AppColors.sokoLight2` |
| Soko/Ink | `#44131D` | `AppColors.sokoInk` |
| Soko/Dark | `#170408` | `AppColors.sokoDark` |
| Soko/Lilac | `#E08EFB` | `AppColors.sokoLilac` |
| Soko/Purple | `#A597FF` | `AppColors.sokoPurple` |
| Soko/Yellow | `#EDE77D` | `AppColors.sokoYellow` |

**General app tokens** are also in `AppColors` — primary, background, text, border, etc. for both light and dark modes.

### Typography
- **Heading font**: UnJamoBatang (interim for Season Mix Trial from Figma)
  - Asset: `assets/fonts/UnJamoBatang.ttf`
  - Desktop: 101.146px, leading 0.96, tracking -1.0115px
  - Mobile: 52px, leading 0.96, tracking -0.52px
- **Body font**: Zalando Sans (mapped to system sans-serif in Flutter)
  - Nav pills: 16px Light, 17px line-height, -0.16px tracking
  - Input: 22px Light, 1.2 line-height, -0.22px tracking
  - Fading prompts: 17.923px Regular, 1.2 line-height, -0.3585px tracking
  - Card pills: 16px Light, 17px line-height, -0.16px tracking

### Spacing
Flutter uses explicit pixel values matching Figma. No spacing scale system — values are hardcoded per component.

## 2. Component Library

### Location
Components live in the feature-based directory structure:
```
lib/
├── features/
│   ├── chat/
│   │   ├── screens/chat_screen.dart      # Main home/chat screen
│   │   └── widgets/
│   │       ├── immersive_map_hero.dart    # Hero section with photo bg
│   │       └── message_input.dart         # Search/input card
│   ├── lists/widgets/
│   ├── onboarding/screens/
│   └── settings/widgets/
└── shared/widgets/
    ├── desktop_top_nav.dart               # Desktop navigation bar
    ├── dotted_line.dart                   # Shared dotted line widget
    └── glassmorphic_header.dart           # Glassmorphic blur wrapper
```

### Architecture
- **State management**: Riverpod (ConsumerWidget, ConsumerStatefulWidget)
- **Navigation**: GoRouter with URL-based routing
- **Responsive**: Manual breakpoints (`MediaQuery.sizeOf(context).width >= 1024` for desktop)

### Canonical components — use these, do NOT hand-roll Material

Reach for the shared design-system widgets before building UI from raw Material. Bare Material
widgets bypass the Soko look and have been flagged in review more than once (see `CLAUDE.md`
"Design system — check it BEFORE building any UI component").

| Need | Use | Location | Avoid |
|------|-----|----------|-------|
| Primary CTA / full-width action button | `SokoCtaButton` (variants pink/red/ink/yellow/lilac/green) | `lib/shared/widgets/soko_cta_button.dart` | `FilledButton` / `ElevatedButton` / `TextButton` |
| Sheet footer button pair (Cancel + Confirm) | `BtSqIco` | `lib/shared/widgets/bt_sq_ico.dart` | raw Material buttons |
| Inline face + name credit (curator, follower proof, shared-by) | `AvatarNameLabel` (20 px round avatar + single-line label, person-glyph fallback) | `lib/shared/widgets/avatar_name_label.dart` | hand-rolled `ClipOval` + `Text` rows |
| Bottom-sheet chrome (paper shell, drag handle, header/body/footer, shadow) | `DSSheetShell` | `lib/shared/widgets/bottom_sheet/ds_sheet_shell.dart` | hand-built `Container` |
| Presenting a bottom sheet (hides bottom nav, sokoInk scrim, root navigator) | `showBottomSheetWithHiddenNav(context, ref, builder)` | `lib/shared/utils/bottom_sheet_utils.dart` | raw `showModalBottomSheet` |
| Inline text link | styled tappable `Text` (underline, `AppColors.sokoInk`) | — | `TextButton` |
| Transient feedback (success / error / loading toast) | `showSoko(ref, message:, variant:)` — or `showSokoFromContext` without a `WidgetRef` | `lib/shared/notifications/heyl_notification.dart` | `ScaffoldMessenger.showSnackBar` |

- `showBottomSheetWithHiddenNav` needs a `WidgetRef` — make the caller a `ConsumerWidget`/`ConsumerState`.
- Some older widgets (e.g. `att_pre_prompt_sheet.dart`) predate these and use raw Material — **do not copy them as a template.**
- The SnackBar→Soko migration is **not finished** — ~20 `showSnackBar` call sites still ship (see [`soko-notifications.md` § Migration status](soko-notifications.md#migration-status)). Finding one in a neighbouring file is not permission to add another; new code uses `showSoko`.
- **Foreground on a coloured Soko fill = `AppColors.sokoInk`, never white.** The bright Soko accents (lilac/purple/yellow/green/red/blue) sit at high luminance, so white text/glyphs fail WCAG contrast on them (white on Soko/Red ≈ 2.4:1, on Soko/Lilac ≈ 2.6:1) while `sokoInk` clears it (≈ 6:1). This is why every `SokoCtaButton` colour variant and `IgDirectShareButton`'s solid-fill mode pair the fill with a `sokoInk` label/glyph. Reserve white foregrounds for dark fills (`sokoInk`/`sokoDark`) and the IG brand gradient.
- Background of the design-system sheet: [`investigations/archived/prod-1860-bottom-sheet-design-system-migration.md`](../investigations/archived/prod-1860-bottom-sheet-design-system-migration.md).

## 3. Frameworks & Libraries

| Purpose | Library |
|---------|---------|
| UI Framework | Flutter 3.38.x |
| State Management | flutter_riverpod |
| Navigation | go_router |
| Icons | flutter_lucide (LucideIcons) |
| SVG | flutter_svg |
| Localization | intl / flutter_localizations |

### Build
- `flutter build web` for web
- `flutter build appbundle` for Android
- `flutter build ios` for iOS

## 4. Asset Management

### Images
```
assets/images/
├── heroes/          # Hero background photos (JPEG/WebP)
├── logos/            # SVG logos (soko-logo-paper.svg, etc.)
└── icons/           # App icons
```
Referenced via `Image.asset('assets/images/...')` or `SvgPicture.asset(...)`.

### Fonts
```
assets/fonts/
└── UnJamoBatang.ttf  # Heading font (Season Mix Trial substitute)
```

## 5. Icon System

- **Library**: `flutter_lucide` package
- **Usage**: `Icon(LucideIcons.menu)`, `Icon(LucideIcons.sun)`, etc.
- **Naming**: camelCase matching Lucide icon names
- **Custom icons**: SVG assets in `assets/images/logos/`

## 6. Styling Approach

### Methodology
Inline Flutter widget styling — no CSS, no Tailwind. All styling is via widget properties:
```dart
Container(
  decoration: BoxDecoration(
    color: AppColors.sokoPaper,
    borderRadius: BorderRadius.circular(17.923),
  ),
)
```

### Glassmorphic/Blur effects
```dart
ClipRRect(
  borderRadius: BorderRadius.circular(999),
  child: BackdropFilter(
    filter: ImageFilter.blur(sigmaX: 11, sigmaY: 11),
    child: Container(
      color: AppColors.sokoPaper.withValues(alpha: 0.2),
      child: content,
    ),
  ),
)
```

### Responsive design
- Mobile-first layout
- Desktop breakpoint: `width >= 1024`
- Desktop shows `DesktopTopNav`, mobile shows header pills + bottom nav
- `LayoutBuilder` and `MediaQuery` for responsive sizing

### Dark mode
- Detected via `Theme.of(context).brightness == Brightness.dark`
- Conditional colors: `isDark ? darkColor : lightColor`
- Hero mode (home page) always uses paper/dark tokens regardless of system theme

## 7. Figma-to-Flutter Translation Rules

### When converting Figma MCP output to Flutter:

1. **Ignore all React/JSX syntax** — translate to Flutter widgets
2. **Ignore all Tailwind classes** — use Flutter BoxDecoration, TextStyle, etc.
3. **Map Figma colors** to `AppColors` constants (see token table above)
4. **Map Figma fonts**: "Season Mix TRIAL" → UnJamoBatang, "Zalando Sans" → system default
5. **Preserve exact pixel values** for sizes, spacing, border radius
6. **backdrop-blur** → `BackdropFilter(filter: ImageFilter.blur(sigmaX: N, sigmaY: N))`
7. **opacity** → `.withValues(alpha: N)` on colors, NOT `Opacity` widget
8. **border-radius: 999px** → `BorderRadius.circular(999)` (full pill)
9. **Gradients**: `LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [...], stops: [...])`
10. **Asset URLs from Figma expire** — never store them as permanent references

### Light vs Dark mode patterns:

| Figma Pattern | Light Flutter | Dark Flutter |
|---------------|--------------|-------------|
| Card bg | `AppColors.sokoPaper` (solid) | `AppColors.sokoPaper.withValues(alpha: 0.2)` + blur |
| Card bottom | `AppColors.sokoLight2` | (no bottom, unified glass) |
| Input text | `AppColors.sokoInk` | `AppColors.sokoPaper` |
| Send button | `AppColors.sokoDark.withValues(alpha: 0.1)` | `AppColors.sokoPaper.withValues(alpha: 0.2)` |
| Bottom nav | Solid `AppColors.sokoPaper` | Glass `AppColors.sokoPaper.withValues(alpha: 0.2)` + blur |
| Pill borders | `0.5px rgba(68,19,29,0.5)` | No borders |

## 8. Localization

- All user-facing strings in ARB files: `lib/l10n/intl_en.arb`, `intl_pt.arb`, `intl_pt_BR.arb`
- Access: `Lt.of(context).keyName`
- Exception: "Mode" label is hardcoded English (UI label, not content)
- Soko is feminine in Portuguese: "a Soko", "da Soko"

## 9. Large font / OS text scaling (anti-clipping rules)

**Every screen must survive an OS font-scale of 1.3× without clipping any text.**
The app honours the user's OS font size (iOS *Settings → Display & Text Size →
Larger Text* / Dynamic Type; Android *Font size*) but **clamps the ceiling at
1.3×** app-wide — `lib/app.dart` wraps the `MaterialApp.router` builder in
`MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3)` (no floor: users who
shrink text keep it). Flutter's `Text` grows faithfully with the scaler, so any
widget that reserves a **fixed pixel box** computed from 1.0× metrics will clip
its text once it scales. These rules — and the regression tests that enforce them
(§ below) — exist because that clipping was fixed reactively twice (PROD-2875,
PROD-2904) and must not come back.

**Build new UI to these rules:**

1. **No fixed pixel height/width *around text*.** Prefer a `minHeight`
   (`ConstrainedBox(constraints: BoxConstraints(minHeight: …))` or a button's
   `minimumSize`) over a fixed `height` / `fixedSize`, so the text region can
   grow with the scaler. When a container's height is genuinely load-bearing
   (uniform rows in a horizontal shelf, a locked animated header), **scale the
   reserved text height by the OS scaler** — don't leave it constant:

   ```dart
   final raw = MediaQuery.textScalerOf(context).scale(14) / 14;
   final textScale = raw < 1.0 ? 1.0 : raw; // grow, never shrink, the box
   final reserved = baseTextBlockHeight * textScale;
   ```

   Canonical example: `NearYouCard.heightForWidth(width, textScale)` /
   `CanonicalShelfCard.heightForWidth(width, textScale)`
   (`lib/features/discovery/widgets/shelves/`) reserve `textBlockHeight *
   textScale`, and `DiscoveryShelf` passes the ambient scaler in.

2. **Buttons**: keep the **min tap target** (44 pt iOS / 48 dp Android) via a
   *minimum* size, and let the label **wrap or auto-size** — never `fixedSize` +
   a single-line clip. Use the shared `SokoCtaButton` (44 px min height) and
   `BtSqIco` (40 px, `Flexible` + ellipsis label); do not hand-roll fixed-height
   Material buttons.

3. **Third-party text widgets that ignore `MediaQuery`** (chiefly
   `flutter_linkify`'s `Linkify` / `SelectableLinkify`, whose `textScaleFactor`
   defaults to `1.0`): pass them the effective factor via
   `effectiveTextScaleFactor(context)` (`lib/core/utils/text_scale.dart`).
   **Never** apply it to a plain `Text` — that double-scales.

4. **Headers / rows that can't grow past the screen width** (a big animated H1,
   a title + adornment unit): wrap the unit in
   `FittedBox(fit: BoxFit.scaleDown)` so it scales-to-fit instead of overflowing
   the right edge — a no-op when it already fits. See the Lists "Tuas / A seguir"
   toggle header (D231).

**Regression tests.** New shared primitives and dense screens get an
**overflow-guard widget test** at `textScaler: 1.3`: pump the widget in a narrow
box wrapped in `MediaQuery(... textScaler: TextScaler.linear(1.3))` and assert
`expect(tester.takeException(), isNull)` (that *is* the overflow-banner check —
`RenderFlex` paints the banner and throws under the same condition). Assert **zero**
overflow, never a `<1px` tolerance. Existing guards live at
`test/shared/widgets/*_large_font_test.dart`,
`test/features/discovery/widgets/shelves/shelf_cards_large_font_test.dart`, and
`test/features/profile/screens/menu_screen_large_font_test.dart`; copy one when
adding a new primitive.

**Why (background):** the three learnings docs
[`os-font-scale-clamp-and-grow.md`](../learnings/os-font-scale-clamp-and-grow.md),
[`flutter-linkify-ignores-textscaler.md`](../learnings/flutter-linkify-ignores-textscaler.md),
and [`animated-text-locked-height-textpainter.md`](../learnings/animated-text-locked-height-textpainter.md),
plus design decisions **D230** (1.3× clamp policy) and **D231** (header
scales-to-fit) in [`design-decisions.md`](design-decisions.md).
