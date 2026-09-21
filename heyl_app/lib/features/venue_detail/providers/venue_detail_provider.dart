import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/entity_ref.dart';
import '../../../data/models/social_proof.dart';
import '../../../data/models/user_list.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/entity_image_cache_provider.dart';
import '../../../providers/locale_provider.dart';
import '../../lists/providers/unified_list_provider.dart';

/// Composite key for [venueDetailProvider]: a venue id (slug or UUID) plus
/// the optional parent-list id when the screen is mounted on the in-list
/// URL form (`/lists/:listId/venues/:venueId`).
@immutable
class VenueDetailKey {
  final String venueId;
  final String? listId;

  const VenueDetailKey({required this.venueId, this.listId});

  @override
  bool operator ==(Object other) =>
      other is VenueDetailKey &&
      other.venueId == venueId &&
      other.listId == listId;

  @override
  int get hashCode => Object.hash(venueId, listId);
}

/// Snapshot returned by [venueDetailProvider]. Bundles the venue detail
/// payload with the parent-list view (when applicable) so the screen and
/// its child widgets can read everything from one watch.
@immutable
class VenueDetailSnapshot {
  final VenueDetailResponse venue;

  /// Parent list when the URL is the in-list form AND it loaded successfully.
  /// Null when:
  ///   - the URL is the standalone form (`listId == null`),
  ///   - the parent list 404'd / 403'd (auto-degrade to standalone, design
  ///     doc § 7.7), or
  ///   - the parent list is still loading.
  final UserList? parentList;

  /// Effective list id used for share-URL building + note gating. Equal to
  /// the input `listId` when the parent list is accessible; null otherwise
  /// (degrades to standalone form). The note surface itself
  /// ([VenueInlineActions]) reads the tip / element-id / ownership live from
  /// `unifiedListProvider(effectiveListId)`, so those aren't frozen here.
  final String? effectiveListId;

  const VenueDetailSnapshot({
    required this.venue,
    this.parentList,
    this.effectiveListId,
  });
}

/// Async family provider keyed by `(venueId, listId?)`.
///
/// Fetches `getVenueDetail(venueId)` and (when `listId != null`) reads the
/// existing `unifiedListProvider(listId)` to merge in the parent list +
/// user's tip. Auto-degrades to standalone behaviour when the parent list
/// can't be loaded (private list shared to a non-member, etc.).
///
/// Side effect: writes the resolved hero image to `entityImageCacheProvider`
/// so other surfaces showing this venue (Discovery shelves, history grid)
/// pick up the photo without a second download.
/// The network half of [venueDetailProvider], deliberately independent of the
/// parent list.
///
/// `getVenueDetail` lives here so parent-list state ticks — item-load, saves,
/// follow, pagination — recompute only the *merge* in [venueDetailProvider] and
/// never re-issue the request. Folding the list `ref.watch` into the fetch body
/// was the double/triple-fetch bug: `unifiedListProvider` emits a sequence of
/// states and each tick re-ran the whole body.
///
/// Watches [apiLocaleCodeProvider] so a locale switch still refetches localized
/// content — exactly once (see [LocaleRefreshListener]).
final _venueDetailFetchProvider = FutureProvider.autoDispose
    .family<VenueDetailResponse, VenueDetailKey>((ref, key) async {
      ref.watch(apiLocaleCodeProvider);
      final detailApi = ref.read(detailApiProvider);
      // Tag the navigation origin so the backend counts this open as an interest
      // signal ONLY when it's organic discovery. Opening from inside a zine
      // (`listId != null`) is browsing someone's curation — not your taste — so it
      // must not count (only following the zine / saving an item does).
      final venue = await detailApi.getVenueDetail(
        key.venueId,
        source: key.listId != null ? 'list' : 'discovery',
      );

      // Propagate hero image to the in-memory entity cache (mirrors the
      // pattern in `item_detail_sheet._fetchDetailData`).
      final imageUrl = venue.imageUrl;
      if (imageUrl != null && imageUrl.isNotEmpty) {
        ref.cacheEntityImage(EntityKind.venue, venue.id, imageUrl);
      }

      return venue;
    });

final venueDetailProvider = FutureProvider.autoDispose
    .family<VenueDetailSnapshot, VenueDetailKey>((ref, key) async {
      final venue = await ref.watch(_venueDetailFetchProvider(key).future);

      if (key.listId == null) {
        return VenueDetailSnapshot(venue: venue);
      }

      // In-list URL: merge in parent-list state. The list view screen primes
      // `unifiedListProvider` when the user opens a list, so warm-start
      // navigation hits a populated state; a cold deep-load triggers the
      // notifier's own fetch and this rebuilds as it settles.
      //
      // `select` narrows the dependency to the three fields the merge reads, so
      // item-load / mutation / follow ticks don't recompute this — and because
      // the fetch above is cached, a recompute never re-issues the HTTP call.
      final (isNotFound, isLoading, list) = ref.watch(
        unifiedListProvider(
          key.listId!,
        ).select((s) => (s.isNotFound, s.isLoading, s.list)),
      );

      // Parent list isn't accessible (private list shared to non-member, 404
      // on a deleted list). Degrade to standalone form per design doc § 7.7.
      if (isNotFound) {
        return VenueDetailSnapshot(venue: venue);
      }

      // Still loading: surface the venue immediately, leave parent-list info
      // null. The screen rebuilds when the list state settles.
      if (isLoading || list == null) {
        return VenueDetailSnapshot(venue: venue, effectiveListId: key.listId);
      }

      // Parent list is loaded and accessible. The note surface reads the tip
      // + element-id + ownership live from `unifiedListProvider`, so nothing
      // list-item-specific is frozen into the snapshot here.
      return VenueDetailSnapshot(
        venue: venue,
        parentList: list,
        effectiveListId: key.listId,
      );
    });
