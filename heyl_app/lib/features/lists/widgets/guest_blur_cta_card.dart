import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../l10n/generated/l10n.dart';

/// Shared sign-in card shown over blurred guest content. Used by both
/// [GuestListGateOverlay] (list-view tail) and the per-page blur on
/// zine item pages so the two surfaces stay visually in sync.
///
/// PROD-1979 — restyled onto the Soko token system: 6 px corners
/// (matching [BtSqIco] / shelf cards), `sokoPaper` surface, `sokoInk`
/// text, `sokoPink` selected-button fill, and the Soko brand mark as
/// the leading badge instead of a generic lock icon.
///
/// [compact] trims the inner padding + brand size for the zine page
/// variant, where the card sits over a single item card rather than a
/// stacked column of hidden rows.
///
/// [titleOverride] / [subtitleOverride] let surfaces (e.g. the guest
/// Daily Drop) substitute their own copy while keeping the rest of the
/// chrome consistent.
class GuestBlurCtaCard extends ConsumerWidget {
  /// Tap handler for the sign-in button.
  ///
  /// If null, falls back to [navigateToLoginPreservingReturn] — a hard nav
  /// is right here (the blur card *is* the explanation surface), but it
  /// must preserve the return URL or OAuth drops the user on `/home`
  /// instead of back on the zine they were reading (PROD-3142).
  final VoidCallback? onSignIn;
  final bool compact;
  final String? titleOverride;
  final String? subtitleOverride;

  const GuestBlurCtaCard({
    super.key,
    this.onSignIn,
    this.compact = false,
    this.titleOverride,
    this.subtitleOverride,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Soko tokens. Light mode is the dominant theme for the webapp —
    // dark mode swaps the surface to `sokoInk` and the brand mark to
    // the paper variant so the card stays readable.
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    final surfaceColor = isDark ? AppColors.sokoInk : AppColors.sokoPaper;
    final secondaryTextColor = inkColor.withValues(alpha: 0.6);
    final brandAsset = isDark
        ? 'assets/images/logos/soko-icon-paper.svg'
        : 'assets/images/logos/soko-icon-blood-1.svg';

    // PROD-1979 — Soko brand mark sits in the top-left as a small badge
    // rather than a circle-framed icon. "Very small character" per
    // product direction; the SVG is the same one the bottom nav uses.
    final brandSize = compact ? 18.0 : 22.0;
    final innerPadding = compact
        ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12)
        : const EdgeInsets.symmetric(horizontal: 16, vertical: 14);

    return Container(
      padding: innerPadding,
      decoration: BoxDecoration(
        color: surfaceColor,
        // 6 px corner radius — matches BtSqIco + shelf-card chrome
        // (Soko design system standard radius for filled surfaces).
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: inkColor.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: AppColors.sokoInk.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SvgPicture.asset(brandAsset, width: brandSize, height: brandSize),
          const SizedBox(height: 8),
          Text(
            titleOverride ?? l10n.guestListBlurTitle,
            textAlign: TextAlign.center,
            style: AppTheme.body(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: inkColor,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitleOverride ?? l10n.guestListBlurSubtitle,
            textAlign: TextAlign.center,
            style: AppTheme.body(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: secondaryTextColor,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 12),
          _SokoSignInButton(
            onTap:
                onSignIn ??
                () => navigateToLoginPreservingReturn(
                  context,
                  ref,
                  referrer: AuthReferrer.guestListBlurCta,
                ),
            label: l10n.authButtonSignIn,
          ),
        ],
      ),
    );
  }
}

/// Soko-styled sign-in button. Mirrors [BtSqIcoVariant.selected]: filled
/// `sokoPink` with `sokoInk` label, 6 px corner radius, 40 px tall.
/// Inlined here (rather than reusing [BtSqIco]) because this button has
/// no leading icon and the parent layout drives the width.
class _SokoSignInButton extends StatefulWidget {
  final VoidCallback onTap;
  final String label;

  const _SokoSignInButton({required this.onTap, required this.label});

  @override
  State<_SokoSignInButton> createState() => _SokoSignInButtonState();
}

class _SokoSignInButtonState extends State<_SokoSignInButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: _pressed
                ? AppColors.sokoPink.withValues(alpha: 0.85)
                : AppColors.sokoPink,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: AppTheme.body(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.sokoInk,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}
