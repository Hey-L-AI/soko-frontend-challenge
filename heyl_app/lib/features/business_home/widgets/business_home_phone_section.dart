import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart' show AppRoutes;
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/account_provider.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import 'business_home_section_header.dart';

/// Phone-number section of the Business Home dashboard (PROD-4040 T2.1).
///
/// Surfaces whether the owner has a verified phone. The actual OTP add/verify
/// flow lives on `/menu/account` (auth methods); the return-state threading
/// for that flow is PROD-4040 T2.4. The screen owns the load-on-mount call.
class BusinessHomePhoneSection extends ConsumerWidget {
  const BusinessHomePhoneSection({super.key, this.sectionNumber});

  final String? sectionNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final phoneMethods = ref.watch(
      accountProvider.select((state) => state.phoneAuthMethods),
    );
    // A phone method being present counts as "done". The Account screen shows
    // its green check for any phone method and never reads `is_verified` — the
    // backend leaves that flag false/absent for OTP-login phones, so filtering
    // on it here left an owner who already has a verified phone staring at a
    // dead "Verify phone" CTA that just opens Account (PROD-4040 QA). Match the
    // Account screen: presence, not the untrusted flag.
    final verified = phoneMethods;

    // The verify/manage flow lives on /menu/account, pushed on top of this
    // still-mounted screen. Popping back runs no lifecycle here, and the screen
    // only loads auth methods once on mount — so a phone verified over there
    // would otherwise never refresh this reactive section. Re-fetch on return.
    Future<void> openAccount() async {
      await context.push(AppRoutes.menuAccount);
      ref.read(accountProvider.notifier).loadAuthMethods();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BusinessHomeSectionHeader(
          number: sectionNumber,
          title: l10n.businessHomePhoneTitle,
        ),
        const SizedBox(height: 12),
        if (verified.isNotEmpty)
          _VerifiedRow(
            phone: verified.first.authIdentifier,
            onManage: openAccount,
          )
        else ...[
          Text(
            l10n.businessHomePhoneDescription,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.sokoShade3,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          SokoCtaButton(
            icon: LucideIcons.smartphone,
            label: l10n.businessHomePhoneVerifyCta,
            variant: SokoCtaVariant.yellow,
            onPressed: openAccount,
          ),
        ],
      ],
    );
  }
}

class _VerifiedRow extends StatelessWidget {
  const _VerifiedRow({required this.phone, required this.onManage});

  final String phone;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.sokoInk8),
      ),
      child: Row(
        children: [
          const Icon(
            LucideIcons.circle_check,
            size: 18,
            color: AppColors.sokoGreen,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              phone.isNotEmpty
                  ? l10n.businessHomePhoneVerifiedWithNumber(phone)
                  : l10n.businessHomePhoneVerified,
              style: const TextStyle(fontSize: 14, color: AppColors.sokoInk),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: onManage,
            style: TextButton.styleFrom(foregroundColor: AppColors.sokoShade3),
            child: Text(l10n.businessHomePhoneManage),
          ),
        ],
      ),
    );
  }
}
