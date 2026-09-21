import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/services/experiment_service.dart';
import '../../../../data/models/models.dart';
import '../../../../data/models/resolved_search_location.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/entity_image_cache_provider.dart';
import '../../../../providers/location_provider.dart';
import '../../../../providers/resolved_search_location_provider.dart';
import '../../../../shared/widgets/soko_card_image.dart';
import '../../../../shared/widgets/impression_detector.dart';
import '../../providers/near_you_context_provider.dart';
import '../../providers/near_you_places_shelf_provider.dart';
import '../../screens/shelf_see_more_screen.dart';
import 'discovery_shelf.dart';
import 'near_you_card.dart';
import 'near_you_coarse_location_prompt.dart';
import 'near_you_location_cta.dart';
import 'shelf_see_more_tile.dart';
import 'show_hidden_button.dart';

/// "Near you" places shelf (PT-PT: "Perto de ti", PT-BR: "Perto de você")
/// — proximity-ordered venue cards from `/feed/near-you/places`
/// (PROD-1963). An explicit search center names its most-specific resolved
/// place ("Near Estrela" / "Around Estrela"); automatic/GPS scope keeps the
/// generic "Near you" / "Nearby" copy. Hides itself when the user hasn't
/// shared location. Pagination is append-only via the trailing see-more tile.
class NearYouPlacesShelf extends ConsumerWidget {
  const NearYouPlacesShelf({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final state = ref.watch(nearYouPlacesShelfProvider);
    final shelfContext = ref.watch(nearYouContextProvider).valueOrNull;
    final searchLocation = ref
        .watch(resolvedSearchLocationProvider)
        .valueOrNull;

    // Hide entirely without location — proximity feed has nothing to
    // show. Other shelves still render above and below.
    if (!state.hasLocation && !state.isInitialLoading) {
      return const SizedBox.shrink();
    }

    final notifier = ref.read(nearYouPlacesShelfProvider.notifier);
    final analytics = ref.read(unifiedAnalyticsProvider);
    final title = nearYouPlacesTitle(
      l10n: l10n,
      shelfContext: shelfContext,
      searchLocation: searchLocation,
    );

    // Show the toggle whenever this load hid ANY venue (dropped.total). The
    // count line ("N really close") shows only when the salient within-250 m
    // count is non-zero. Both are preserved across the toggle so the button
    // stays put while showing the raw feed.
    final showHiddenButton = state.hiddenTotal > 0;

    // The shelf renders at most 10 cards; deeper content lives on the
    // vertical see-more page behind the trailing tile.
    final visibleCount = state.items.length > kDiscoveryShelfMaxVisibleItems
        ? kDiscoveryShelfMaxVisibleItems
        : state.items.length;
    final showSeeMore =
        state.hasMore || state.items.length > kDiscoveryShelfMaxVisibleItems;
    // PROD-4083 — gate the CTA on permission, not just fix precision, so a
    // granted-but-coarse user isn't told "location sharing disabled" while the
    // OS is actively sharing their (coarse) location.
    final locationState = ref.watch(locationProvider);
    final showLocationCta =
        !state.isInitialLoading &&
        shouldShowNearYouLocationCta(
          context: shelfContext,
          location: locationState,
        ) &&
        ref.watch(experimentServiceProvider).enableLocationSuggestionBanner;

    // PROD-4083 — permission granted but the fix is only a coarse GPS reading.
    // `NearYouCoarseLocationPrompt` silently tries to upgrade it (no prompt) and,
    // only for the iOS "Precise Location off" case, shows an actionable prompt.
    // Gated on `!isInitialLoading` so nothing surfaces mid-acquisition (the shelf
    // holds its loading state during the awaiting-precise-fix window).
    final showCoarsePrompt =
        !state.isInitialLoading && locationState.isGpsApproximate;

    final shelf = DiscoveryShelf(
      shelfId: 'near_you_places',
      title: title,
      titleTrailing: showHiddenButton
          ? ShowHiddenButton(
              countLabel: state.hiddenCount > 0
                  ? l10n.discoveryHiddenNearbyLabel(state.hiddenCount)
                  : null,
              active: !state.personalized,
              isLoading: state.isInitialLoading || state.isToggling,
              onTap: notifier.togglePersonalized,
            )
          : null,
      isLoading: state.isInitialLoading,
      error: state.error,
      itemCount: visibleCount,
      cardWidth: NearYouCard.imageWidth,
      cardHeight: NearYouCard.totalHeight,
      visibleCardsHint: 3.5,
      cardHeightForWidth: NearYouCard.heightForWidth,
      // PROD-2606 — placeholder cover sizes from width, not row height.
      cardImageHeightForWidth: NearYouCard.imageHeightForWidth,
      onRetry: notifier.refresh,
      // `onLoadMore` stays wired ONLY so the paged row keeps the
      // show-hidden scroll anchoring ([itemIdAt]); with `hasMore` left at
      // its false default the auto-pagination never fires. Deeper content
      // is reached via the trailing "Ver mais" tile instead.
      onLoadMore: notifier.loadMore,
      itemIdAt: (index) => state.items[index].id,
      personalized: state.personalized,
      // Title + chevron open the same see-more page as the trailing tile.
      onSeeMore: showSeeMore
          ? () {
              analytics.trackDiscoveryShelfSeeMoreClicked(
                shelfId: 'near_you_places',
              );
              context.push(SeeMoreShelf.nearYouPlaces.routePath);
            }
          : null,
      trailingTileBuilder: showSeeMore
          ? (context, cellWidth, rowHeight, imageHeight) => ShelfSeeMoreTile(
              cellWidth: cellWidth,
              rowHeight: rowHeight,
              imageHeight: imageHeight,
              onTap: () {
                analytics.trackDiscoveryShelfSeeMoreClicked(
                  shelfId: 'near_you_places',
                );
                context.push(SeeMoreShelf.nearYouPlaces.routePath);
              },
            )
          : null,
      itemBuilder: (context, index) {
        final item = state.items[index];
        // Cold-cache fallback: if the feed didn't carry an image for this
        // venue, use whatever the detail sheet learned for it.
        final cachedImage = ref.watch(
          entityImageCacheProvider,
        )[EntityKind.venue]?[item.id];
        return ImpressionDetector(
          scopeId: notifier.impressionScopeId,
          itemId: item.id,
          onImpression: () =>
              notifier.recordImpression(item.id, cardIndex: index),
          child: NearYouCard(
            imageUrl: item.imageUrl ?? cachedImage,
            seed: item.id,
            kind: SokoEntityKind.venue,
            name: item.title,
            area: nearYouDistanceLabel(shelfContext, item.distanceKm),
            category: item.primaryTag,
            onTap: () {
              analytics.trackDiscoveryShelfCardClicked(
                shelfId: 'near_you_places',
                cardIndex: index,
                itemId: item.id,
                itemType: 'venue',
              );
              context.push('/venues/${item.id}');
            },
          ),
        );
      },
    );
    if (!showLocationCta && !showCoarsePrompt) return shelf;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        shelf,
        if (showLocationCta) const NearYouLocationCta(),
        if (showCoarsePrompt) const NearYouCoarseLocationPrompt(),
      ],
    );
  }
}

/// Resolves the shelf's dynamic title ("Near you" / "Near Estrela" / …).
/// Shared with the shelf's vertical see-more page so both surfaces read
/// the same heading.
String nearYouPlacesTitle({
  required Lt l10n,
  required NearYouContext? shelfContext,
  required ResolvedSearchLocation? searchLocation,
}) {
  final placeName = _explicitPlaceName(searchLocation);
  // `around` means the feed is measured from the picker centroid, never the
  // user's precise position. Its heading must say so even when the IP city
  // happens to match the picker (which makes `displayNearYou` true).
  if (shelfContext?.mode == NearYouMode.around) {
    final aroundName = placeName ?? shelfContext?.cityName;
    return aroundName == null || aroundName.isEmpty
        ? l10n.discoveryShelfNearbyTitle
        : l10n.discoveryShelfAroundPlaceTitle(aroundName);
  }
  final displayNearYou = shelfContext?.displayNearYou ?? true;
  if (placeName != null) {
    return displayNearYou
        ? l10n.discoveryShelfNearPlaceTitle(placeName)
        : l10n.discoveryShelfAroundPlaceTitle(placeName);
  }
  return displayNearYou
      ? l10n.discoveryShelfNearYouTitle
      : l10n.discoveryShelfNearbyTitle;
}

/// Formats a distance only when the feed was anchored to the user's precise
/// location. City-centroid results stay useful, but a metre/km label would
/// falsely imply that it describes the user's distance from the item.
String? nearYouDistanceLabel(NearYouContext? shelfContext, double km) {
  if (shelfContext?.mode == NearYouMode.around) return null;
  if (km < 1) return '${(km * 1000).round()} m';
  return '${km.toStringAsFixed(1)} km';
}

String? _explicitPlaceName(ResolvedSearchLocation? searchLocation) {
  if (searchLocation == null || !searchLocation.isExplicit) return null;

  final label = searchLocation.label?.trim();
  if (label != null && label.isNotEmpty) {
    final mostSpecific = label.split(',').first.trim();
    if (mostSpecific.isNotEmpty) return mostSpecific;
  }

  final cityName = searchLocation.cityName?.trim();
  return cityName == null || cityName.isEmpty ? null : cityName;
}
