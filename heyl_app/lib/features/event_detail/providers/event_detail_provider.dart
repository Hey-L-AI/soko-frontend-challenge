import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/entity_ref.dart';
import '../../../data/models/event.dart';
import '../../../data/models/event_occurrence.dart';
import '../../../data/models/social_proof.dart';
import '../../../data/models/user_list.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/entity_image_cache_provider.dart';
import '../../../providers/locale_provider.dart';
import '../../lists/providers/unified_list_provider.dart';

/// Composite key for [eventDetailProvider]: an event id (slug or UUID) plus
/// the optional parent-list id when the screen is mounted on the in-list
/// URL form (`/lists/:listId/events/:eventId`).
@immutable
class EventDetailKey {
  final String eventId;
  final String? listId;

  const EventDetailKey({required this.eventId, this.listId});

  @override
  bool operator ==(Object other) =>
      other is EventDetailKey &&
      other.eventId == eventId &&
      other.listId == listId;

  @override
  int get hashCode => Object.hash(eventId, listId);
}

/// PROD-2981 — resolves a map pin's **event-occurrence id** into the real
/// **event id** the detail contract wants (`GET /events/{id}`).
///
/// A `/map/pins` event pin is keyed by occurrence, so a pin tap can't name the
/// event it should open until this round-trip lands. Owning that as a provider
/// is what lets the sheet go up IMMEDIATELY and resolve behind its own loading
/// state — the pin tap used to `await` the hydrate first, leaving the user on a
/// dimmed map with no sheet for the length of a network call, which is exactly
/// what made people tap again.
///
/// Prefer the grid's already-hydrated `eventId` where there is one (see
/// `MapGridState.eventIdForMarker`) — this is the fallback for a pin the
/// results grid hasn't reached yet.
///
/// Resolves to null when the occurrence can't be paired back to an event (a
/// stale pin the hydrate dropped); the sheet then shows its error state.
final eventIdForOccurrenceProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, occurrenceId) async {
      final res = await ref
          .read(mapApiProvider)
          .getMapHydrate(eventOccurrenceIds: [occurrenceId]);
      final event = res.events.isNotEmpty ? res.events.first : null;
      final id = event?.eventId ?? event?.id;
      return (id != null && id.isNotEmpty) ? id : null;
    });

/// Snapshot returned by [eventDetailProvider]. Bundles the modern detail
/// payload (image / description / venue / social proof) with the legacy
/// events-API occurrence list and the optional parent-list view, so the
/// screen and its child widgets can read everything from one watch.
@immutable
class EventDetailSnapshot {
  final EventDetailResponse2 event;

  /// Future-only, sorted occurrences from the legacy events API. Empty when
  /// the legacy call failed or the event has no scheduled occurrences.
  final List<EventOccurrence> occurrences;

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
  /// ([EventInlineActions]) reads the tip / element-id / ownership live from
  /// `unifiedListProvider(effectiveListId)`, so those aren't frozen here.
  final String? effectiveListId;

  /// True while the screen paints the tapped-item **seed** shell before the
  /// network detail resolves (see `EventDetailScreen._buildLoading`). The
  /// occurrence list isn't known yet, so occurrence-dependent affordances (the
  /// reminder bell) render **disabled** rather than being omitted and then
  /// popping in when the real detail lands.
  final bool isHydrating;

  const EventDetailSnapshot({
    required this.event,
    this.occurrences = const [],
    this.parentList,
    this.effectiveListId,
    this.isHydrating = false,
  });
}

/// The network half of [eventDetailProvider], deliberately independent of the
/// parent list. Hits `getEventDetail` (modern — image / desc / venue / social
/// proof) and `getEvent` (legacy — occurrences) **in parallel** and merges the
/// two, and writes the resolved hero image to `entityImageCacheProvider` so
/// other surfaces (Discovery shelves, history grid) reuse the photo.
///
/// The two HTTP calls (modern detail + legacy occurrences) live here so that
/// parent-list state ticks — item-load, saves, follow, pagination — recompute
/// only the *merge* in [eventDetailProvider] and never re-issue these requests.
/// Folding the list `ref.watch` into the same body as the fetch was the
/// double/triple-fetch bug: `unifiedListProvider` emits a sequence of states
/// (loading → loaded → loading-items → …) and each tick re-ran the whole body.
///
/// Watches [apiLocaleCodeProvider] so a locale switch still refetches localized
/// content — exactly once, since only the code the backend actually receives
/// drives this (see [LocaleRefreshListener]).
final _eventDetailFetchProvider = FutureProvider.autoDispose
    .family<
      ({EventDetailResponse2 detail, List<EventOccurrence> occurrences}),
      EventDetailKey
    >((ref, key) async {
      ref.watch(apiLocaleCodeProvider);
      final detailApi = ref.read(detailApiProvider);
      final eventsApi = ref.read(eventsApiProvider);
      final todayStr = DateTime.now().toIso8601String().substring(0, 10);

      // Modern detail call is the canonical source for image / description /
      // venue / social proof. The legacy events-API call is the only source
      // for occurrence data. If the modern one fails we have nothing useful
      // to show, so let it throw; the legacy one is best-effort and we
      // tolerate failure.
      final results = await Future.wait([
        // Origin tag: count as an interest signal only for organic discovery
        // opens; opening from inside a zine (`listId != null`) doesn't count.
        detailApi.getEventDetail(
          key.eventId,
          source: key.listId != null ? 'list' : 'discovery',
        ),
        eventsApi
            .getEvent(key.eventId, startDate: todayStr)
            .then<EventDetailResponse?>((r) => r)
            .catchError((_) => null as EventDetailResponse?),
      ]);

      final detail = results[0] as EventDetailResponse2;
      final legacy = results[1] as EventDetailResponse?;

      // Future-only, sorted occurrences (client-side safety net on top of
      // backend `start_date` filtering, mirrors the legacy sheet).
      final occurrences = (legacy?.occurrences ?? const <EventOccurrence>[])
          .futureOnly();

      // Propagate the resolved hero image to the in-memory entity cache so
      // other surfaces pick up the photo without a second download.
      final imageUrl = detail.imageUrl ?? legacy?.imageUrl;
      if (imageUrl != null && imageUrl.isNotEmpty) {
        ref.cacheEntityImage(EntityKind.event, detail.id, imageUrl);
      }

      return (detail: detail, occurrences: occurrences);
    });

final eventDetailProvider = FutureProvider.autoDispose
    .family<EventDetailSnapshot, EventDetailKey>((ref, key) async {
      final fetch = await ref.watch(_eventDetailFetchProvider(key).future);
      final detail = fetch.detail;
      final occurrences = fetch.occurrences;

      if (key.listId == null) {
        return EventDetailSnapshot(event: detail, occurrences: occurrences);
      }

      // In-list URL: merge in parent-list state. The list view screen primes
      // `unifiedListProvider` when the user opens a list, so warm-start
      // navigation hits a populated state; a cold deep-load triggers the
      // notifier's own fetch and this rebuilds as it settles.
      //
      // `select` narrows the dependency to the three fields the merge reads, so
      // item-load / mutation / follow ticks don't recompute this — and because
      // the fetch above is cached, a recompute never re-issues the HTTP calls.
      final (isNotFound, isLoading, list) = ref.watch(
        unifiedListProvider(
          key.listId!,
        ).select((s) => (s.isNotFound, s.isLoading, s.list)),
      );

      // Parent list isn't accessible (private list shared to non-member, 404
      // on a deleted list). Degrade to standalone form per design doc § 7.7.
      if (isNotFound) {
        return EventDetailSnapshot(event: detail, occurrences: occurrences);
      }

      // Still loading: surface the event immediately, leave parent-list info
      // null. The screen rebuilds when the list state settles.
      if (isLoading || list == null) {
        return EventDetailSnapshot(
          event: detail,
          occurrences: occurrences,
          effectiveListId: key.listId,
        );
      }

      // Parent list is loaded and accessible. The note surface reads the tip
      // + element-id + ownership live from `unifiedListProvider`, so nothing
      // list-item-specific is frozen into the snapshot here.
      return EventDetailSnapshot(
        event: detail,
        occurrences: occurrences,
        parentList: list,
        effectiveListId: key.listId,
      );
    });
