/// Events-only Near-You feed models (PROD-1963). Decodes
/// `NearYouEventsFeedOut` from `GET /api/v1/app/feed/near-you/events`.
/// Powers the "Happening" / "A acontecer" shelf on the Discovery Page.
library;

import '../../core/utils/datetime_parsing.dart';

/// One event card in the Happening shelf. Mirrors `FeedItemEvent` in
/// the OpenAPI spec.
class NearYouEventItem {
  /// Event UUID.
  final String id;

  /// Display title.
  final String title;

  /// Cover/thumbnail URL. May be null for sparse data; callers fall back
  /// to a placeholder asset.
  final String? imageUrl;

  /// Distance from the requested coordinate, in kilometres.
  final double distanceKm;

  /// Event start (ISO-8601 UTC).
  final DateTime startsAt;

  /// Event end (ISO-8601 UTC). Null for events with no published end time.
  final DateTime? endsAt;

  /// The **localized** event-category display label ("Música" in pt-PT,
  /// "Music" in en) — NOT a slug. Backend-resolved per request; localized
  /// since PROD-2142, and owned by the backend under ADR-048.
  ///
  /// **Render it exactly as received** — no humanize, no title-case, no
  /// slug→label mapping (PROD-3978).
  final String? primaryCategory;

  /// Whether the BE has a confirmed time for the event (vs date-only sources
  /// that defaulted to 00:00 at ingest). Defaults to `true` for transitional
  /// safety — payloads predating the BE flag render with the time visible,
  /// matching the legacy behaviour.
  final bool timeKnown;

  const NearYouEventItem({
    required this.id,
    required this.title,
    required this.distanceKm,
    required this.startsAt,
    this.imageUrl,
    this.endsAt,
    this.primaryCategory,
    this.timeKnown = true,
  });

  factory NearYouEventItem.fromJson(Map<String, dynamic> json) {
    return NearYouEventItem(
      id: json['id'] as String,
      title: json['title'] as String,
      imageUrl: json['image_url'] as String?,
      distanceKm: (json['distance_km'] as num).toDouble(),
      startsAt: parseBackendDateTimeRequired(json['starts_at'] as String),
      endsAt: parseBackendDateTime(json['ends_at'] as String?),
      primaryCategory: json['primary_category'] as String?,
      timeKnown: json['time_known'] as bool? ?? true,
    );
  }
}

/// Counts of events seen-suppression hard-dropped from a feed load. Mirrors
/// `EventsDropStats`. Absent / zeroed when the caller asked for the raw feed
/// (`personalize=false`). The Happening shelf's "show hidden" button reads
/// [today].
class EventsDropStats {
  /// All events suppression dropped this load, any date.
  final int total;

  /// Dropped events whose next occurrence is today — the salient count.
  final int today;

  const EventsDropStats({this.total = 0, this.today = 0});

  factory EventsDropStats.fromJson(Map<String, dynamic> json) {
    return EventsDropStats(
      total: json['total'] as int? ?? 0,
      today: json['today'] as int? ?? 0,
    );
  }
}

/// Response wrapper for `/feed/near-you/events`. `total` is the count of
/// candidates within the hard radius cap across all pages; the shelf
/// computes `hasMore` as `loaded.length < total`.
class NearYouEventsFeedResponse {
  final List<NearYouEventItem> items;
  final int total;

  /// Seen-suppression drop counts for this load. Null when the BE omitted
  /// the block (older BE, or `personalize=false`).
  final EventsDropStats? dropped;

  const NearYouEventsFeedResponse({
    required this.items,
    required this.total,
    this.dropped,
  });

  factory NearYouEventsFeedResponse.fromJson(Map<String, dynamic> json) {
    return NearYouEventsFeedResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => NearYouEventItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      dropped: json['dropped'] == null
          ? null
          : EventsDropStats.fromJson(json['dropped'] as Map<String, dynamic>),
    );
  }
}
