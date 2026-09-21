import 'package:flutter/material.dart';

/// Colour tokens for the Soko app.
///
/// Two layers live here, and they are not equal:
///
///  1. **Soko design-system tokens** (`soko*`, the semantic aliases and the map
///     pin tokens) — the canonical palette, mapped 1:1 to Figma `Soko/*`
///     variables. **New UI must use these.** See § "SOKO DESIGN-SYSTEM TOKENS".
///  2. **Pre-design-system tokens** (`primary`, `background`, `surface`,
///     `textPrimary`, `border`, …) — derived from the retired Lovable mockups,
///     which are no longer a source of truth. These still hold up the legacy
///     app shell and older screens, so they cannot simply be deleted, but they
///     are a migration target, not a valid choice for new work.
///
/// Inventory with live usage counts and Figma origins:
/// `docs/ideation/wireframes/brand-color-visualizer.html`.
class AppColors {
  AppColors._();

  // ============================================
  // PRE-DESIGN-SYSTEM TOKENS — LIGHT
  // Legacy layer. Prefer the Soko tokens below for anything new.
  // ============================================

  // --primary: 350 45% 55% (light mode)
  static const Color primary = Color(0xFFC76274); // hsl(350 45% 55%)
  static const Color primaryDark = Color(
    0xFFA34A5A,
  ); // hsl(350 34% 46%) - pressed

  // Secondary colors (Rose tint)
  // --secondary: 350 30% 90% (light mode)
  static const Color secondary = Color(0xFFF0E0E3); // hsl(350 30% 90%)
  static const Color secondaryForeground = Color(
    0xFFA34A5A,
  ); // hsl(350 45% 40%)

  // Background colors - Warm cream
  // --background: 30 30% 94% (light mode)
  static const Color background = Color(0xFFF5F1EC); // hsl(30 30% 94%)
  // --card: 30 25% 98% (light mode)
  static const Color surface = Color(0xFFFCFBF9); // hsl(30 25% 98%) - card
  static const Color surfaceVariant = Color(0xFFFCFBF9); // Same as surface

  // Muted colors
  // --muted: 30 20% 90% (light mode)
  static const Color muted = Color(0xFFE8E2DC); // hsl(30 20% 90%)

  // Text colors - Warm tones
  // --foreground: 0 20% 15% (light mode)
  static const Color textPrimary = Color(
    0xFF2E1F1F,
  ); // hsl(0 20% 15%) - warm dark brown
  // --muted-foreground: 0 10% 40% (light mode)
  static const Color textSecondary = Color(0xFF706666); // hsl(0 10% 40%)
  static const Color textTertiary = Color(0xFF8A8080); // hsl(0 8% 50%)
  static const Color textOnPrimary = Color(0xFFFFFFFF); // White

  // Border colors - Warm gray
  // --border: 30 20% 85% (light mode)
  static const Color border = Color(0xFFDED7D0); // hsl(30 20% 85%)
  // --input: 30 20% 88% (light mode)
  static const Color borderLight = Color(0xFFE5DFD8); // hsl(30 20% 88%)

  // ============================================
  // PRE-DESIGN-SYSTEM TOKENS — DARK
  // Legacy layer. Note dark mode is descoped for redesigned surfaces
  // (PROD-1738): the Soko palette has no dark variants, and redesigned
  // screens render paper/ink regardless of system theme.
  // ============================================

  // --background: 0 33% 6% (dark mode) - dark brown/maroon
  static const Color backgroundDark = Color(0xFF140A0A); // hsl(0 33% 6%)

  // --card: 0 25% 12% (dark mode) - dark brown cards
  static const Color surfaceDark = Color(0xFF261717); // hsl(0 25% 12%)

  // --secondary/--accent: 0 20% 12% (dark mode)
  static const Color surfaceVariantDark = Color(0xFF251818); // hsl(0 20% 12%)

  // --muted: 0 20% 10% (dark mode)
  static const Color mutedDark = Color(0xFF1F1414); // hsl(0 20% 10%)

  // --foreground: 30 10% 95% (dark mode)
  static const Color textPrimaryDark = Color(0xFFF5F3F1); // hsl(30 10% 95%)

  // --muted-foreground: 30 10% 65% (dark mode) - warm taupe
  static const Color textSecondaryDark = Color(0xFFAFA69D); // hsl(30 10% 65%)
  static const Color textTertiaryDark = Color(
    0xFFAFA69D,
  ); // Same as secondary for dark

  // --border: 0 20% 15% (dark mode)
  static const Color borderDarkMode = Color(0xFF2E1F1F); // hsl(0 20% 15%)

  // --primary: 350 45% 72% (dark mode) - dusty pink, lighter for visibility
  static const Color primaryDarkMode = Color(0xFFD898A3); // hsl(350 45% 72%)

  // ============================================
  // STATUS COLORS (Same for both modes)
  // ============================================

  static const Color success = Color(0xFF22C55E); // Green-500
  static const Color warning = Color(0xFFF59E0B); // Amber-500
  static const Color error = Color(0xFFEF4444); // Red-500
  static const Color info = Color(0xFF3B82F6); // Blue-500

  // ============================================
  // MEMORY CATEGORY COLORS
  // ============================================

  static const Color memoryLocation = Color(0xFF3B82F6); // Blue
  static const Color memoryPreferences = Color(0xFFF43F5E); // Rose
  static const Color memoryFeedback = Color(0xFFF59E0B); // Amber

  // Chat bubble constants were removed here (PROD-1804 deprecated them; the
  // cutover has since landed). The chat surface uses Soko tokens: sokoPink for
  // user bubbles, sokoShade5 for assistant bubbles, sokoInk for text, and the
  // bubbles are borderless on sokoPaper.

  // ============================================
  // SHADOWS
  // ============================================

  static const Color shadow = Color(0x1A000000); // 10% black
  static const Color shadowLight = Color(0x0D000000); // 5% black
  static const Color shadowDark = Color(0x40000000); // 25% black for dark mode

  // ============================================
  // BRAND / ACCENT COLORS
  // ============================================

  static const Color amber = Color(0xFFF59E0B);

  /// WhatsApp brand green. Used for the "Continue on WhatsApp" CTA, the
  /// WhatsApp session marker in the sidebar, and the WhatsApp share channel.
  static const Color whatsapp = Color(0xFF25D366);

  // ============================================
  // SOKO DESIGN-SYSTEM TOKENS (canonical, pulled live from Figma 6144:3690)
  // ============================================
  //
  // Refresh by re-running `get_variable_defs` against `6144:3690` via the
  // Figma MCP. `sokoLight2` (#EFDFE4) diverges from the design system
  // and is pending designer reconciliation — left untouched here on
  // purpose.

  static const Color sokoPaper = Color(0xFFF9F0F0); // Page background
  static const Color sokoPink = Color(
    0xFFFFB8CB,
  ); // Avatar border, Save selected/hover bg

  /// Soko/Middle Pink — a deeper, more saturated companion to [sokoPink].
  /// Use when a pink surface needs more visual weight than the standard
  /// pink (e.g. the high-density "3+ events" cell on the calendar).
  static const Color sokoPinkMiddle = Color(0xFFEF8EA8);
  static const Color sokoShade1 = Color(0xFF312228); // Active desktop nav pill
  static const Color sokoShade2 = Color(0xFF534B4D);
  static const Color sokoShade3 = Color(
    0xFF947C81,
  ); // Muted secondary text (Discovery card captions)
  static const Color sokoShade4 = Color(
    0xFFC1B2B5,
  ); // Discovery chat bar placeholder text
  static const Color sokoShade45 = Color(
    0xFFE7DBDE,
  ); // Discovery chat bar bottom row, send idle
  static const Color sokoShade5 = Color(
    0xFFF1E5E6,
  ); // Discovery chat bar top row, mic, history
  /// Soko/Ink — primary text on light surfaces.
  ///
  /// **`#3B0F18`, corrected 2026-08-28.** This held `#44131D` for months, which
  /// is not a stale copy of Soko/Ink — it is the *current* value of a
  /// **different** variable, `Soko/Ink 10`. `get_variable_defs` on the feed
  /// frames returns both side by side:
  /// `{"Soko/Ink": "#3B0F18", "Soko/Ink 10": "#44131D"}`. Confirmed as the live
  /// value by the designer (Zé, 2026-08-28).
  ///
  /// That is why the mistake survived: the app was not showing an out-of-date
  /// colour, it was showing a real token under the wrong name, so every
  /// spot-check against Figma found the hex somewhere in the palette.
  static const Color sokoInk = Color(0xFF3B0F18); // Text on light card
  /// Soko/Ink at 8 % opacity — subtle overlays / dividers
  /// (`docs/ui/design-tokens.md` line 24).
  static const Color sokoInk8 = Color(0x14_3B0F18);

  /// `Soko/Ink 10` — different base (`#44131D`) and 10% alpha vs [sokoInk8].
  /// Do not substitute [sokoInk8]; over paper it is visibly lighter.
  static const Color sokoInk10 = Color(0x1A_44131D);

  /// `Soko/Ink 50` — the muted secondary text on the person card: the @handle
  /// and the details row (Figma `7740:46956`, `get_variable_defs` →
  /// `{"Soko/Ink 50": "#764D4D"}`).
  ///
  /// A **solid** token, not [sokoInk] at 50 % — and deliberately not
  /// [sokoShade3] `#947C81`, which is the older, lighter muted grey the card
  /// used before PROD-4443. The two are close enough to be mistaken for each
  /// other in a screenshot and far enough apart to be wrong.
  static const Color sokoInk50 = Color(0xFF764D4D);

  /// Soko/Ink at 30 % opacity — secondary text / muted UI surfaces
  /// (`docs/ui/design-tokens.md` line 25). Used as the user-bubble fill in
  /// chat per PROD-1804 follow-up.
  static const Color sokoInkSecondary = Color(0x4D_3B0F18);
  static const Color sokoDark = Color(0xFF170408); // Darkest, send button tint
  static const Color sokoBlue = Color(
    0xFF8BDFFF,
  ); // Venue detail page bg, event tag fill
  // Reconciled to the live Figma palette (Soko/ variables, node 2763:8327):
  // Lilac #C588F2→#E08EFB, Purple #8D88FB→#A597FF, Yellow #F0F288→#EDE77D.
  static const Color sokoLilac = Color(0xFFE08EFB); // Event detail page bg
  static const Color sokoPurple = Color(
    0xFFA597FF,
  ); // Zine cover "purple" variant (PROD-2042 retired the venue-tag binding)
  static const Color sokoYellow = Color(
    0xFFEDE77D,
  ); // Rating tag fill, Daily Drop / Weekly Bundle bg
  static const Color sokoGreen = Color(0xFFB0EF8B);
  static const Color sokoRed = Color(
    0xFFF68686,
  ); // Saves tag fill, destructive accents

  static const Color sokoLight2 = Color(
    0xFFEFDFE4,
  ); // ⚠️ no matching Figma token (legacy) — flagged with designer
  static const Color sokoLight3 = Color(
    0xFFFFDAE4,
  ); // Pink header banner (PROD-1861 add-to-list item preview)

  // ============================================
  // SEMANTIC EVENT / VENUE ALIASES
  // ============================================
  // Single source of truth for event and venue surface + accent colors.
  // Change here to recolor every event/venue surface in the app.

  static const Color sokoEvent = sokoGreen; // Event surface
  // Accent rule (PROD-2042): an entity's accent is the OTHER entity's
  // surface colour, so an event card carries a venue-coloured tag and
  // vice-versa. Visually links the two while keeping them legible
  // apart. Event-accent stays blue (was direct `sokoBlue`); venue-
  // accent flips purple → green to honour the swap.
  static const Color sokoEventAccent = sokoVenue; // Event tag / card accent
  static const Color sokoVenue = sokoBlue; // Venue surface
  static const Color sokoVenueAccent = sokoEvent; // Venue tag / card accent
  static const Color sokoListAccent =
      sokoYellow; // Zine/list accent (PROD-1909 typeahead)

  // ============================================
  // MAP PIN + CLUSTER TOKENS (PROD-1978)
  // ============================================
  // Cluster bubble = neutral Soko Pink regardless of contents.
  // Venue/Event pins use the existing semantic aliases so a global color
  // change here propagates to detail pages and cards too.

  static const Color mapClusterFill = sokoPink;
  static const Color mapClusterText = sokoInk;
  static const Color mapPinVenue = sokoVenue;
  static const Color mapPinEvent = sokoEvent;
  static const Color mapPinDefault = primary; // fallback (legacy rose)

  // PROD-2205-followup r3: stroke colours for the SELECTED pin —
  // a darker shade of each pin's own fill (≈ 60 % RGB brightness of
  // the fill). Keeps the hue family so the border reads as "the
  // same colour, darker"; the prior pink-mix shifted the hue too
  // far. Pre-computed so the Mapbox style expression can branch
  // on `item_type` without doing per-frame colour math.
  /// Event stroke ≈ `mapPinEvent (#B0EF8B) · 0.6`.
  static const Color mapPinEventSelectedStroke = Color(0xFF6A8F53);

  /// Venue stroke ≈ `mapPinVenue (#8BDFFF) · 0.6`.
  static const Color mapPinVenueSelectedStroke = Color(0xFF538699);

  /// Default / legacy-rose stroke ≈ `mapPinDefault (#C76274) · 0.6`.
  static const Color mapPinDefaultSelectedStroke = Color(0xFF773B46);

  // PROD-2159: highlight color for the "selected" pin (e.g. the
  // current zine item in the multi-pin item-page map). Reads as a
  // "you are here" accent that contrasts with the venue/event
  // semantic colours. Uses the Soko/list yellow accent — same hue
  // already associated with zines / list affordances.
  static const Color mapPinSelected = sokoYellow;
}
