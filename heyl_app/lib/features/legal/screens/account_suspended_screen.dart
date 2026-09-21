import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_cta_button.dart';

/// PROD-2264 — Landing screen shown after a 403 [ModerationError]
/// `USER_SUSPENDED` / `USER_BANNED` response. The user has already
/// been force-logged-out by the time this renders. Read-only: there
/// is no path back into the authenticated app from here; the only
/// affordance is "Contact support".
class AccountSuspendedScreen extends StatelessWidget {
  const AccountSuspendedScreen({super.key});

  Future<void> _openSupport() async {
    final uri = Uri.parse('mailto:support@soko.fyi');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  LucideIcons.octagon_alert,
                  size: 64,
                  color: AppColors.sokoInkSecondary,
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.accountSuspendedTitle,
                  textAlign: TextAlign.center,
                  style: AppTheme.displayPrimary(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: AppColors.sokoInk,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.accountSuspendedBody,
                  textAlign: TextAlign.center,
                  style: AppTheme.body(
                    fontSize: 15,
                    color: AppColors.sokoInk,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 32),
                SokoCtaButton(
                  label: l10n.accountSuspendedContactSupport,
                  icon: LucideIcons.mail,
                  onPressed: _openSupport,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
