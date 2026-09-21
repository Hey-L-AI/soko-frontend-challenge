import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/experiment_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/social_proof.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/soko_tag.dart';
import '../providers/venue_claim_provider.dart';
import 'venue_owner_edit_sheet.dart';

/// Ownership marker and editor access for venues owned by the signed-in user.
class VenueOwnerAffordance extends ConsumerWidget {
  const VenueOwnerAffordance({
    super.key,
    required this.venue,
    required this.onSaved,
  });

  final VenueDetailResponse venue;
  final VoidCallback onSaved;

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
    final owned = ref.watch(ownedVenueIdsProvider);
    return owned.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (ids) {
        if (!ids.contains(venue.id)) return const SizedBox.shrink();
        final l10n = Lt.of(context);
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SokoTag(
                background: AppColors.sokoGreen,
                leading: const Icon(LucideIcons.check, size: 12),
                child: Text(
                  l10n.businessOwnershipManagedTag,
                  style: SokoTag.textStyleCompact,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: l10n.businessOwnershipEditTitle,
                onPressed: () => showBottomSheetWithHiddenNav(
                  context: context,
                  ref: ref,
                  builder: (_) =>
                      VenueOwnerEditSheet(venue: venue, onSaved: onSaved),
                ),
                icon: const Icon(LucideIcons.pencil, size: 17),
              ),
            ],
          ),
        );
      },
    );
  }
}
