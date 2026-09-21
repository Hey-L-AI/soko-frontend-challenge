import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/experiment_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/widgets/cached_image.dart';
import '../../../shared/widgets/clickable.dart';
import '../../profile/utils/profile_style.dart';
import '../providers/venue_claim_provider.dart';

/// Compact, horizontally-scrollable entry point to venues the current user
/// owns. It is intentionally absent for non-owners instead of showing an
/// empty state on a personal profile.
class OwnedBusinessesProfileShelf extends ConsumerWidget {
  const OwnedBusinessesProfileShelf({super.key});

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

    final businesses = ref.watch(ownedBusinessProfileEntriesProvider);
    return businesses.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (entries) {
        if (entries.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 0, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text(
                  Lt.of(context).businessOwnershipMyBusinessesTitle,
                  style: Pt.b1,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 174,
                child: ListView.separated(
                  key: const ValueKey('owned-businesses-profile-shelf'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(right: 16),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, index) =>
                      _OwnedBusinessCard(entry: entries[index]),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OwnedBusinessCard extends StatelessWidget {
  const _OwnedBusinessCard({required this.entry});

  final OwnedBusinessProfileEntry entry;

  @override
  Widget build(BuildContext context) {
    final venue = entry.venue;
    final subtitleParts = <String>[
      if (venue?.tags?.isNotEmpty ?? false) venue!.tags!.first,
      if (venue?.city?.isNotEmpty ?? false) venue!.city!,
    ];
    final subtitle = subtitleParts.join(' · ');
    final name = venue?.name.isNotEmpty == true
        ? venue!.name
        : entry.business.name;
    final imageUrl = venue?.imageUrl;
    final radius = BorderRadius.circular(6);

    return SizedBox(
      width: 148,
      child: Semantics(
        button: true,
        label: name,
        child: Clickable(
          onTap: () => context.push('/venues/${entry.venueId}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: radius,
                child: SizedBox(
                  width: 148,
                  height: 104,
                  child: imageUrl == null || imageUrl.isEmpty
                      ? const _BusinessArtworkFallback()
                      : CachedImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          errorWidget: const _BusinessArtworkFallback(),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Pt.b2Bold,
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Pt.b2.copyWith(
                    color: AppColors.sokoInk.withValues(alpha: 0.5),
                  ),
                ),
              ],
              const SizedBox(height: 3),
              Icon(
                LucideIcons.circle_check,
                size: 16,
                color: AppColors.sokoGreen,
                semanticLabel: Lt.of(context).businessOwnershipManagedTag,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BusinessArtworkFallback extends StatelessWidget {
  const _BusinessArtworkFallback();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: AppColors.sokoLight2,
    child: Center(
      child: Icon(
        LucideIcons.store,
        color: AppColors.sokoInk.withValues(alpha: 0.5),
        size: 28,
      ),
    ),
  );
}
