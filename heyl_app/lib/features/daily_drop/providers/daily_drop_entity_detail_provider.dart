import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/entity_ref.dart';
import '../../../data/models/event.dart';
import '../../../data/models/event_occurrence.dart';
import '../../../data/models/social_proof.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/entity_image_cache_provider.dart';
import '../../event_detail/providers/event_detail_provider.dart';
import '../../venue_detail/providers/venue_detail_provider.dart';

/// Venue/event detail fetches for the **Daily Drop detail page**, which differ
/// from [venueDetailProvider] / [eventDetailProvider] in exactly one way that
/// matters: they send **no `?source=`**.
///
/// ## Why the page can't reuse the ordinary detail providers
///
/// Both of those hardcode `source: key.listId != null ? 'list' : 'discovery'`
/// (`venue_detail_provider.dart:92`, `event_detail_provider.dart:136`), and
/// `discovery` is one of the origins the backend counts as a **memory interest
/// signal** — `_DISCOVERY_VIEW_SOURCES` in `heyl/apps/webapp/api_detail.py`.
/// The drop page fetches only to reuse the existing save / tag / description /
/// share widgets; the user never asked to see this entity. Writing an interest
/// signal for it would assert taste the user hasn't expressed, and would
/// contradict the page's whole analytics stance (it also fires no `view_item`).
/// Interest is recorded when the user *asks* for the entity — the CTA at the
/// bottom pushes venue/event detail, which fetches with `source: 'discovery'`
/// and fires `view_item` on mount, exactly once.
///
/// Omitting the parameter is the documented no-capture contract on both sides:
/// the backend treats "absent/unknown → no capture (safe)", and `DetailApi`
/// drops the key from the query string entirely when `source` is null
/// (`detail_api.dart`). So this needs no backend change.
///
/// ## Why separate providers rather than a nullable `source` on the keys
///
/// The `source` has to be part of the **cache identity**, or a drop-page fetch
/// and a discovery-page fetch for the same entity would share one entry and
/// whichever fired first would silently decide whether the signal was written.
/// Separate providers give that separation structurally, and they also drop the
/// parent-list machinery (`unifiedListProvider`, tips, `listElementId`) that the
/// drop page has no URL form for.
///
/// They still return the same [VenueDetailSnapshot] / [EventDetailSnapshot]
/// shapes, so `SokoSaveButton`, `EventSaveButton`, `VenueTagRow` and
/// `EventTagRow` mount unchanged — the list-scoped fields are simply null,
/// which is precisely the "standalone form" those widgets already handle.

/// Venue detail for a drop's `venue_id`, fetched with `source` omitted.
final dailyDropVenueDetailProvider = FutureProvider.autoDispose
    .family<VenueDetailSnapshot, String>((ref, venueId) async {
      final venue = await ref
          .read(detailApiProvider)
          .getVenueDetail(venueId); // no `source` — see the file doc.

      // Same hero-image propagation the ordinary providers do: a pure in-memory
      // cache write, no network and no signal. Worth keeping here because the
      // CTA's destination is this very venue's detail page, which then paints
      // its hero without a second download.
      final imageUrl = venue.imageUrl;
      if (imageUrl != null && imageUrl.isNotEmpty) {
        ref.cacheEntityImage(EntityKind.venue, venue.id, imageUrl);
      }
      return VenueDetailSnapshot(venue: venue);
    });

/// Event detail for a drop's `event_id`, fetched with `source` omitted.
///
/// Keeps the legacy `getEvent` companion call that [eventDetailProvider] makes,
/// because it is the only source of **occurrences** — and occurrences are what
/// let `EventSaveButton` save the right date rather than guessing one from the
/// drop payload. Verified that this second call carries no capture of its own:
/// its handler (`heyl/apps/local_db/api/events.py`, `get_event`) is a plain
/// query + occurrence filter + serialize, with no interest write anywhere in the
/// function. Only `api_detail.py` holds that gate. Best-effort, as upstream: a
/// failure yields an empty occurrence list rather than failing the page.
final dailyDropEventDetailProvider = FutureProvider.autoDispose
    .family<EventDetailSnapshot, String>((ref, eventId) async {
      final detailApi = ref.read(detailApiProvider);
      final eventsApi = ref.read(eventsApiProvider);
      final todayStr = DateTime.now().toIso8601String().substring(0, 10);

      final results = await Future.wait([
        detailApi.getEventDetail(eventId), // no `source` — see the file doc.
        eventsApi
            .getEvent(eventId, startDate: todayStr)
            .then<EventDetailResponse?>((r) => r)
            .catchError((_) => null as EventDetailResponse?),
      ]);

      final detail = results[0] as EventDetailResponse2;
      final legacy = results[1] as EventDetailResponse?;
      final occurrences = (legacy?.occurrences ?? const <EventOccurrence>[])
          .futureOnly();

      final imageUrl = detail.imageUrl ?? legacy?.imageUrl;
      if (imageUrl != null && imageUrl.isNotEmpty) {
        ref.cacheEntityImage(EntityKind.event, detail.id, imageUrl);
      }
      return EventDetailSnapshot(event: detail, occurrences: occurrences);
    });
