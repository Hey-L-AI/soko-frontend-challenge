import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../bt_sq_ico.dart';
import '../soko_cta_button.dart';
import 'ds_sheet_shell.dart';

/// Reusable empty/gated-state bottom sheet for deep links that can't open
/// their destination (PROD-2564, extracted from the PROD-2565 Daily Drop sheet).
///
/// One shell, two footer shapes:
/// - **info variants** (`cancelLabel == null`): a single full-width
///   [SokoCtaButton] (same shape as `add_to_list_sheet`'s Save). Dismissal is
///   via the drag handle / scrim.
/// - **action variants** (`cancelLabel != null`): the canonical [BtSqIco]
///   Cancel + primary pair (matching `login_prompt_sheet` / `delete_list_sheet`)
///   for cases where dismissing is a real choice (login / profiling).
///
/// Feature-specific copy + CTAs live in per-feature `show…Sheet` helpers (see
/// `daily_drop_deep_link_sheet.dart`, `weekly_bundle_deep_link_sheet.dart`);
/// this widget is pure presentation.
class DeepLinkEmptyStateSheet extends StatelessWidget {
  const DeepLinkEmptyStateSheet({
    super.key,
    required this.title,
    required this.body,
    required this.ctaLabel,
    this.ctaIcon,
    this.onCta,
    this.cancelLabel,
    this.content,
  });

  final String title;
  final String body;
  final String ctaLabel;
  final IconData? ctaIcon;

  /// Action run after the sheet pops. `null` = the CTA just dismisses
  /// (info variants, where the CTA simply closes onto the safe fallback).
  final VoidCallback? onCta;

  /// When set, the footer renders the canonical [BtSqIco] Cancel + primary
  /// pair for the action variants. When null, a single full-width
  /// [SokoCtaButton] is shown for the info variants.
  final String? cancelLabel;

  /// PROD-3730 — optional extra content between [body] and the footer.
  ///
  /// The shell was title + body + buttons only, which left nowhere to put a
  /// progress indicator or an inline toggle. Added for the Daily Drop
  /// generating sheet; PROD-3440's two window variants (`upcoming` /
  /// `closed`) are expected to reuse it rather than fork the shell.
  ///
  /// Null keeps the original three-part layout byte-for-byte.
  final Widget? content;

  @override
  Widget build(BuildContext context) {
    return DSSheetShell(
      // Canonical 14 px gap from button → sheet bottom (DS sticky-footer
      // convention); the bottom nav is already hidden by the wrapper.
      bodyPadding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              height: 1.0,
              letterSpacing: -0.36,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 14,
              fontWeight: FontWeight.w300,
              height: 1.2,
              letterSpacing: -0.14,
              color: AppColors.sokoInk,
            ),
          ),
          if (content != null) ...[const SizedBox(height: 16), content!],
          const SizedBox(height: 20),
          if (cancelLabel == null)
            // Single primary CTA (info variants) — canonical DS sheet CTA,
            // same shape as `add_to_list_sheet`'s Save. Dismissal is via the
            // drag handle / scrim.
            SokoCtaButton(
              label: ctaLabel,
              icon: ctaIcon,
              onPressed: () {
                Navigator.of(context).pop();
                onCta?.call();
              },
            )
          else
            // Cancel + primary pair (action variants) — same sticky-footer
            // BtSqIco row as `login_prompt_sheet` / `delete_list_sheet`.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: BtSqIco(
                    icon: LucideIcons.x,
                    label: cancelLabel!,
                    variant: BtSqIcoVariant.normal,
                    expand: true,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: BtSqIco(
                    icon: ctaIcon ?? LucideIcons.arrow_right,
                    label: ctaLabel,
                    variant: BtSqIcoVariant.selected,
                    expand: true,
                    onTap: () {
                      Navigator.of(context).pop();
                      onCta?.call();
                    },
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
