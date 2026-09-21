import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/social_proof.dart';
import '../../../providers/api_provider.dart';

/// Fetches the full list of events at a venue via the paginated
/// `GET /api/v1/app/places/{venue_id}/events` endpoint (PROD-1680). Walks
/// every page until `has_more: false` and returns a flattened list.
///
/// Used by the zine item-page calendar (§ 7) for venue-with-events cards
/// that need to show ALL events at the venue, not just `upcoming_events`'s
/// hard-capped 10.
final venueEventsProvider =
    FutureProvider.family<List<UpcomingEvent>, String>((ref, venueId) async {
  final api = ref.watch(detailApiProvider);

  final all = <UpcomingEvent>[];
  String? cursor;
  // Belt-and-braces upper bound on pagination loops.
  for (var i = 0; i < 50; i++) {
    final page = await api.listVenueEvents(venueId, limit: 50, cursor: cursor);
    all.addAll(page.items);
    if (!page.hasMore || page.nextCursor == null) break;
    cursor = page.nextCursor;
  }
  return all;
});
