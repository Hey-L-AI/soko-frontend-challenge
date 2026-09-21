import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../venue_claim/providers/venue_claim_provider.dart';
import '../providers/business_venue_providers.dart';
import 'business_home_section_header.dart';
import 'business_venue_search.dart';

/// "Your venues" section of the Business Home dashboard (PROD-4040 T2.1 + T2.2):
/// the search → claim entry, the caller's owned venues (each opens the owner
/// edit surface), and any venues still awaiting approval.
class BusinessVenuesSection extends ConsumerStatefulWidget {
  const BusinessVenuesSection({super.key, this.sectionNumber});

  final String? sectionNumber;

  @override
  ConsumerState<BusinessVenuesSection> createState() =>
      _BusinessVenuesSectionState();
}

class _BusinessVenuesSectionState extends ConsumerState<BusinessVenuesSection> {
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(ownedBusinessProfileEntriesProvider);
    ref.invalidate(businessPendingClaimsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final owned = ref.watch(ownedBusinessProfileEntriesProvider);
    final pending = ref.watch(businessPendingClaimsProvider);
    final ownedList = owned.valueOrNull ?? const [];
    final pendingList = pending.valueOrNull ?? const [];
    final hasAny = ownedList.isNotEmpty || pendingList.isNotEmpty;
    final settling = owned.isLoading || pending.isLoading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BusinessHomeSectionHeader(
          number: widget.sectionNumber,
          title: l10n.businessHomeVenuesTitle,
        ),
        const SizedBox(height: 14),
        BusinessVenueSearch(focusNode: _searchFocus, onChanged: _refresh),
        const SizedBox(height: 12),
        if (!hasAny && !settling)
          _EmptyVenues(subtitle: l10n.businessHomeVenuesEmptyHint)
        else ...[
          for (final entry in ownedList)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _OwnedVenueCard(entry: entry),
            ),
          for (final entry in pendingList)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _PendingVenueCard(entry: entry),
            ),
          if (hasAny)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _searchFocus.requestFocus,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.sokoInk,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
                icon: const Icon(LucideIcons.plus, size: 16),
                label: Text(l10n.businessHomeAddAnother),
              ),
            ),
        ],
      ],
    );
  }
}

class _VenueCardShell extends StatelessWidget {
  const _VenueCardShell({required this.child, this.onTap, this.dimmed = false});

  final Widget child;
  final VoidCallback? onTap;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: dimmed ? 0.8 : 1,
      child: Material(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.sokoInk8),
            ),
            padding: const EdgeInsets.all(14),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _VenueThumb extends StatelessWidget {
  const _VenueThumb({this.imageUrl});

  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 52,
        height: 52,
        child: (url != null && url.isNotEmpty)
            ? Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const _ThumbPlaceholder(),
              )
            : const _ThumbPlaceholder(),
      ),
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.sokoShade4,
      child: Icon(LucideIcons.store, size: 20, color: AppColors.sokoShade3),
    );
  }
}

class _OwnedVenueCard extends StatelessWidget {
  const _OwnedVenueCard({required this.entry});

  final OwnedBusinessProfileEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final venue = entry.venue;
    final name = venue?.name ?? entry.business.name;
    final address = venue?.address;
    void openVenue() => context.push('/venues/${entry.venueId}');

    return _VenueCardShell(
      onTap: openVenue,
      child: Row(
        children: [
          _VenueThumb(imageUrl: venue?.imageUrl),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontFamily: 'UnJamoBatang',
                    fontSize: 19,
                    color: AppColors.sokoInk,
                  ),
                ),
                if (address != null && address.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    address,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.sokoShade3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              color: AppColors.sokoGreen,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              LucideIcons.check,
              size: 14,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(width: 10),
          _EditVenueButton(onTap: openVenue, label: l10n.businessHomeEditVenue),
        ],
      ),
    );
  }
}

class _EditVenueButton extends StatelessWidget {
  const _EditVenueButton({required this.onTap, required this.label});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.sokoPink,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.sokoInk,
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingVenueCard extends StatelessWidget {
  const _PendingVenueCard({required this.entry});

  final PendingClaimEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final venue = entry.venue;
    final name = venue?.name ?? l10n.businessHomeVenueFallbackName;
    final address = venue?.address;

    return _VenueCardShell(
      dimmed: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _VenueThumb(imageUrl: venue?.imageUrl),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontFamily: 'UnJamoBatang',
                    fontSize: 19,
                    color: AppColors.sokoInk,
                  ),
                ),
                if (address != null && address.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    address,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.sokoShade3,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  l10n.businessHomeApprovalHint,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.sokoShade3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.sokoYellow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              l10n.businessHomeUnderApproval,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.sokoInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyVenues extends StatelessWidget {
  const _EmptyVenues({required this.subtitle});

  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.sokoInk8, width: 1.5),
      ),
      child: Column(
        children: [
          const Icon(LucideIcons.store, size: 28, color: AppColors.sokoShade3),
          const SizedBox(height: 12),
          Text(
            l10n.businessHomeVenuesEmptyTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'UnJamoBatang',
              fontSize: 20,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: AppColors.sokoShade3),
          ),
        ],
      ),
    );
  }
}
