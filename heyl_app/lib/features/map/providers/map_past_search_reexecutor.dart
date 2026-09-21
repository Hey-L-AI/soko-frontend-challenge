import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import 'map_search_executor.dart';
import 'map_search_history_provider.dart';

/// What a history-row tap amounted to. The panel maps this to UX:
/// [stale] → "no longer available" toast + remove the row (Decision #21);
/// [transientError] → keep the row (a network blip is not staleness).
enum MapPastSearchTapOutcome { executed, stale, transientError }

/// Re-executes a past-search entry with a FRESH resolve (D6 — never cached
/// results): fetch the target per type, bump recency, dispatch the resolved
/// object into [MapSearchExecutor]. Ended-but-existing events resolve fine
/// and stay re-executable (Decision #37).
class MapPastSearchReExecutor {
  MapPastSearchReExecutor(this._ref);

  final Ref _ref;

  /// [locale] — the UI language code (`Localizations.localeOf(context)
  /// .languageCode`), used by the location resolve.
  Future<MapPastSearchTapOutcome> execute(
    MapSearchHistoryEntry entry, {
    required String locale,
  }) async {
    final executor = _ref.read(mapSearchExecutorProvider);
    try {
      switch (entry.type) {
        case MapSearchHistoryType.keyword:
          // Nothing to resolve — a keyword can't go stale.
          final query = entry.queryText ?? entry.displayLabel;
          _bumpRecency(entry);
          await executor.executeKeyword(query);
        case MapSearchHistoryType.venue:
          // `source` omitted on resolves: execution only flies/promotes the
          // pin (Decision #18), so this is a non-navigation fetch that must
          // not count as a memory interest signal (see DetailApi docs).
          final venue = await _ref
              .read(detailApiProvider)
              .getVenueDetail(entry.targetId!);
          _bumpRecency(entry);
          await executor.executeVenue(
            venueId: venue.id,
            label: venue.name,
            latitude: venue.latitude,
            longitude: venue.longitude,
            imageUrl: venue.imageUrl,
          );
        case MapSearchHistoryType.event:
          final event = await _ref
              .read(detailApiProvider)
              .getEventDetail(entry.targetId!);
          _bumpRecency(entry);
          // No occurrence id: history stores the canonical event id
          // (PROD-3495 contract) and the detail response carries none.
          await executor.executeEvent(
            eventId: event.id,
            label: event.title,
            latitude: event.latitude,
            longitude: event.longitude,
            imageUrl: event.imageUrl,
          );
        case MapSearchHistoryType.location:
          // Fresh session token per resolve — history taps are single
          // resolves, not autocomplete sessions.
          final area = await _ref
              .read(geoApiProvider)
              .resolveArea(
                id: entry.targetId!,
                sessionToken: const Uuid().v4(),
                locale: locale,
              );
          if (area == null) return MapPastSearchTapOutcome.stale;
          _bumpRecency(entry);
          await executor.executeLocation(area);
        case MapSearchHistoryType.list:
          // The round-trip stays even though PROD-3566 made it optional for
          // the *dropdown* (`/map/pins` accepts a slug, so nothing needs
          // resolving to move the map). Here it is the **staleness probe**:
          // a 404/403/410 below is precisely how a deleted, unshared or
          // moderated list is detected (Decision #21). Removing it would
          // delete staleness detection while every test still passed.
          final list = await _ref
              .read(listsApiProvider)
              .getList(entry.targetId!);
          _bumpRecency(entry);
          // Resolved name over the stored `displayLabel` — a renamed list
          // should show its current name in "De quem?", not the old one.
          await executor.executeList(
            listId: list.id,
            name: list.name,
            source: MapListOpenSource.history,
            // PROD-3568 — EXACT here, unlike the dropdown: the resolve above
            // already cost us the round-trip, so the real owner id is in hand
            // and no handle guessing is needed.
            ownerId: list.ownerId,
          );
      }
      return MapPastSearchTapOutcome.executed;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      // Gone, never-existed, or no-longer-yours all read as "no longer
      // available" (Decision #21). Anything else is transient.
      if (status == 404 || status == 403 || status == 410) {
        return MapPastSearchTapOutcome.stale;
      }
      return MapPastSearchTapOutcome.transientError;
    } catch (_) {
      return MapPastSearchTapOutcome.transientError;
    }
  }

  /// Fire-and-forget: the server upserts + bumps `last_used_at`; the local
  /// list mirrors it. Must never delay or fail the execution itself.
  void _bumpRecency(MapSearchHistoryEntry entry) {
    unawaited(
      _ref
          .read(mapSearchHistoryProvider.notifier)
          .recordSelection(
            type: entry.type,
            targetId: entry.targetId,
            queryText: entry.queryText,
            displayLabel: entry.displayLabel,
            imageUrl: entry.imageUrl,
          ),
    );
  }
}

final mapPastSearchReExecutorProvider = Provider<MapPastSearchReExecutor>(
  MapPastSearchReExecutor.new,
);
