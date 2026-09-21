import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';

/// PROD-2001 — bottom sheet prompting non-authenticated users to sign in
/// for gated actions (follow a list, save an item, etc.).
///
/// Visual matches the Soko sheet pattern (Figma `6453:14507`): paper
/// shell, Mobile/B1 Bold title on `sokoInk`, Mobile/B2 Reg subtitle on
/// `sokoInk`, and a paired [BtSqIco] action row — idle "Cancel" + Soko/
/// Pink "selected" Sign-In with a leading log-in glyph. Uses the
/// canonical DS button so the sheet stays in lock-step with every other
/// `BtSqIco` surface (list action bar, create-zine, add-items footer).
class LoginPromptSheet extends StatelessWidget {
  /// The action the user was trying to perform (e.g., "follow this list")
  final String action;

  /// Callback when user taps sign in button
  final VoidCallback onLogin;

  const LoginPromptSheet({
    super.key,
    required this.action,
    required this.onLogin,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return DSSheetShell(
      // Canonical 14 px gap from buttons → sheet bottom (DS sticky-
      // footer convention). The bottom nav is already hidden by
      // `showBottomSheetWithHiddenNav`, so no extra clearance needed.
      bodyPadding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Title — Soko/Ink, Zalando Sans Bold, 18 px, line-height 1,
          // letter-spacing -0.36. Heavier weight than the Figma's
          // Mobile/B1 Medium so the sheet's primary message reads with
          // more emphasis (per direct designer feedback).
          Text(
            l10n.loginPromptOpenSokoTitle(action),
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

          // Subtitle — Mobile/B2 Reg (Zalando Sans Light 14, line-height
          // 1.2, letter-spacing -0.14) on sokoInk.
          Text(
            l10n.loginPromptOpenSokoSubtitle,
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
          const SizedBox(height: 20),

          // Paired full-width action row — normal Cancel (× icon) +
          // selected Sign In (log-in icon), 12 px gap, each Expanded so
          // they split the row 50/50. Matches the sticky-footer pattern
          // used by location-scope picker, import-list, and
          // Instagram-share sheets.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: BtSqIco(
                  icon: LucideIcons.x,
                  label: l10n.listActionCancel,
                  variant: BtSqIcoVariant.normal,
                  expand: true,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: BtSqIco(
                  icon: LucideIcons.log_in,
                  label: l10n.authButtonSignIn,
                  variant: BtSqIcoVariant.selected,
                  expand: true,
                  onTap: () {
                    Navigator.of(context).pop(true);
                    onLogin();
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

/// Show the login prompt bottom sheet.
///
/// Returns `true` if the user tapped "Sign in", or `null` if dismissed
/// (Cancel, swipe down, tap outside, back button).
Future<bool?> showLoginPromptSheet(
  BuildContext context, {
  required WidgetRef ref,
  required String action,
  required VoidCallback onLogin,
}) {
  return showBottomSheetWithHiddenNav<bool>(
    context: context,
    ref: ref,
    builder: (context) => LoginPromptSheet(action: action, onLogin: onLogin),
  );
}
