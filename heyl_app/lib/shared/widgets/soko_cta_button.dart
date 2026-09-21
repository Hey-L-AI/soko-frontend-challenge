import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Canonical full-width Soko primary CTA — matches the "add to soko"
/// Save button in `add_to_list_sheet.dart` (the reference shape called
/// out by design):
///
/// - height 44 px, full width by default (`expand: true`)
/// - radius 6 px, elevation 0
/// - Zalando Sans 14 / w400 / line-height 1.2 / letter-spacing -0.14
/// - icon size 14, gap 8 to label (when present)
/// - hover/focus: bg = `Color.alphaBlend(fg × 0.10, bg)`, pressed × 0.16.
///   Same math as `BtSqIco` so the two CTA widgets render identical
///   hover/pressed shades on every brand surface (sokoPink/sokoYellow/
///   sokoInk/etc.).
/// - `pink` variant: `sokoPink` bg + `sokoInk` fg (default)
/// - `red` variant: `sokoRed` bg + `sokoInk` fg (destructive)
/// - `ink` variant: `sokoInk` bg + `sokoPaper` fg
/// - `yellow` variant: `sokoYellow` bg + `sokoInk` fg ("Criar zine")
/// - `lilac` variant: `sokoLilac` bg + `sokoInk` fg
/// - `ghost` variant: transparent bg + `sokoInk` fg (borderless tertiary)
///
/// Use this everywhere a screen-level primary action button is needed
/// (Connect Instagram, Sign Out, Delete Account, etc.). For sheet
/// button-row pairs (Cancel + Confirm) keep using [BtSqIco] — that
/// component is the same shape sized down to 40 px for sticky-footer
/// rows.
class SokoCtaButton extends StatelessWidget {
  const SokoCtaButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = SokoCtaVariant.pink,
    this.loading = false,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final SokoCtaVariant variant;

  /// When true, replaces the icon with a small spinner and disables
  /// taps. Used for in-flight actions (e.g. Delete Account → API call).
  final bool loading;

  /// When false, the button hugs its content instead of taking the
  /// full available width. Default `true` (full-width CTA).
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (variant) {
      SokoCtaVariant.pink => (AppColors.sokoPink, AppColors.sokoInk),
      SokoCtaVariant.red => (AppColors.sokoRed, AppColors.sokoInk),
      SokoCtaVariant.ink => (AppColors.sokoInk, AppColors.sokoPaper),
      SokoCtaVariant.yellow => (AppColors.sokoYellow, AppColors.sokoInk),
      SokoCtaVariant.lilac => (AppColors.sokoLilac, AppColors.sokoInk),
      SokoCtaVariant.green => (AppColors.sokoGreen, AppColors.sokoInk),
      // Outline at rest; the hover/press fill is applied below rather than by
      // the shared alpha-blend, because pink is the accent here and not a
      // tint of the resting background (D253).
      SokoCtaVariant.pinkOutline => (AppColors.sokoPaper, AppColors.sokoInk),
      // Borderless tertiary/dismiss action: transparent idle, `sokoInk`
      // label. Hover/pressed reuse the same `Color.alphaBlend(fg × α, bg)`
      // math as every other variant — blended over the transparent bg this
      // yields a faint `sokoInk` tint (10% hover / 16% pressed), the
      // borderless "text button" affordance.
      SokoCtaVariant.ghost => (Colors.transparent, AppColors.sokoInk),
    };

    // Label. In full-width (`expand`) mode the label is wrapped in
    // `Flexible` + `FittedBox(scaleDown)` so a label wider than the button —
    // a long string, a long locale, or the OS large-font setting (clamped
    // app-wide to 1.3×, see D230) — auto-shrinks to stay on one line inside
    // the fixed 44 px pill instead of overflowing the right edge. This follows
    // the design-system rule "buttons wrap or auto-size — never single-line
    // clip" (PROD-2907 / § 9 in `design-system-rules.md`) and is a no-op when
    // the label already fits (scale factor 1.0). In content-hugging mode
    // (`expand: false`) the button sizes to the label's intrinsic width, so no
    // Flexible/FittedBox is applied — a `Flexible` there would be unbounded in
    // the `MainAxisSize.min` Row and callers keep those labels short.
    Widget labelChild = Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: 'Zalando Sans',
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.2,
        letterSpacing: -0.14,
        color: fg,
      ),
    );
    if (expand) {
      labelChild = FittedBox(fit: BoxFit.scaleDown, child: labelChild);
    }
    // Label row stays in place across idle ↔ loading; the spinner overlays it
    // via the Stack so the label never shifts horizontally.
    labelChild = Opacity(opacity: loading ? 0 : 1, child: labelChild);

    // Drive the background color directly from the widget state instead of
    // letting Material paint a separate `overlayColor` layer on top. Result
    // is identical math to `BtSqIco`'s `Color.alphaBlend(fg × α, bg)`, so
    // both CTA widgets render the exact same hover/pressed shade.
    final button = SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style:
            ElevatedButton.styleFrom(
              foregroundColor: fg,
              disabledForegroundColor: fg.withValues(alpha: 0.5),
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: variant == SokoCtaVariant.pinkOutline
                    ? const BorderSide(color: AppColors.sokoPink)
                    : BorderSide.none,
              ),
            ).copyWith(
              backgroundColor: WidgetStateProperty.resolveWith<Color?>((
                states,
              ) {
                if (states.contains(WidgetState.disabled)) {
                  return bg.withValues(alpha: 0.5);
                }
                // Pink is this variant's interaction accent, so hover/press
                // FILL pink instead of tinting the paper rest state (D253,
                // matching `BtSqIcoVariant.pinkOutline`).
                if (variant == SokoCtaVariant.pinkOutline) {
                  if (states.contains(WidgetState.pressed) ||
                      states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.focused)) {
                    return AppColors.sokoPink;
                  }
                  return bg;
                }
                if (states.contains(WidgetState.pressed)) {
                  return Color.alphaBlend(fg.withValues(alpha: 0.16), bg);
                }
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)) {
                  return Color.alphaBlend(fg.withValues(alpha: 0.10), bg);
                }
                return bg;
              }),
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null && !loading) ...[
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: 8),
                ],
                if (expand) Flexible(child: labelChild) else labelChild,
              ],
            ),
            if (loading)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              ),
          ],
        ),
      ),
    );

    if (!expand) return button;
    return SizedBox(width: double.infinity, child: button);
  }
}

enum SokoCtaVariant {
  /// Non-destructive primary CTA. `sokoPink` bg, `sokoInk` text/icon.
  pink,

  /// Destructive CTA (delete, disconnect, etc.). `sokoRed` bg,
  /// `sokoInk` text/icon.
  red,

  /// Dark CTA — `sokoInk` bg, `sokoPaper` text.
  ink,

  /// Creation CTA — `sokoYellow` bg, `sokoInk` text/icon. Used by the
  /// "Criar zine" button inside the add-to-list sheet.
  yellow,

  /// Lilac brand variant — `sokoLilac` bg, `sokoInk` text/icon.
  lilac,

  /// Green brand variant — `sokoGreen` bg, `sokoInk` text/icon. Used by
  /// the "Use my exact location" CTA in the profiling onboarding.
  green,

  /// Soko/Paper fill + 1 px Soko/Pink border at rest, filling Soko/Pink on
  /// hover/press. The design system's "pink as an accent, not a default fill"
  /// treatment — [D253](../../../docs/ui/design-decisions.md), which introduced
  /// it as `BtSqIcoVariant.pinkOutline` for the onboarding profile CTAs and the
  /// location pills.
  ///
  /// Ported here so a stacked pair can be one component: `BtSqIco` is 40 px and
  /// this is 44, so mixing them to get an outline would misalign a two-button
  /// column by 4 px. Same colours, same hover/press math — the two widgets
  /// already share their interaction alphas on purpose.
  pinkOutline,

  /// Borderless tertiary / dismiss action — transparent bg, `sokoInk`
  /// text/icon, no border. Keeps the same 44 px pill shape and
  /// hover/pressed feedback as the filled variants (a faint `sokoInk`
  /// tint), so a "Maybe later" style action stacks cleanly under a filled
  /// primary in the same button column.
  ghost,
}
