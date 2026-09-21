// PROD-4006 — saving an event from the feed.
//
// Both surfaces that can save use this: the `event_hero` card's bookmark and
// the `bundle` row's (D22 — the row's CTA acts on that row's own item). One
// helper rather than two so the two cannot drift into different save
// semantics for the same event on the same page.
//
// **Saved state is read from the bulk cache, never from a per-item request.**
// `listsProvider.savedEventIds` is warmed once by
// `GET /users/me/saved/entity-ids` with a 15-minute SWR window, so a page of a
// hero plus two 6-row bundles costs zero extra calls. That is deliberate and it
// is why FE asked the backend NOT to add a `saved` field to the feed contract:
// the state already exists client-side and putting it on the wire would create
// a second, staler copy.
//
// `SignalController` also carries a save bit (`EntitySignal.wantToGo`), and the
// hero mounts a controller anyway for its thumbs — but reading the save from
// there would give the hero a different source of truth from the bundle rows,
// and the two disagree the moment one of them refreshes. One source.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/models/chat_message.dart';
import '../../../../data/models/discovery_engagement.dart';
import '../../../../data/models/feed_home.dart';
import '../../../../data/models/user_list.dart';
import '../../../../providers/api_provider.dart';
import '../../../../providers/lists_provider.dart';
import '../../../../shared/widgets/impression_detector.dart';
import '../../../lists/widgets/add_to_list_sheet.dart';

/// The ids of events the caller has saved, from the bulk cache.
///
/// A derived read rather than watching `listsProvider` wholesale, for two
/// reasons. It narrows the rebuild: a feed page holds up to fourteen bookmarks
/// and every one of them would otherwise rebuild on any lists mutation —
/// renaming a zine, loading preview covers — rather than only when a save
/// actually changes. And it gives widget tests one small thing to override
/// instead of a `ListsNotifier` with an API, a storage service and an analytics
/// client behind it.
final feedSavedEventIdsProvider = Provider<Set<String>>(
  (ref) => ref.watch(listsProvider.select((s) => s.savedEventIds)),
);

/// The ids of venues the caller has saved, from the same bulk cache
/// (PROD-4108). Separate provider rather than a union set: the two id spaces
/// are distinct and a merged set would make an event and a venue with the same
/// id indistinguishable — vanishingly unlikely with UUIDs, but the narrower
/// rebuild is the real reason.
final feedSavedVenueIdsProvider = Provider<Set<String>>(
  (ref) => ref.watch(listsProvider.select((s) => s.savedVenueIds)),
);

/// Whether [item] is in one of the caller's lists.
///
/// Reads the cache for the item's **own** entity type. Exhaustive over the
/// sealed [FeedItem] with no `default`, so a third type is a compile error
/// rather than a bookmark that silently never fills.
bool isFeedItemSaved(WidgetRef ref, FeedItem item) => switch (item) {
  FeedEventItem() => ref.watch(feedSavedEventIdsProvider).contains(item.id),
  FeedVenueItem() => ref.watch(feedSavedVenueIdsProvider).contains(item.id),
  // ⚠️ **A zine is never "saved", and `false` here is a real answer rather than
  // a default** (PROD-4118). Events and venues are saved *into* a zine; a zine
  // has nothing to be saved into, and its affordance is follow — a different
  // rail, in `feed_zine_follow.dart`. Callers must not reach this expecting a
  // bookmark state: `FeedBundleRow` switches on the item type *before* asking,
  // so the zine row never calls this at all.
  FeedZineItem() => false,
};

/// Opens the save affordance for [item].
///
/// This is the app's established card-bookmark behaviour, not a feed-specific
/// one: quicksave on tap when unsaved and skip the drawer (PROD-3873 /
/// PROD-3983), so the bookmark fills immediately and filing into a zine stays
/// one tap away rather than being forced. Tapping an already-saved bookmark
/// opens the full drawer to manage it.
///
/// Auth gating lives inside `showAddToListSheet` when `ref` is passed, so there
/// is deliberately **no guest check here** — the feed path applies no policy of
/// its own (D10), and a second guest branch is how the two diverge.
Future<void> openFeedItemSave(
  BuildContext context,
  WidgetRef ref,
  FeedItem item,
) async {
  // PROD-4303 — a confirmed save/unsave from the FEED surface feeds the
  // discovery-engagement rail. Detected as a before/after diff of the bulk
  // saved-state cache around the whole affordance, because both save paths
  // only settle that cache on the server's answer by the time the returned
  // future resolves: `quickSave` flips optimistically but reverts before it
  // returns on any failure, and the manage drawer awaits its DELETEs before
  // popping. The one optimistic write in the drawer — filing an already-saved
  // item into another zine — does not change overall saved-ness, so it cannot
  // produce a false emission here. Captured before the await: the tracker is
  // keepAlive, and `ref` may be dead by the time the sheet closes.
  final tracker = ref.read(discoverySessionTrackerProvider);
  // A before/after diff is only honest against a WARM cache. If the bulk
  // saved-ids fetch had not landed when the sheet opened, `wasSaved` is a
  // default `false` for an item the server may already hold — and the diff
  // would then emit a confirmed 'save' for a no-op (or an 'unsave' the user
  // never made). Skip emission entirely in that window: a false confirmed
  // save is worse than a missed one. Residual risk, accepted: a background
  // lists refresh landing MID-sheet can still move the cache under the diff.
  final cacheWasLoaded = ref.read(
    listsProvider.select((s) => s.isSavedCacheLoaded),
  );
  final wasSaved = _isSavedInCache(ref, item);

  await showAddToListSheet(
    context,
    _toItemSuggestion(item),
    ref: ref,
    source: ListSource.discoveryFeed,
    quickSaveIfUnsaved: true,
    skipDrawerWhenSaving: true,
  );

  // `context.mounted` guards the post-await `ref` read — the card's element
  // outliving the sheet is the normal case; if it was disposed the visit has
  // moved on and dropping the event beats reading a dead ref.
  if (!context.mounted) return;
  if (!cacheWasLoaded) return;
  final isSaved = _isSavedInCache(ref, item);
  if (isSaved == wasSaved) return;
  // Resolve the card's pending exposure first, so the exposure precedes the
  // action in `seq` order (contract v2 — an action must never be credited
  // before the exposure that earned it).
  ImpressionDetector.resolveForItem(item.id, endReason: 'action');
  tracker.action(
    actionKind: isSaved
        ? DiscoveryEngagementAction.save
        : DiscoveryEngagementAction.unsave,
    itemId: item.id,
    itemType: switch (item) {
      FeedEventItem() => 'event',
      FeedVenueItem() => 'venue',
      FeedZineItem() => 'zine',
    },
  );
}

/// [isFeedItemSaved] without the `watch` — a one-shot read for the diff above,
/// safe outside `build`.
bool _isSavedInCache(WidgetRef ref, FeedItem item) {
  final lists = ref.read(listsProvider);
  return switch (item) {
    FeedEventItem() => lists.savedEventIds.contains(item.id),
    FeedVenueItem() => lists.savedVenueIds.contains(item.id),
    FeedZineItem() => false,
  };
}

/// Adapts a feed item to the shape the save path already speaks.
ItemSuggestion _toItemSuggestion(FeedItem item) => switch (item) {
  final FeedEventItem event => _eventSuggestion(event),
  final FeedVenueItem venue => _venueSuggestion(venue),
  // Unreachable by construction — `openFeedItemSave` is only wired to the two
  // saveable types, and `FeedBundleRow` picks the follow rail for zines before
  // it gets here. Throwing rather than inventing a suggestion: the save sheet
  // has no `type` for a zine, so a fabricated one would file it under a type
  // nothing recognises and fail silently in the user's list.
  FeedZineItem() => throw UnsupportedError(
    'A zine is followed, not saved — use toggleFeedZineFollow.',
  ),
};

/// ⚠️ **`'place'`, not `'venue'`.** The feed calls this entity a venue and the
/// save path has always called it a place — see
/// `features/venue_detail/utils/venue_item_suggestion.dart`, which is the
/// established shape this mirrors. So unlike the event adapter below, this is a
/// real translation between two vocabularies rather than a rename, and getting
/// it wrong would file the venue under a type nothing else recognises.
///
/// `venueId` carries the id as well as `id`: the sheet keys the optimistic list
/// item off it, exactly as the venue detail page does.
ItemSuggestion _venueSuggestion(FeedVenueItem venue) => ItemSuggestion(
  id: venue.id,
  name: venue.name,
  type: 'place',
  venueId: venue.id,
  imageUrl: venue.imageUrl,
  city: venue.city,
  // The localized primary type is the closest thing the feed's venue item has
  // to the detail page's `tags`; `types` is the un-localized taxonomy and is
  // deliberately not sent as display text.
  category: venue.type,
);

/// `FeedEventItem` is a superset of the existing event vocabulary by design —
/// the contract reuses field names rather than inventing a parallel DTO — so
/// this is a rename, not a translation. Anything the sheet does not need is
/// left off rather than guessed at.
ItemSuggestion _eventSuggestion(FeedEventItem item) => ItemSuggestion(
  id: item.id,
  name: item.title,
  imageUrl: item.imageUrl,
  type: 'event',
  eventId: item.id,
  venueId: item.venueId,
  url: item.url,
  date: item.startsAt.toIso8601String(),
  // The same flag `event_time.dart` encodes: when the crawler only knew a date,
  // the time component is a midnight sentinel and must not be presented as a
  // real start time downstream.
  datePrecision: item.timeKnown ? 'datetime' : 'date',
  description: item.descriptionShort,
  location: item.venueName,
  city: item.city,
  category: item.category,
  categories: item.categories,
);
