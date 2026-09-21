import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/social_proof_provider.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/social_proof_row.dart'
    show SocialProofBadge, SocialProofListsLabel;
import '../../../shared/widgets/soko_card_image.dart';
import 'add_to_list_sheet.dart';

/// Card widget for displaying a list item in cards view
/// Designed to match the chat PlaceCard style for consistency
class ListItemCard extends ConsumerWidget {
  final UserListItem item;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final bool isReadOnly;

  /// Whether this item is saved in any of the user's owned lists
  final bool isSaved;

  const ListItemCard({
    super.key,
    required this.item,
    this.onTap,
    this.onRemove,
    this.isReadOnly = false,
    this.isSaved = false,
  });

  void _showAddToListSheet(BuildContext context, WidgetRef ref) {
    // Convert UserListItem to ItemSuggestion for the add-to-list sheet
    final place = ItemSuggestion(
      id: item.venueId ?? item.eventId ?? item.id,
      type: item.itemType == SavedItemType.event ? 'event' : 'place',
      eventId: item.eventId,
      venueId: item.venueId,
      name: item.title ?? '',
      imageUrl: item.imageUrl,
      category: item.category,
      address: item.address,
      city: item.city,
      latitude: item.latitude,
      longitude: item.longitude,
      // PROD-3829: forward the facet so a re-save from this surface keeps it.
      primaryFacet: item.primaryFacet,
    );
    // PROD-3873 — card bookmark: quicksave on tap, half-open peek on a fresh
    // save (full when managing an already-saved item).
    showAddToListSheet(
      context,
      place,
      ref: ref,
      source: ListSource.listUi,
      quickSaveIfUnsaved: true,
      skipDrawerWhenSaving: true,
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark ? AppColors.surfaceDark : AppColors.surface;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final textSecondaryColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final textTertiaryColor = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;

    return Clickable(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Image section - fixed aspect ratio for consistency
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  SokoCardImage(
                    imageUrl: item.imageUrl,
                    seed: item.venueId ?? item.eventId ?? item.id,
                    kind: SokoEntityKind.fromSavedType(item.itemType),
                  ),

                  // Gradient overlay
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.1),
                          Colors.black.withValues(alpha: 0.5),
                        ],
                      ),
                    ),
                  ),

                  // Type indicator (bottom-left)
                  Positioned(
                    bottom: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: item.itemType == SavedItemType.event
                            ? primaryColor.withValues(alpha: 0.9)
                            : AppColors.info.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            item.itemType == SavedItemType.event
                                ? Icons.event
                                : Icons.place,
                            size: 9,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            item.itemType == SavedItemType.event
                                ? l10n.listDetailFilterEvents
                                : l10n.listDetailFilterPlaces,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Bookmark button (top-left) - shows save state
                  Positioned(
                    top: 4,
                    left: 4,
                    child: Clickable(
                      onTap: () => _showAddToListSheet(context, ref),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: isSaved
                              ? primaryColor.withValues(alpha: 0.9)
                              : Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isSaved ? Icons.bookmark : Icons.bookmark_border,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),

                  // Save count badge (top-right)
                  ..._buildSaveCountBadge(ref),

                  // Remove button (top-right, offset if badge present) - hidden in read-only mode
                  if (onRemove != null && !isReadOnly)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Clickable(
                        onTap: onRemove,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Content section - compact
            Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Title
                  Text(
                    item.title ?? l10n.listDetailItemTitleFallback,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),

                  // Rating for places OR Date for events
                  if (item.itemType == SavedItemType.place &&
                      item.rating != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(Icons.star, size: 10, color: AppColors.amber),
                          const SizedBox(width: 2),
                          Text(
                            item.rating!.toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 9,
                              color: textSecondaryColor,
                            ),
                          ),
                          if (item.ratingCount != null)
                            Text(
                              ' (${item.ratingCount})',
                              style: TextStyle(
                                fontSize: 8,
                                color: textTertiaryColor,
                              ),
                            ),
                        ],
                      ),
                    )
                  else if (item.itemType == SavedItemType.event &&
                      item.eventDate != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(
                            Icons.schedule,
                            size: 10,
                            color: textTertiaryColor,
                          ),
                          const SizedBox(width: 2),
                          Expanded(
                            child: Text(
                              _formatDate(item.eventDate!),
                              style: TextStyle(
                                fontSize: 9,
                                color: textSecondaryColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Category or location (single line)
                  if (item.category != null ||
                      item.city != null ||
                      item.address != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        item.category ?? item.city ?? item.address ?? '',
                        style: TextStyle(fontSize: 9, color: textTertiaryColor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),

                  // Social proof
                  _buildSocialProof(ref),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  SocialProof? _getSocialProof(WidgetRef ref) {
    final entityId = item.venueId ?? item.eventId;
    if (entityId == null) return null;

    final type = item.itemType == SavedItemType.event ? 'event' : 'place';
    final proof = ref.watch(socialProofProvider)[entityId];

    if (proof == null) {
      ref.read(socialProofProvider.notifier).getSocialProof(entityId, type);
    }
    return proof;
  }

  Widget _buildSocialProof(WidgetRef ref) {
    final proof = _getSocialProof(ref);
    if (proof == null) return const SizedBox.shrink();
    final type = item.itemType == SavedItemType.event ? 'event' : 'place';
    return SocialProofListsLabel(proof: proof, itemType: type);
  }

  List<Widget> _buildSaveCountBadge(WidgetRef ref) {
    final proof = _getSocialProof(ref);
    if (proof == null || proof.saveCount <= 0) return [];
    return [
      Positioned(top: 4, right: 4, child: SocialProofBadge(proof: proof)),
    ];
  }
}
