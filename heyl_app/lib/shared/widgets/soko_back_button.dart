import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import 'clickable.dart';

/// The shared arrow glyph — a long left-pointing arrow.
///
/// Named here rather than inlined because it is drawn in **both** directions:
/// [SokoBackButton] as-is, and `SokoForwardArrow` mirrored. One constant means
/// swapping the art cannot leave the two pointing at different drawings.
const String kSokoArrowGlyph = 'assets/images/icons/detail/back-arrow.svg';

/// Surface treatment for [SokoBackButton].
enum SokoBackButtonVariant {
  /// A bare glyph centred in a 48×48 hit target — for use inside a solid
  /// header/chrome surface.
  bare,

  /// The glyph on a 36×36 [AppColors.sokoInk8] circle — the same tinted chrome
  /// `ChatBarCircleButton` and `NotificationsTopButton` draw, for headers where
  /// the back arrow sits among other icon-circle buttons.
  shaded,

  /// The glyph on a 44×44 [AppColors.sokoPaper] circle with a soft shadow —
  /// for chrome-less pages that sit over media (e.g. the full-bleed Map page),
  /// where a bare icon wouldn't read against the content underneath.
  floating,
}

/// Design-system back button — the canonical "go back" affordance.
///
/// Renders the shared `back-arrow.svg` glyph (tinted [color], default
/// [AppColors.sokoInk]) and standardizes the tap behaviour: pop the
/// navigation stack, falling back to [fallbackRoute] (default `/`) on a cold
/// deep-link where there's nothing to pop. This mirrors the shared
/// `popOrFallback` helper without coupling `shared/` to a feature; callers
/// that need a richer fallback (e.g. a parent list) pass their own [onTap].
///
/// **Both of the app's pinned headers draw their arrow from here** (PROD-4086):
/// `SokoPinnedHeader` via `SokoHeaderSlot.back()` at `size: 40`, and the
/// shell-level `PinnedPageChrome` at the `bare` default of 48 — the latter
/// passing `onTap` because its fallback is richer than pop-or-go-`/` (an
/// in-list detail returns to its parent list). So a change to the glyph, the
/// hit target or the tap policy here lands on `/lists/*`, `/venues/*`,
/// `/events/*`, daily-drop and create-zine as well as the feed. That is the
/// point — but it means this is not a widget to adjust casually for one caller.
///
/// Three surface treatments via [variant] — see [SokoBackButtonVariant].
class SokoBackButton extends StatelessWidget {
  const SokoBackButton({
    super.key,
    this.variant = SokoBackButtonVariant.bare,
    this.onTap,
    this.fallbackRoute = '/',
    this.color = AppColors.sokoInk,
    this.surfaceColor = AppColors.sokoPaper,
    this.size,
  });

  /// Which surface the glyph sits on. Defaults to [SokoBackButtonVariant.bare].
  final SokoBackButtonVariant variant;

  /// Overrides the default pop-or-fallback tap behaviour. Pass this when a
  /// screen needs a custom destination (e.g. `popOrFallback(context,
  /// parentListId: ...)`).
  final VoidCallback? onTap;

  /// Where to land when the stack can't be popped (cold deep-link). Ignored
  /// when [onTap] is provided.
  final String fallbackRoute;

  /// Glyph tint. Defaults to [AppColors.sokoInk].
  final Color color;

  /// Fill of the circular surface, used only by
  /// [SokoBackButtonVariant.floating]. Defaults to [AppColors.sokoPaper]; the
  /// Map page passes white (PROD-2996). The `shaded` variant always uses
  /// [AppColors.sokoInk8] so it stays a peer of the other tinted icon circles.
  final Color surfaceColor;

  /// Overrides the variant's default outer dimension (bare 48, shaded 36,
  /// floating 44). The glyph itself does not scale — only the box around it.
  ///
  /// Exists for headers with their own row height: [SokoPinnedHeader] is a
  /// 40 px bar, and `bare`'s 48 px Material hit target overflows it. Passing
  /// 40 keeps the arrow on the same rhythm as the filled 40 px circles beside
  /// it without forking a fourth variant.
  final double? size;

  void _defaultBack(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(fallbackRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 22×17 matches the chrome-header back arrow (PinnedPageChrome). The
    // `shaded` variant shrinks it to the 16 px glyph its sibling circle
    // buttons use, so the arrow doesn't crowd the smaller 36 px circle.
    final glyph = SvgPicture.asset(
      kSokoArrowGlyph,
      width: variant == SokoBackButtonVariant.shaded ? 16 : 22,
      height: variant == SokoBackButtonVariant.shaded ? 12 : 17,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );

    final Widget surface = switch (variant) {
      // 48×48 hit target (Material guideline) around the compact glyph.
      SokoBackButtonVariant.bare => SizedBox(
        width: size ?? 48,
        height: size ?? 48,
        child: Center(child: glyph),
      ),
      SokoBackButtonVariant.shaded => Container(
        width: size ?? 36,
        height: size ?? 36,
        decoration: const BoxDecoration(
          color: AppColors.sokoInk8,
          shape: BoxShape.circle,
        ),
        child: Center(child: glyph),
      ),
      SokoBackButtonVariant.floating => Container(
        width: size ?? 44,
        height: size ?? 44,
        decoration: BoxDecoration(
          color: surfaceColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppColors.sokoInk.withValues(alpha: 0.12),
              blurRadius: 8,
            ),
          ],
        ),
        child: Center(child: glyph),
      ),
    };

    return Clickable(
      onTap: onTap ?? () => _defaultBack(context),
      child: surface,
    );
  }
}
