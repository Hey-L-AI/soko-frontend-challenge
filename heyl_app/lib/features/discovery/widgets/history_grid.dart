import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/entity_ref.dart';
import '../../../providers/entity_image_cache_provider.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../providers/history_grid_provider.dart';

/// Discovery — History grid (PROD-1521). A 2-column × 3-row grid of compact
/// 197×60 cards (image + label) backed by `GET /users/me/activity`. Hides
/// itself silently on error or when the user has no recent activity — the
/// grid is a personal feed and there's no editorial fallback to surface.
///
/// Cards click-dispatch on `EntityRef.type`: venues push `/venues/<id>`,
/// events push `/events/<id>`, lists push the list-detail route.
///
/// Layout-shift handling (PROD-1518): the body is wrapped in
/// `AnimatedSize` so the loading → empty / error transition animates a
/// collapse instead of dropping shelves below by ~190 px in a single
/// frame.
class HistoryGrid extends ConsumerWidget {
  const HistoryGrid({super.key});

  /// Per-card sizing from the Figma capture (node 3932:1955).
  static const double _cardHeight = 60;
  static const double _cardGap = 5;
  static const double _thumbnailWidth = 46;
  static const double _cardRadius = 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(historyGridProvider);

    final body = asyncItems.when(
      loading: () => const _HistoryGridSkeleton(),
      error: (_, __) => const SizedBox.shrink(),
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        // Render exactly the items returned (max 6); the BE may return fewer
        // than the requested limit when entities have been deleted.
        final visible = items.take(6).toList();
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _HistoryGridLayout(
            children: [
              for (var i = 0; i < visible.length; i++)
                _HistoryCard(item: visible[i], index: i),
            ],
          ),
        );
      },
    );

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: body,
    );
  }
}

/// Lays out up to 6 children in a 2-column × 3-row grid with 5 px gaps. The
/// row count tracks the number of items so a 4-card response only renders
/// 2 rows (no trailing blank row).
class _HistoryGridLayout extends StatelessWidget {
  final List<Widget> children;
  const _HistoryGridLayout({required this.children});

  @override
  Widget build(BuildContext context) {
    const gap = HistoryGrid._cardGap;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      final left = children[i];
      final right = (i + 1 < children.length) ? children[i + 1] : null;
      rows.add(
        Row(
          children: [
            Expanded(child: left),
            const SizedBox(width: gap),
            Expanded(child: right ?? const SizedBox.shrink()),
          ],
        ),
      );
      if (i + 2 < children.length) rows.add(const SizedBox(height: gap));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

class _HistoryCard extends ConsumerWidget {
  final EntityRef item;
  final int index;
  const _HistoryCard({required this.item, required this.index});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    final analytics = ref.read(unifiedAnalyticsProvider);

    // Fall back to the cross-surface URL cache populated by the
    // item-detail sheet (venues + events) and the list-detail screen
    // (lists). Near You / Spaces use the same trick when the feed
    // payload's image_url is null on cold-cache entries.
    final cachedUrl = ref.watch(entityImageCacheProvider)[item.type]?[item.id];
    final resolvedImageUrl = item.imageUrl ?? cachedUrl;

    final canOpen = item.type != EntityKind.unknown;
    return Clickable(
      onTap: canOpen
          ? () {
              analytics.trackDiscoveryHistoryCardClicked(
                cardIndex: index,
                itemId: item.id,
                itemType: _itemTypeLabel(item.type),
              );
              _openItem(context, item);
            }
          : null,
      child: Container(
        height: HistoryGrid._cardHeight,
        decoration: BoxDecoration(
          color: AppColors.sokoShade5,
          borderRadius: BorderRadius.circular(HistoryGrid._cardRadius),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            _Thumbnail(
              imageUrl: resolvedImageUrl,
              seed: item.id,
              kind: _floorKindFor(item.type),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9),
                child: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.body(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    height: 1.0,
                    color: inkColor,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final String? imageUrl;
  final String seed;
  final SokoEntityKind kind;
  const _Thumbnail({
    required this.imageUrl,
    required this.seed,
    required this.kind,
  });

  @override
  Widget build(BuildContext context) {
    // Type-aware brand floor + texture beneath the thumbnail; on a missing
    // or failed image the floor stays — never a broken-image icon.
    return SokoCardImage(
      imageUrl: imageUrl,
      seed: seed,
      kind: kind,
      width: HistoryGrid._thumbnailWidth,
      height: HistoryGrid._cardHeight,
    );
  }
}

/// Map the activity-feed [EntityKind] to the card floor colour. Lists and
/// unknown rows fall back to the neutral floor.
SokoEntityKind _floorKindFor(EntityKind kind) => switch (kind) {
  EntityKind.venue => SokoEntityKind.venue,
  EntityKind.event => SokoEntityKind.event,
  EntityKind.list || EntityKind.unknown => SokoEntityKind.neutral,
};

class _HistoryGridSkeleton extends StatelessWidget {
  const _HistoryGridSkeleton();

  @override
  Widget build(BuildContext context) {
    final placeholders = List.generate(6, (_) => _SkeletonCard());
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: _HistoryGridLayout(children: placeholders),
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: HistoryGrid._cardHeight,
      decoration: BoxDecoration(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(HistoryGrid._cardRadius),
      ),
    );
  }
}

void _openItem(BuildContext context, EntityRef item) {
  switch (item.type) {
    case EntityKind.venue:
      // Routed full-screen venue detail page (PROD-1670). Same admin
      // gate as `/discovery`, so this swap is safe inside Discovery.
      context.push('/venues/${item.id}');
      return;
    case EntityKind.event:
      // Routed full-screen event detail page (PROD-1671). Same admin
      // gate as `/discovery`, so this swap is safe inside Discovery.
      context.push('/events/${item.id}');
      return;
    case EntityKind.list:
      // The list-detail route accepts either slug or id. EntityRef carries
      // only id, so push by id.
      context.push('/lists/${item.id}', extra: const {'referrer': '/'});
      return;
    case EntityKind.unknown:
      return;
  }
}

String _itemTypeLabel(EntityKind kind) {
  switch (kind) {
    case EntityKind.venue:
      return 'venue';
    case EntityKind.event:
      return 'event';
    case EntityKind.list:
      return 'list';
    case EntityKind.unknown:
      return 'unknown';
  }
}
