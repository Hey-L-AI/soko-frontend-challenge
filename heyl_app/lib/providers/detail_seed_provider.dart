import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';

/// A lightweight, already-known summary of an event/venue — enough to paint
/// the detail-page **shell** (hero image + title + category/location chips)
/// the instant the user taps, while the full detail hydrates over the network
/// (PROD-4XXX).
///
/// This is the "placeholder data / stale-while-revalidate" pattern: every
/// surface that already holds an entity's summary (a zine item, a discovery
/// card, a list row) writes it to [detailSeedCacheProvider] on tap, and the
/// detail screen reads it to render a real body immediately instead of a
/// full-page spinner. The network fetch always still runs and replaces the
/// seed within ~1s, so a slightly-stale seed is self-healing — it only needs
/// to be "good enough to paint".
///
/// Generalises [entityImageCacheProvider] (which carries only the hero URL)
/// to the handful of fields the shell needs.
class DetailSeed {
  final EntityKind kind;
  final String id;
  final String? imageUrl;
  final String? title;

  /// Event category or venue primary-tag — the type chip.
  final String? category;

  /// Event-only: the linked venue's display name (location chip).
  final String? venueName;
  final String? city;

  /// Event-only: ISO-8601 start used for the relative-timing sticker.
  final String? startAtIso;

  /// Event-only: the short one-liner blurb (`description_short`), when the
  /// tapped source card already carries it (Discovery feed, saved lists). Lets
  /// the shell paint the blurb immediately instead of waiting for hydrate. Only
  /// forwarded for events — venue source cards (`FeedVenueItem`) don't carry a
  /// short description, and `EventDetailResponse2.descriptionShort` is itself
  /// often NULL in production, so this is a best-effort head start, not a
  /// guarantee.
  final String? descriptionShort;

  const DetailSeed({
    required this.kind,
    required this.id,
    this.imageUrl,
    this.title,
    this.category,
    this.venueName,
    this.city,
    this.startAtIso,
    this.descriptionShort,
  });

  /// Build a seed from a tapped list/zine item. Returns null when the item
  /// has no resolvable backend entity id (ad-hoc places), since there is
  /// nothing to key the detail route on.
  static DetailSeed? fromUserListItem(UserListItem item) {
    final isEvent = item.itemType == SavedItemType.event;
    final id = isEvent ? item.eventId : item.venueId;
    if (id == null || id.isEmpty) return null;
    return DetailSeed(
      kind: isEvent ? EntityKind.event : EntityKind.venue,
      id: id,
      imageUrl: item.imageUrl,
      title: item.title,
      category: item.category,
      venueName: isEvent ? item.venueName : null,
      city: item.city,
      startAtIso: isEvent ? item.eventDate?.toIso8601String() : null,
      descriptionShort: isEvent ? item.descriptionShort : null,
    );
  }

  /// Build a seed from a tapped Library-feed event row. Lets the standalone
  /// event detail paint hero + title instantly and carries the image so the
  /// page's pastel background can derive from it on the first frame.
  static DetailSeed fromLibraryEvent(LibraryFeedEvent e) => DetailSeed(
    kind: EntityKind.event,
    id: e.id,
    imageUrl: e.imageUrl,
    title: e.title,
    category: e.category,
    venueName: e.venueName,
    startAtIso: e.startAt?.toIso8601String(),
  );

  /// Build a seed from a tapped map result card ([ItemSuggestion]). Lets the
  /// map's detail SHEET paint hero + title + chips instantly (see the sheets'
  /// seed-aware loading branches) instead of a spinner while the full detail
  /// hydrates. Returns null when the item has no resolvable backend id.
  ///
  /// [ItemSuggestion.date] is a display string (not guaranteed ISO-8601), so it
  /// is deliberately NOT fed to [startAtIso] — the relative-timing sticker just
  /// waits for the hydrated event rather than risk a parse throw in the body.
  static DetailSeed? fromItemSuggestion(ItemSuggestion s) {
    final isEvent = s.type == 'event';
    final id = isEvent ? (s.eventId ?? s.id) : (s.venueId ?? s.id);
    if (id.isEmpty) return null;
    return DetailSeed(
      kind: isEvent ? EntityKind.event : EntityKind.venue,
      id: id,
      imageUrl: s.imageUrl,
      title: s.name,
      category: s.category,
      venueName: isEvent ? s.location : null,
      city: s.city,
    );
  }

  /// Build a seed from a tapped Library-feed place row (venue counterpart of
  /// [fromLibraryEvent]).
  static DetailSeed fromLibraryPlace(LibraryFeedPlace p) => DetailSeed(
    kind: EntityKind.venue,
    id: p.id,
    imageUrl: p.imageUrl,
    title: p.name,
    category: p.category,
    city: p.city,
  );

  /// Build a seed from a tapped Discovery feed (feed_v2) event card, so the
  /// standalone event detail paints its shell instantly and the feed→collage
  /// Hero has a frame-1 destination.
  static DetailSeed fromFeedEventItem(FeedEventItem e) => DetailSeed(
    kind: EntityKind.event,
    id: e.id,
    imageUrl: e.imageUrl,
    title: e.title,
    category: e.category,
    venueName: e.venueName,
    city: e.city,
    startAtIso: e.startsAt.toIso8601String(),
    descriptionShort: e.descriptionShort,
  );

  /// Build a seed from a tapped Discovery feed venue card (venue counterpart of
  /// [fromFeedEventItem]).
  static DetailSeed fromFeedVenueItem(FeedVenueItem v) => DetailSeed(
    kind: EntityKind.venue,
    id: v.id,
    imageUrl: v.imageUrl,
    title: v.name,
    category: v.type,
    city: v.city,
  );

  List<String> get _heroImages =>
      (imageUrl != null && imageUrl!.isNotEmpty) ? [imageUrl!] : const [];

  /// Minimal [EventDetailResponse2] carrying only the shell fields. Every
  /// section in `EventDetailBody` is data-gated, so the absent fields simply
  /// don't render — the shell shows hero + title (+ location when known).
  EventDetailResponse2 toEventDetail() => EventDetailResponse2(
    id: id,
    title: title ?? '',
    images: _heroImages,
    imageUrl: imageUrl,
    venueName: venueName,
    venueCity: city,
    category: category,
    startDatetime: startAtIso,
    descriptionShort: descriptionShort,
    socialProof: const SocialProof(),
  );

  /// Minimal [VenueDetailResponse] carrying only the shell fields.
  VenueDetailResponse toVenueDetail() => VenueDetailResponse(
    id: id,
    name: title ?? '',
    images: _heroImages,
    imageUrl: imageUrl,
    city: city,
    primaryTag: category,
    socialProof: const SocialProof(),
  );
}

/// Max entries kept in the in-memory seed cache. Oldest are evicted (insertion
/// order) so the map can't grow without bound as the user browses. Seeds are
/// tiny (a few strings each); this cap is about hygiene, not memory pressure.
const int _kDetailSeedCacheMax = 96;

/// The image-derived pastel a **standalone** event/venue detail page paints as
/// its full-page background (shell Scaffold + [PinnedPageChrome] + body),
/// replacing the old fixed Soko/Green (event) / Soko/Blue (venue). It's
/// published by the detail screen once it resolves the colour (via
/// `standaloneDetailBgColor`) and read by `DiscoveryShell` + `PinnedPageChrome`
/// so all three surfaces agree — mirroring the daily-drop "one shared resolver,
/// two paint sites" pattern. Null → those surfaces fall back to the route
/// constant (e.g. a cold deep-link's first loading frame, before the image is
/// known). A tap-originated open pre-publishes a synchronous fallback so the
/// common path never flashes the old colour. Not user-scoped — it's ephemeral
/// UI state overwritten on every detail open.
final standaloneDetailBgProvider = StateProvider<Color?>((ref) => null);

String _seedKey(EntityKind kind, String id) => '${kind.name}:$id';

/// In-memory `(EntityKind,id) → DetailSeed` cache. Bounded + LRU-ish (oldest
/// insertion evicted past [_kDetailSeedCacheMax]). Registered in
/// `userScopedProviders` so it clears on account switch; clears on restart
/// like [entityImageCacheProvider].
final detailSeedCacheProvider = StateProvider<Map<String, DetailSeed>>(
  (ref) => const {},
);

extension DetailSeedRef on Ref {
  DetailSeed? detailSeed(EntityKind kind, String id) =>
      read(detailSeedCacheProvider)[_seedKey(kind, id)];
}

extension DetailSeedWidgetRef on WidgetRef {
  DetailSeed? detailSeed(EntityKind kind, String id) =>
      read(detailSeedCacheProvider)[_seedKey(kind, id)];

  void cacheDetailSeed(DetailSeed? seed) {
    if (seed == null) return;
    final current = read(detailSeedCacheProvider);
    final key = _seedKey(seed.kind, seed.id);
    // Rebuild with the newest key last (insertion order = recency).
    final next = <String, DetailSeed>{...current}..remove(key);
    next[key] = seed;
    // Evict oldest until within cap.
    while (next.length > _kDetailSeedCacheMax) {
      next.remove(next.keys.first);
    }
    read(detailSeedCacheProvider.notifier).state = next;
  }
}
