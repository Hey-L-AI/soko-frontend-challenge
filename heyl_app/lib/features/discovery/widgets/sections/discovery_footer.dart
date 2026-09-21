import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../l10n/generated/l10n.dart';

/// End-of-page footer for the Discovery page (Figma
/// `d4BCnyUHe2705J7ecQtaIH` node `6144:5235`): a 115 × 115 illustration
/// tile + a centred Season Mix Light 42 px line.
///
/// Three variants share the same chrome:
///   - [DiscoveryFooter] — sits below the shelves on the discovery
///     scroll. Tile asset: `soko-seating-and-reading.webp`. Line:
///     "That's all folks" ([discoveryFooterEnd]).
///   - [DiscoveryFooter.doneLooking] — for the search-results state
///     when the user has filtered through the action bar. Tile asset:
///     `soko-walking-and-reading.webp`. Line: "Done looking?" ([discoveryFooterDoneLooking]).
///   - [DiscoveryFooter.comingSoon] — placeholder used on `/lists` while
///     the redesigned hub is being built (PROD-1736 follow-up). Reuses
///     `soko-seating-and-reading.webp`. Line: "Coming soon"
///     ([listsHubComingSoon]).
///
/// Spacing convention: 120 px gap above the tile — no dotted divider,
/// breaking the inter-shelf rhythm to mark the page's visual full-stop.
///
/// The widget claims full available width (`SizedBox(width: double.infinity)`)
/// so the centred Column reads correctly regardless of the parent's
/// `crossAxisAlignment` — `SearchResultsSection` uses `start` for the
/// 2-column grid above and would otherwise shrink the footer to its
/// widest child.
class DiscoveryFooter extends StatelessWidget {
  /// Asset path for the illustration tile.
  final String assetPath;

  /// Native size of the supplied asset. The tile renders at 115 × 115; the
  /// supplied [assetSize] is used to preserve aspect ratio when the source
  /// isn't square (e.g. `soko-walking-and-reading.webp` is 252 × 230).
  final Size assetSize;

  /// Whether the asset has a transparent background. When false, a
  /// [BlendMode.multiply] against the page colour is applied so the
  /// asset's opaque white surround collapses into the page.
  final bool assetHasTransparentBg;

  /// Which caption to render — selects the localized string in [build].
  ///
  /// Null for [DiscoveryFooter.captioned], where the caption comes from
  /// [_captionText] instead. Exactly one of the two is ever set.
  final _FooterCaption? _caption;

  /// A caption supplied by the caller rather than looked up in [Lt].
  ///
  /// PROD-4238: the server-driven feed's terminal card gets its copy from the
  /// wire (backend-localized, D7), so the app ships no ARB key for it and
  /// cannot render one on its own initiative.
  final String? _captionText;

  /// When true (default) the footer reserves 104 px of trailing breathing
  /// room so the gap between the caption and the bottom of the screen
  /// lands at ~200 px. Set to false when something else follows the
  /// footer in the same scroll (e.g. `DiscoveryEndActions` in PROD-1980)
  /// so that block can sit close to the caption.
  final bool hasTrailingGap;

  const DiscoveryFooter({super.key, this.hasTrailingGap = true})
    : assetPath = 'assets/images/illustrations/soko-seating-and-reading.webp',
      assetSize = const Size(506, 494),
      assetHasTransparentBg = true,
      _caption = _FooterCaption.thatsAll,
      _captionText = null;

  const DiscoveryFooter.doneLooking({super.key, this.hasTrailingGap = true})
    : assetPath = 'assets/images/illustrations/soko-walking-and-reading.webp',
      assetSize = const Size(252, 230),
      assetHasTransparentBg = false,
      _caption = _FooterCaption.doneLooking,
      _captionText = null;

  const DiscoveryFooter.comingSoon({super.key, this.hasTrailingGap = true})
    : assetPath = 'assets/images/illustrations/soko-seating-and-reading.webp',
      assetSize = const Size(506, 494),
      assetHasTransparentBg = true,
      _caption = _FooterCaption.comingSoon,
      _captionText = null;

  /// The feed's end-of-feed card, captioned from the backend (PROD-4238).
  ///
  /// Same chrome as [DiscoveryFooter] — the 115 px tile, the 42 px Season Mix
  /// line, the 120 px gap and no divider — with the copy supplied instead of
  /// read from [Lt]. `discoveryFooterEnd` deliberately stays in the ARBs for
  /// the two search/shelf screens that still use it; this constructor adds no
  /// key of its own.
  const DiscoveryFooter.captioned({
    super.key,
    required String caption,
    this.hasTrailingGap = true,
  }) : assetPath = 'assets/images/illustrations/soko-seating-and-reading.webp',
       assetSize = const Size(506, 494),
       assetHasTransparentBg = true,
       _caption = null,
       _captionText = caption;

  /// The ARB string for the enum variants. Only reached when [_captionText] is
  /// null, i.e. never for [DiscoveryFooter.captioned] — so that constructor
  /// pulls in no localization for a caption it already has.
  String _localizedCaption(BuildContext context) {
    final l10n = Lt.of(context);
    return switch (_caption!) {
      _FooterCaption.thatsAll => l10n.discoveryFooterEnd,
      _FooterCaption.doneLooking => l10n.discoveryFooterDoneLooking,
      _FooterCaption.comingSoon => l10n.listsHubComingSoon,
    };
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    // For opaque-background assets (e.g. `soko-walking-and-reading.webp`), multiply
    // blend with the page colour collapses the white surround into the
    // page. Transparent assets skip the blend and render as-is.
    // `DiscoveryShell` paints `AppColors.sokoPaper` (light) /
    // `AppColors.backgroundDark` (dark) on the Scaffold — match it here.
    final pageBg = isDark ? AppColors.backgroundDark : AppColors.sokoPaper;
    // Render at 115 logical px on the longest edge, scaling the other axis
    // to preserve the source aspect ratio.
    const targetMax = 115.0;
    final aspect = assetSize.width / assetSize.height;
    final renderWidth = aspect >= 1 ? targetMax : targetMax * aspect;
    final renderHeight = aspect >= 1 ? targetMax / aspect : targetMax;
    final caption = _captionText ?? _localizedCaption(context);
    // Trailing breathing room so the gap between the footer text and
    // the bottom of the screen (ignoring the overlaid bottom nav)
    // lands at 200 px. `DiscoveryScreen` already reserves 96 px via
    // `bottomNavReserve`; this 104 px brings the total to the spec
    // (96 + 104 = 200). Localised inside the footer so non-footer
    // Discovery rows keep the existing 96 px reserve.
    const trailingGap = 104.0;
    return SizedBox(
      // Claim the full available width so the centred Column doesn't
      // shrink-to-fit its widest child when the parent (e.g.
      // `SearchResultsSection`) uses `crossAxisAlignment: start`.
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 120),
          Image.asset(
            assetPath,
            width: renderWidth,
            height: renderHeight,
            fit: BoxFit.contain,
            color: assetHasTransparentBg ? null : pageBg,
            colorBlendMode: assetHasTransparentBg ? null : BlendMode.multiply,
          ),
          const SizedBox(height: 10),
          Text(
            caption,
            textAlign: TextAlign.center,
            style: AppTheme.displayPrimary(
              fontSize: 42,
              fontWeight: FontWeight.w300,
              color: inkColor,
              height: 0.94,
            ),
          ),
          if (hasTrailingGap) const SizedBox(height: trailingGap),
        ],
      ),
    );
  }
}

/// Caption variants for [DiscoveryFooter]. Internal — the public API
/// is the named constructors above.
enum _FooterCaption { thatsAll, doneLooking, comingSoon }
