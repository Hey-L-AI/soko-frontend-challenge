import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/experiment_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../providers/venue_claim_provider.dart';
import 'venue_claim_sheet.dart';

/// Claim CTA + pending result state for a venue. It is intentionally absent
/// until the remote rollout flag and the authenticated server state agree.
class VenueClaimCta extends ConsumerWidget {
  const VenueClaimCta({
    super.key,
    required this.venueId,
    required this.venueName,
    this.showAction = true,
  });

  final String venueId;
  final String venueName;

  /// The compact action-grid affordance owns the claim button on venue pages.
  /// This widget still owns the pending-status notice in the original slot.
  final bool showAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(
      experimentServiceProvider.select(
        (state) => state.enableBusinessOwnership,
      ),
    );
    if (!enabled || !ref.watch(isAuthenticatedProvider)) {
      return const SizedBox.shrink();
    }

    final claimState = ref.watch(venueClaimStateProvider(venueId));
    return claimState.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (state) {
        if (state.isOwner) {
          return const SizedBox.shrink();
        }
        if (state.claim?.status == 'pending') {
          return const _ClaimPendingNotice();
        }
        if (state.claim?.status == 'rejected') {
          if (!showAction) return const _ClaimRejectedNotice();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _ClaimRejectedNotice(),
              const SizedBox(height: 20),
              SokoCtaButton(
                icon: LucideIcons.shield_check,
                label: Lt.of(context).businessOwnershipClaimCta,
                variant: SokoCtaVariant.ink,
                onPressed: () => showBottomSheetWithHiddenNav(
                  context: context,
                  ref: ref,
                  builder: (_) =>
                      VenueClaimSheet(venueId: venueId, venueName: venueName),
                ),
              ),
            ],
          );
        }
        if (state.claim?.status == 'verified') {
          return const SizedBox.shrink();
        }
        if (!showAction) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 20),
            SokoCtaButton(
              icon: LucideIcons.shield_check,
              label: Lt.of(context).businessOwnershipClaimCta,
              variant: SokoCtaVariant.ink,
              onPressed: () => showBottomSheetWithHiddenNav(
                context: context,
                ref: ref,
                builder: (_) =>
                    VenueClaimSheet(venueId: venueId, venueName: venueName),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ClaimPendingNotice extends StatelessWidget {
  const _ClaimPendingNotice();

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 20),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.sokoYellow,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      Lt.of(context).businessOwnershipClaimPending,
      style: const TextStyle(
        color: AppColors.sokoInk,
        fontSize: 14,
        height: 1.3,
      ),
    ),
  );
}

class _ClaimRejectedNotice extends StatelessWidget {
  const _ClaimRejectedNotice();

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 20),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.sokoYellow,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      Lt.of(context).businessOwnershipClaimRejected,
      style: const TextStyle(
        color: AppColors.sokoInk,
        fontSize: 14,
        height: 1.3,
      ),
    ),
  );
}
