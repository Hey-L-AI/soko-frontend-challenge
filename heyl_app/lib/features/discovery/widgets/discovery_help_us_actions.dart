import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../instagram_share/widgets/instagram_share_sheet.dart';
import '../../lists/widgets/import_list_sheet.dart';

/// Two full-width call-to-action pills inviting the user to contribute
/// places/posts that help Soko expand coverage. Rendered directly below
/// [DiscoveryNewCitySection] and gated by the same
/// `isCurrentCitySupportedProvider` check — the pills only appear when
/// the active city is not backend-marked "open"
/// (`GeoCity.isOpen == false`, PROD-1959 / PROD-3675). They sit
/// inside `DiscoveryScreen`'s conditional `!isCurrentCitySupportedProvider`
/// block, immediately after the Soko cartoon hero.
///
/// Figma container frame: `6353:29457` (400 × 86, 2 rows of 40 px with a
/// 6 px gap). Buttons:
///   - `6353:29458` — Soko/Yellow `#EDE77D`, `IconAddPin` + "Deixa-me
///     espreitar o teu Maps" — wired to [showImportListSheet] (PROD-1931).
///     Opens the Google Maps list-import bottom sheet; analytics source
///     is `discovery_help_us`. Replaces the earlier PROD-1850 coming-soon
///     stub now that the backend is live (`importGoogleMapsList`).
///   - `6353:29459` — Soko/Lilac `#E08EFB`, `IconIg` + "Envia-me um post" —
///     wired to [showInstagramShareSheet] (PROD-1863); same
///     `discovery_help_us` analytics source.
///
/// Historical context: an earlier iteration tried `showCreateStubSheet`
/// here, but a `showModalBottomSheet` triggered from a button near the
/// top of the discovery scroll rendered below the visible viewport (the
/// sheet is anchored to the scrollable's bottom, not the page overlay),
/// so a user who tapped from the top got no feedback. The current sheets
/// route through [showBottomSheetWithHiddenNav] with `useRootNavigator:
/// true` — they mount on the app's root Overlay and avoid the bug.
class DiscoveryHelpUsActions extends ConsumerWidget {
  /// Analytics `source` stamped on whichever sheet the reader opens.
  ///
  /// Defaults to this widget's original surface so the legacy Discovery call
  /// site keeps the value it has always sent. PROD-4319 renders the same two
  /// pills inside the feed's `create_cta` block and passes `feed_create_cta`,
  /// because sharing one value would make the two surfaces indistinguishable in
  /// the funnel exactly when you would want to compare them.
  final String source;

  const DiscoveryHelpUsActions({super.key, this.source = 'discovery_help_us'});

  /// Runs [open] only once the reader is a real user.
  ///
  /// ⚠️ **Both destinations reject a guest token**, and a guest carries a *real*
  /// bearer token — so nothing fails until submit: the sheet opened, the form
  /// filled, and the POST returned a generic 401 with no route to sign in. That
  /// dead end was live on the Discovery new-city hero (PROD-4319, found by codex
  /// while reviewing the feed block).
  ///
  /// [requireAuth] rather than hiding the pills: this widget sits directly under
  /// "Ajuda-me a conhecer o que há de melhor aqui", so hiding the buttons would
  /// leave the page asking for help and offering no way to give it. A guest gets
  /// the prompt sheet, and signing in returns them here able to contribute —
  /// which is the conversion the ask was for.
  void _gated(BuildContext context, WidgetRef ref, VoidCallback open) {
    requireAuth(
      context,
      ref,
      action: Lt.of(context).guestHelpUsContributeAction,
      referrer: AuthReferrer.guestHelpUsContribute,
      onAuthenticated: open,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Pill(
          svgAsset: 'assets/images/icons/discovery/icon-add-pin.svg',
          label: l10n.discoveryHelpUsMapsRequest,
          background: AppColors.sokoYellow,
          onTap: () => _gated(
            context,
            ref,
            () => showImportListSheet(context, ref: ref, source: source),
          ),
        ),
        const SizedBox(height: 6),
        _Pill(
          svgAsset: 'assets/images/icons/discovery/icon-ig.svg',
          label: l10n.discoveryHelpUsInstagramPost,
          background: AppColors.sokoLilac,
          onTap: () => _gated(
            context,
            ref,
            () => showInstagramShareSheet(context, ref: ref, source: source),
          ),
        ),
      ],
    );
  }
}

/// Full-width pill mirroring `BtSqIco` chrome (height 40, padding 14×10,
/// radius 6, gap 8) but rendering an SVG glyph instead of a Lucide
/// [IconData] and centering the icon+label pair.
class _Pill extends StatefulWidget {
  final String svgAsset;
  final String label;
  final Color background;
  final VoidCallback onTap;

  const _Pill({
    required this.svgAsset,
    required this.label,
    required this.background,
    required this.onTap,
  });

  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedScale(
          scale: _isPressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: widget.background,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                SvgPicture.asset(
                  widget.svgAsset,
                  width: 14,
                  height: 14,
                  colorFilter: const ColorFilter.mode(
                    AppColors.sokoInk,
                    BlendMode.srcIn,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w300,
                      height: 1.2,
                      letterSpacing: -0.14,
                      color: AppColors.sokoInk,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
