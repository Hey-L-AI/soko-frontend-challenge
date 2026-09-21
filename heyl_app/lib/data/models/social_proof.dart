import '../../core/utils/datetime_parsing.dart';
import 'event_date_range.dart';
import 'map_pin.dart' show FacetPair;
import 'recurrence_phase.dart';

/// Social proof data for events and venues
class SocialProof {
  final int saveCount;
  final int listCount;
  final List<ListSummary> lists;

  const SocialProof({
    this.saveCount = 0,
    this.listCount = 0,
    this.lists = const [],
  });

  factory SocialProof.fromJson(Map<String, dynamic> json) {
    return SocialProof(
      saveCount: json['save_count'] as int? ?? 0,
      listCount: json['list_count'] as int? ?? 0,
      lists:
          (json['lists'] as List<dynamic>?)
              ?.map((e) => ListSummary.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  bool get isEmpty => saveCount == 0 && listCount == 0;
}

/// Summary of a list containing an item
class ListSummary {
  final String id;
  final String name;
  final String? slug;
  final String? coverImageUrl;

  // PROD-2300 — granular cover-recipe fields, mirroring `UserList`. The
  // OpenAPI `ListSummaryOut` (= `ListIdentityOut`) already carries these on
  // `social_proof.lists[]` and typeahead list rows; the FE just wasn't
  // deserialising them, which forced four surfaces (event/venue "appears
  // in" shelves, typeahead row, add-to-list fallback) to render the raw
  // `coverImageUrl` and bypass the `ZineCoverRecipe` pipeline. All
  // nullable so payloads that pre-date the BE backfill still parse.
  final String? coverType;
  final String? coverColor;
  final String? coverTexture;
  final String? coverTextColor;
  final String? coverItemId;
  final String? coverItemImageUrl;
  final bool coverShowTitle;
  final bool coverShowTexture;
  final bool coverShowLogo;

  /// URL-friendly identifier (slug if available, otherwise UUID)
  String get urlIdentifier => slug ?? id;

  const ListSummary({
    required this.id,
    required this.name,
    this.slug,
    this.coverImageUrl,
    this.coverType,
    this.coverColor,
    this.coverTexture,
    this.coverTextColor,
    this.coverItemId,
    this.coverItemImageUrl,
    this.coverShowTitle = true,
    this.coverShowTexture = true,
    this.coverShowLogo = true,
  });

  factory ListSummary.fromJson(Map<String, dynamic> json) {
    return ListSummary(
      id: json['id'] as String,
      name: json['name'] as String,
      slug: json['slug'] as String?,
      coverImageUrl: json['cover_image_url'] as String?,
      coverType: json['cover_type'] as String?,
      coverColor: json['cover_color'] as String?,
      coverTexture: json['cover_texture'] as String?,
      coverTextColor: json['cover_text_color'] as String?,
      coverItemId: json['cover_item_id'] as String?,
      coverItemImageUrl: json['cover_item_image_url'] as String?,
      coverShowTitle: json['cover_show_title'] as bool? ?? true,
      coverShowTexture: json['cover_show_texture'] as bool? ?? true,
      coverShowLogo: json['cover_show_logo'] as bool? ?? true,
    );
  }
}

/// Upcoming event at a venue
class UpcomingEvent {
  final String eventId;
  final String name;
  final String? startAt;
  final String? endAt;
  final String? category;
  final String? imageUrl;
  final String? url;

  /// One-liner blurb (~10-20 words). Backend [`UpcomingEventOut`] exposes
  /// `description_short` only — no `description_long` on this DTO. Mostly
  /// NULL in production today: events ingestion has no LLM-summarising step
  /// (analogous to venues' `venue_description_generator.py`), so the field
  /// only populates when a scraper happens to provide a short blurb.
  final String? descriptionShort;

  /// Whether the BE has a confirmed time for the event (vs date-only sources
  /// that defaulted to 00:00 at ingest). Defaults to `true` for transitional
  /// safety — payloads predating the BE flag render with the time visible,
  /// matching the legacy behaviour.
  final bool timeKnown;

  const UpcomingEvent({
    required this.eventId,
    required this.name,
    this.startAt,
    this.endAt,
    this.category,
    this.imageUrl,
    this.url,
    this.descriptionShort,
    this.timeKnown = true,
  });

  factory UpcomingEvent.fromJson(Map<String, dynamic> json) {
    return UpcomingEvent(
      eventId: json['event_id'] as String,
      name: json['name'] as String,
      startAt: json['start_at'] as String?,
      endAt: json['end_at'] as String?,
      category: json['category'] as String?,
      imageUrl: json['image_url'] as String?,
      url: json['url'] as String?,
      descriptionShort: json['description_short'] as String?,
      timeKnown: json['time_known'] as bool? ?? true,
    );
  }

  /// Parses `start_at` into a [DateTime]; null when the field is absent or
  /// malformed.
  DateTime? get startDateTime {
    final s = startAt;
    if (s == null) return null;
    try {
      return DateTime.parse(s).toLocal();
    } catch (_) {
      return null;
    }
  }
}

/// One page of `listVenueEvents` (`GET /places/{venue_id}/events`).
/// Mirrors the `VenueEventsPageOut` schema from PROD-1680.
class VenueEventsPage {
  final List<UpcomingEvent> items;
  final String? nextCursor;
  final bool hasMore;

  const VenueEventsPage({
    required this.items,
    this.nextCursor,
    required this.hasMore,
  });

  factory VenueEventsPage.fromJson(Map<String, dynamic> json) {
    return VenueEventsPage(
      items: (json['items'] as List<dynamic>? ?? [])
          .map((e) => UpcomingEvent.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: json['next_cursor'] as String?,
      hasMore: json['has_more'] as bool? ?? false,
    );
  }
}

/// The user who created/shared a user-generated event or venue (PROD-3134).
///
/// Reads `shared_by` (`SharedByUserOut`) from `EventDetailOut` /
/// `VenueDetailOut`. Present ONLY for user-created items (those with a
/// `creator_user_id`, e.g. events extracted from user photo contributions,
/// PROD-2147, or Instagram inbound shares, PROD-1572) — NULL for system/scraped
/// items. When set, drives the `Shared by <user>` attribution rendered below
/// the description. Venues have no creator concept in the backend yet, so the
/// venue field stays null until the BE adds a venue-level creator. [handle] is
/// the `/u/{handle}` profile key
/// and is expected whenever a creator exists; the UI degrades to a
/// non-tappable name when it's absent.
class SharedByUser {
  final String id;
  final String? fullName;
  final String? handle;
  final String? avatarUrl;

  /// Manually-assigned Expert tag (backend PROD-3336). Drives the Expert badge
  /// next to the sharer's name.
  final bool isExpert;

  const SharedByUser({
    required this.id,
    this.fullName,
    this.handle,
    this.avatarUrl,
    this.isExpert = false,
  });

  factory SharedByUser.fromJson(Map<String, dynamic> json) {
    return SharedByUser(
      id: json['id'] as String,
      fullName: json['full_name'] as String?,
      handle: json['handle'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      isExpert: json['is_expert'] as bool? ?? false,
    );
  }
}

/// One page of an event's full sharer list (PROD-3161 / PROD-3162).
///
/// Reads `EventSharersPageOut` from `GET /app/events/{event_id}/shared-by`,
/// backing the "and N others" popup. Same item shape as
/// [EventDetailResponse2.sharersPreview]; [nextOffset] is null on the last page.
class EventSharersPage {
  final List<SharedByUser> items;
  final int total;
  final int? nextOffset;

  const EventSharersPage({
    required this.items,
    required this.total,
    this.nextOffset,
  });

  bool get hasMore => nextOffset != null;

  factory EventSharersPage.fromJson(Map<String, dynamic> json) {
    return EventSharersPage(
      items: (json['items'] as List<dynamic>? ?? [])
          .map((e) => SharedByUser.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      nextOffset: json['next_offset'] as int?,
    );
  }
}

/// One person on the merged "… têm interesse" row.
///
/// Reads `InterestedUserOut`: a [SharedByUser] plus WHY they are on the list.
/// [liked] and [saved] are independent and at least one is always true — both
/// true means the same person liked AND saved, and the row draws both glyphs.
///
/// The follow flags are viewer-relative and only populated by the paginated
/// `/interested-by` endpoint, whose rows carry a Follow button. The detail
/// payload's preview draws no button and leaves them false.
class InterestedUser {
  final SharedByUser user;

  /// This person gave the entity a 👍.
  final bool liked;

  /// This person has the entity in a list that names them. The backend owns
  /// which saves qualify (public zine always; the default Saved list only while
  /// `show_saved` is on and, for a private account, only for followers).
  final bool saved;

  /// The VIEWER actively follows this person (excludes pending requests).
  final bool isFollowing;

  /// This person follows the VIEWER — the row's button reads "Follow back".
  final bool followsYou;

  /// The VIEWER has a PENDING request to this person. Disjoint from
  /// [isFollowing]; seeds "Requested" on load rather than only after a tap.
  final bool requested;

  const InterestedUser({
    required this.user,
    this.liked = false,
    this.saved = false,
    this.isFollowing = false,
    this.followsYou = false,
    this.requested = false,
  });

  factory InterestedUser.fromJson(Map<String, dynamic> json) {
    return InterestedUser(
      user: SharedByUser.fromJson(json),
      liked: json['liked'] as bool? ?? false,
      saved: json['saved'] as bool? ?? false,
      isFollowing: json['is_following'] as bool? ?? false,
      followsYou: json['follows_you'] as bool? ?? false,
      requested: json['requested'] as bool? ?? false,
    );
  }
}

/// Parses an `interested_preview` array. Absent/!list ⇒ empty, so a backend
/// that predates the merged row simply renders no row.
List<InterestedUser> _parseInterested(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .map((e) => InterestedUser.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// One page of an entity's interested people.
///
/// Reads `InterestedPageOut` from
/// `GET /app/{events|places}/{id}/interested-by`, backing the sheet behind the
/// row. Deduped server-side: someone who both liked and saved is ONE item with
/// both flags, which is precisely why this can't be assembled here from two
/// separate lists. [nextOffset] is null on the last page.
class InterestedPage {
  final List<InterestedUser> items;

  /// Distinct people, after filtering. Viewer-relative — blocks and the
  /// private-account save rule both depend on who is asking.
  final int total;
  final int? nextOffset;

  const InterestedPage({
    required this.items,
    required this.total,
    this.nextOffset,
  });

  bool get hasMore => nextOffset != null;

  factory InterestedPage.fromJson(Map<String, dynamic> json) {
    return InterestedPage(
      items: _parseInterested(json['items']),
      total: json['total'] as int? ?? 0,
      nextOffset: json['next_offset'] as int?,
    );
  }
}

/// Parses a `likers_preview` array. Absent/!list ⇒ empty, so a backend that
/// predates PROD-3779 simply renders no "Liked by" row.
List<SharedByUser> _parseLikers(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .map((e) => SharedByUser.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// PROD-4074 — forward-compatible parse for a detail response's photo set,
/// used by both [EventDetailResponse2.images] and [VenueDetailResponse.images].
///
/// The backend does not carry a multi-image field yet (single `image_url`
/// only; the multi-photo backend work is PROD-1676). Until it does, this
/// collapses to the single hero — `[image_url]` when present, else empty — so
/// the collage renders the single-image treatment, unchanged from today. The
/// day the backend adds an `images` array, the gallery fills with **no app
/// release**. Non-string / blank entries are dropped defensively.
List<String> _parseDetailImages(dynamic raw, String? imageUrl) {
  if (raw is List) {
    final urls = raw
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (urls.isNotEmpty) return urls;
  }
  final single = imageUrl?.trim() ?? '';
  return single.isEmpty ? const [] : <String>[single];
}

/// One page of an entity's likers (PROD-3779).
///
/// Reads `LikersPageOut` from `GET /app/{events|places}/{id}/liked-by`, backing
/// the "Liked by" row's "and N others" popup. Same item shape as
/// [EventDetailResponse2.likersPreview]; [nextOffset] is null on the last page.
///
/// Deliberately its own type rather than reusing [EventSharersPage]: the wire
/// shape matches today, but the two lists answer different questions and will
/// drift.
class LikersPage {
  final List<SharedByUser> items;
  final int total;
  final int? nextOffset;

  const LikersPage({required this.items, required this.total, this.nextOffset});

  bool get hasMore => nextOffset != null;

  factory LikersPage.fromJson(Map<String, dynamic> json) {
    return LikersPage(
      items: (json['items'] as List<dynamic>? ?? [])
          .map((e) => SharedByUser.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      nextOffset: json['next_offset'] as int?,
    );
  }
}

/// Full event detail response with social proof
class EventDetailResponse2 {
  final String id;
  final String title;

  /// Multi-sentence prose for the long-form description block. Reads
  /// `description_long` from `EventDetailOut` (PROD-1686 part 2). NULL when
  /// the LLM enrichment didn't produce a long-tier summary or the event
  /// was never enriched. **Never duplicates [descriptionShort]** —
  /// guaranteed by the backend tier gating.
  final String? descriptionLong;

  /// One-liner blurb (~10-20 words) rendered above the long-form prose
  /// block on the event detail page. Reads `description_short` from
  /// `EventDetailOut`. Mostly NULL in production today (events ingestion
  /// has no LLM-summarising step yet — same caveat as
  /// [UpcomingEvent.descriptionShort]).
  final String? descriptionShort;

  final String? startDatetime;
  final String? endDatetime;
  final String? venueId;
  final String? venueName;
  final double? latitude;
  final double? longitude;
  final String? venueAddress;
  final String? venueCity;
  final String? url;
  final String? category;
  final String? imageUrl;

  /// PROD-4074 — the full photo set for the detail-page hero collage.
  ///
  /// **Forward-compatible parse: `EventDetailOut` does not carry an `images`
  /// array yet** (single `image_url` only; the backend multi-photo work is
  /// PROD-1676). Until it lands this collapses to `[imageUrl]` when present,
  /// else empty — so the collage renders the single-image treatment,
  /// unchanged from today. The day the backend sends `images`, the gallery
  /// fills with no app release. See [_parseDetailImages].
  final List<String> images;

  /// The user who shared/created this event, when it is user-generated
  /// (PROD-3134). NULL for system/scraped events. See [SharedByUser].
  ///
  /// Kept as the single-sharer primary for back-compat; see [sharersPreview] /
  /// [sharersCount] for the full multi-sharer set (PROD-3160).
  final SharedByUser? sharedBy;

  /// Head of the distinct users who shared this event — creator + photo
  /// contributions + Instagram shares, folded across dedup merges (PROD-3161).
  /// Reads `sharers_preview` (up to 3), ordered creator-first then most-recent
  /// share. Empty for system/scraped events. The full list is paginated via
  /// [DetailApi.getEventSharedBy]. Drives the collapsed "A, B and N others" row.
  final List<SharedByUser> sharersPreview;

  /// Total distinct sharers for this event (PROD-3161). Reads `sharers_count`;
  /// `>=` [sharersPreview] length. Drives the "and N others" affordance and the
  /// popup — 0/1 means no popup.
  final int sharersCount;

  /// Upcoming occurrences collapsed into display date ranges (PROD-3116).
  /// Backend-computed; empty when the event has no future occurrences. The
  /// "Dates" section renders these instead of one repeated-title row per
  /// occurrence. See [EventDateRange].
  final List<EventDateRange> dateRanges;

  final SocialProof socialProof;

  /// Head (up to 3) of the people who liked this event — the "Liked by" row
  /// (PROD-3779). Reads `likers_preview`. Viewer-relative: the backend filters
  /// blocks both ways and puts the viewer's follows first. The full list pages
  /// via [DetailApi.getLikedBy].
  final List<SharedByUser> likersPreview;

  /// Total people who liked this event (`likes_count`), after the backend's
  /// filtering. Drives the "and N others" affordance.
  final int likesCount;

  /// Head (up to 3) of the people who liked OR saved this event — the merged
  /// "… têm interesse" row, which REPLACES the "Liked by" row.
  /// Reads `interested_preview`. Viewer-relative twice over (blocks both ways,
  /// and a private account's Saved entry only names them to a follower). The
  /// full list pages via [DetailApi.getInterestedBy].
  final List<InterestedUser> interestedPreview;

  /// Distinct people who liked or saved this event (`interested_count`), after
  /// filtering. Drives the "e mais N" affordance.
  final int interestedCount;

  /// PROD-3412 (BE-7) — confident recurrence phase from `EventDetailOut`,
  /// ungated. **Currently parsed but NOT rendered.** It was intended for a chip
  /// on the detail header, but that surface was dropped (PROD-3379): the phase
  /// is a per-occurrence property and `EventDetailOut.recurrence_phase` anchors
  /// on only the event's next-future occurrence, which is ambiguous on a
  /// by-event view whose "Datas" section lists many occurrences. Kept for the
  /// contract; a real detail treatment would need per-occurrence phase data.
  final RecurrencePhase? recurrencePhase;

  /// PROD-3829 — the entity's primary discovery facet, when the backend sends
  /// one. Selects the detail-block map pin's teardrop art via
  /// `mapPinKey(primaryFacet:)`.
  ///
  /// **Forward-compatible parse: this response does not carry the field yet.**
  /// Absent / null / `{}` all resolve to null, and a null facet renders the
  /// generic pink `pin-default`. The day the backend adds it, the category art
  /// appears with **no app release** (PROD-3832).
  ///
  /// ⚠️ NEVER synthesise this from `tags` / `category` — that expansion is
  /// deliberately server-side (PROD-2369).
  final FacetPair? primaryFacet;

  const EventDetailResponse2({
    required this.id,
    required this.title,
    this.descriptionLong,
    this.descriptionShort,
    this.startDatetime,
    this.endDatetime,
    this.venueId,
    this.venueName,
    this.latitude,
    this.longitude,
    this.venueAddress,
    this.venueCity,
    this.url,
    this.category,
    this.imageUrl,
    this.images = const [],
    this.sharedBy,
    this.sharersPreview = const [],
    this.sharersCount = 0,
    this.dateRanges = const [],
    required this.socialProof,
    this.likersPreview = const [],
    this.likesCount = 0,
    this.interestedPreview = const [],
    this.interestedCount = 0,
    this.recurrencePhase,
    this.primaryFacet,
  });

  /// Field-override copy. Used to backfill a hydrated detail with a value we
  /// already had from the tapped-item seed — chiefly [descriptionShort], which
  /// the feed card carries but `EventDetailOut` often nulls (so the seed blurb
  /// would otherwise flash then vanish on hydrate). Uses the `?? this.x`
  /// pattern: it can override to a non-null value but cannot null a field out —
  /// which is exactly what a backfill wants.
  EventDetailResponse2 copyWith({String? descriptionShort}) =>
      EventDetailResponse2(
        id: id,
        title: title,
        descriptionLong: descriptionLong,
        descriptionShort: descriptionShort ?? this.descriptionShort,
        startDatetime: startDatetime,
        endDatetime: endDatetime,
        venueId: venueId,
        venueName: venueName,
        latitude: latitude,
        longitude: longitude,
        venueAddress: venueAddress,
        venueCity: venueCity,
        url: url,
        category: category,
        imageUrl: imageUrl,
        images: images,
        sharedBy: sharedBy,
        sharersPreview: sharersPreview,
        sharersCount: sharersCount,
        dateRanges: dateRanges,
        socialProof: socialProof,
        likersPreview: likersPreview,
        likesCount: likesCount,
        interestedPreview: interestedPreview,
        interestedCount: interestedCount,
        recurrencePhase: recurrencePhase,
        primaryFacet: primaryFacet,
      );

  /// Local-anchored start parsed from [startDatetime] (the next-future
  /// occurrence, or — for an all-past event — the earliest occurrence the
  /// backend falls back to). Null when the event carries no start.
  DateTime? get startAt => parseBackendDateTime(startDatetime)?.toLocal();

  /// True when this event has already happened — no future occurrences
  /// ([dateRanges] is empty, which the backend guarantees means "no upcoming")
  /// AND its last known date is before today. Uses [endDatetime] when present
  /// so a still-running multi-day event isn't marked past. Day-truncated in
  /// local time. A saved/linked event can be past even though most detail
  /// surfaces are future-filtered.
  bool get isPast {
    if (dateRanges.isNotEmpty) return false;
    final end = parseBackendDateTime(endDatetime)?.toLocal();
    final ref = end ?? startAt;
    if (ref == null) return false;
    final now = DateTime.now();
    return DateTime(
      ref.year,
      ref.month,
      ref.day,
    ).isBefore(DateTime(now.year, now.month, now.day));
  }

  factory EventDetailResponse2.fromJson(Map<String, dynamic> json) {
    return EventDetailResponse2(
      id: json['id'] as String,
      title: json['title'] as String,
      descriptionLong: json['description_long'] as String?,
      descriptionShort: json['description_short'] as String?,
      startDatetime: json['start_datetime'] as String?,
      endDatetime: json['end_datetime'] as String?,
      venueId: json['venue_id'] as String?,
      venueName: json['venue_name'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      venueAddress: json['venue_address'] as String?,
      venueCity: json['venue_city'] as String?,
      url: json['url'] as String?,
      category: json['category'] as String?,
      imageUrl: json['image_url'] as String?,
      images: _parseDetailImages(json['images'], json['image_url'] as String?),
      primaryFacet: FacetPair.readFrom(json),
      sharedBy: json['shared_by'] == null
          ? null
          : SharedByUser.fromJson(json['shared_by'] as Map<String, dynamic>),
      sharersPreview:
          (json['sharers_preview'] as List<dynamic>?)
              ?.map((e) => SharedByUser.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      sharersCount: json['sharers_count'] as int? ?? 0,
      dateRanges:
          (json['date_ranges'] as List<dynamic>?)
              ?.map((e) => EventDateRange.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      socialProof: SocialProof.fromJson(
        json['social_proof'] as Map<String, dynamic>,
      ),
      likersPreview: _parseLikers(json['likers_preview']),
      likesCount: json['likes_count'] as int? ?? 0,
      interestedPreview: _parseInterested(json['interested_preview']),
      interestedCount: json['interested_count'] as int? ?? 0,
      recurrencePhase: recurrencePhaseFromWire(json['recurrence_phase']),
    );
  }
}

/// Full venue detail response with social proof and upcoming events
class VenueDetailResponse {
  final String id;
  final String name;

  /// Multi-sentence prose for the long-form description block (Mobile/B2
  /// Reg, Soko/Ink) — rendered below the details block on the venue
  /// detail page. Reads `description_long` from `VenueDetailOut` (PROD-1686
  /// part 2). Either the **full** tier (150-300 words, LLM confidence
  /// ≥ 0.8) or the **medium** tier (50-80 words, confidence 0.5-0.8) —
  /// **never the short tier**. NULL for confidence 0.2-0.5 venues (only
  /// short tier survived gating) or never-enriched venues. **Guaranteed
  /// never to duplicate [descriptionShort]**, so the de-dupe in the
  /// screen layer is now defensive belt-and-braces, not load-bearing.
  ///
  /// Note: the backend still emits a deprecated `description` alias for
  /// transition compatibility — we deliberately ignore it here. Backend
  /// removal is tracked as PROD-1691.
  final String? descriptionLong;

  /// One-liner blurb (~10-20 words / 60-100 chars, Mobile/B2 Reg,
  /// Soko/Shade1) — rendered between the venue name and the tag row.
  /// Reads `description_short` from `VenueDetailOut` (PROD-1686). NULL for
  /// venues never enriched (production today: ~55 % of venues).
  final String? descriptionShort;

  final String? address;
  final String? city;
  final double? latitude;
  final double? longitude;
  final String? imageUrl;
  final double? rating;
  final int? ratingCount;
  final List<String>? tags;
  final String? googlePlaceId;
  final String? website;
  final String? phone;
  final String? instagram;
  final String? twitter;
  final String? facebook;
  final Map<String, dynamic>? openingHours;
  final String? googleMapsUrl;

  /// PROD-3960 / ADR-048 — the **localized** venue-type display label
  /// ("Restaurante chinês" in pt-PT, "Chinese restaurant" in en), resolved
  /// per request by the backend from the venue's primary type (`types[0]`,
  /// ADR-043). This is what the page renders as "what kind of place is this".
  ///
  /// **Render it as received.** It is NOT a slug — do not humanize,
  /// title-case, or map it. (Surrounding whitespace is trimmed at the render
  /// sites for layout; that is not a transformation of the label.) The same
  /// value the feed cards already carry under the same name, so a card and the
  /// detail page it opens cannot disagree.
  ///
  /// The key is always present on `VenueDetailOut` (required-but-nullable), so
  /// there is no absent-key branch. `null` means the venue has no usable
  /// primary type — `types` empty or `types[0]` blank — which is real data,
  /// not a localization failure: a type with no label in the requested locale
  /// falls back to English rather than to null (lenient contract, ADR-048).
  ///
  /// Note [tags] stays the raw, UNLOCALIZED slug list — a different thing.
  final String? primaryTag;

  /// PROD-3829 — the entity's primary discovery facet, when the backend sends
  /// one. Selects the detail-block map pin's teardrop art via
  /// `mapPinKey(primaryFacet:)`.
  ///
  /// **Forward-compatible parse: this response does not carry the field yet.**
  /// Absent / null / `{}` all resolve to null, and a null facet renders the
  /// generic pink `pin-default`. The day the backend adds it, the category art
  /// appears with **no app release** (PROD-3832).
  ///
  /// ⚠️ NEVER synthesise this from `tags` / `category` — that expansion is
  /// deliberately server-side (PROD-2369).
  final FacetPair? primaryFacet;

  /// The user who shared/created this venue, when it is user-generated
  /// (PROD-3134). NULL for system/scraped venues (all venues today, until the
  /// BE adds a venue-level creator). See [SharedByUser].
  final SharedByUser? sharedBy;

  /// PROD-4074 — the full photo set for the detail-page hero collage.
  /// Forward-compatible parse (single `image_url` only today; multi-photo
  /// backend is PROD-1676). Collapses to `[imageUrl]` when present, else
  /// empty. See [EventDetailResponse2.images] and [_parseDetailImages].
  final List<String> images;

  final SocialProof socialProof;
  final List<UpcomingEvent> upcomingEvents;

  /// The "Liked by" row — see [EventDetailResponse2.likersPreview].
  final List<SharedByUser> likersPreview;
  final int likesCount;

  /// The merged "… têm interesse" row — see
  /// [EventDetailResponse2.interestedPreview]; identical semantics.
  final List<InterestedUser> interestedPreview;
  final int interestedCount;

  const VenueDetailResponse({
    required this.id,
    required this.name,
    this.descriptionLong,
    this.descriptionShort,
    this.address,
    this.city,
    this.latitude,
    this.longitude,
    this.imageUrl,
    this.rating,
    this.ratingCount,
    this.tags,
    this.googlePlaceId,
    this.website,
    this.phone,
    this.instagram,
    this.twitter,
    this.facebook,
    this.openingHours,
    this.googleMapsUrl,
    this.images = const [],
    this.sharedBy,
    required this.socialProof,
    this.upcomingEvents = const [],
    this.likersPreview = const [],
    this.likesCount = 0,
    this.interestedPreview = const [],
    this.interestedCount = 0,
    this.primaryFacet,
    this.primaryTag,
  });

  factory VenueDetailResponse.fromJson(Map<String, dynamic> json) {
    return VenueDetailResponse(
      id: json['id'] as String,
      name: json['name'] as String,
      descriptionLong: json['description_long'] as String?,
      descriptionShort: json['description_short'] as String?,
      address: json['address'] as String?,
      city: json['city'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      imageUrl: json['image_url'] as String?,
      rating: (json['rating'] as num?)?.toDouble(),
      ratingCount: json['rating_count'] as int?,
      tags: (json['tags'] as List<dynamic>?)?.cast<String>(),
      googlePlaceId: json['google_place_id'] as String?,
      website: json['website'] as String?,
      phone: json['phone'] as String?,
      instagram: json['instagram'] as String?,
      twitter: json['twitter'] as String?,
      facebook: json['facebook'] as String?,
      openingHours: json['opening_hours'] as Map<String, dynamic>?,
      googleMapsUrl: json['google_maps_url'] as String?,
      images: _parseDetailImages(json['images'], json['image_url'] as String?),
      primaryFacet: FacetPair.readFrom(json),
      primaryTag: json['primary_tag'] as String?,
      sharedBy: json['shared_by'] == null
          ? null
          : SharedByUser.fromJson(json['shared_by'] as Map<String, dynamic>),
      socialProof: SocialProof.fromJson(
        json['social_proof'] as Map<String, dynamic>,
      ),
      upcomingEvents:
          (json['upcoming_events'] as List<dynamic>?)
              ?.map((e) => UpcomingEvent.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      likersPreview: _parseLikers(json['likers_preview']),
      likesCount: json['likes_count'] as int? ?? 0,
      interestedPreview: _parseInterested(json['interested_preview']),
      interestedCount: json['interested_count'] as int? ?? 0,
    );
  }

  /// Applies the strict owner-edit allowlist while a PATCH is in flight.
  /// Presence, rather than a null-coalescing value, matters because nullable
  /// fields may intentionally be cleared by the owner.
  VenueDetailResponse withOwnerEdits(Map<String, dynamic> fields) {
    T? value<T>(String key, T? current) =>
        fields.containsKey(key) ? fields[key] as T? : current;

    return VenueDetailResponse(
      id: id,
      name: value<String>('name', name) ?? name,
      descriptionLong: value<String>('description_long', descriptionLong),
      descriptionShort: value<String>('description_short', descriptionShort),
      address: address,
      city: city,
      latitude: latitude,
      longitude: longitude,
      imageUrl: imageUrl,
      rating: rating,
      ratingCount: ratingCount,
      tags: tags,
      googlePlaceId: googlePlaceId,
      website: value<String>('website', website),
      phone: value<String>('phone', phone),
      instagram: value<String>('instagram', instagram),
      twitter: value<String>('twitter', twitter),
      facebook: value<String>('facebook', facebook),
      openingHours: value<Map<String, dynamic>>('opening_hours', openingHours),
      googleMapsUrl: googleMapsUrl,
      // Not owner-editable (owner photo edits go through a dedicated upload) —
      // forwarded verbatim so the constructor rebuild cannot silently drop it.
      images: images,
      sharedBy: sharedBy,
      socialProof: socialProof,
      upcomingEvents: upcomingEvents,
      // PROD-3829: this method rebuilds the whole response through the
      // constructor, so every field it forgets to forward silently reverts to
      // that field's default rather than being preserved — the same trap as
      // `UserListItem.copyWith`. Three were being dropped:
      //   • `likersPreview` / `likesCount` (pre-existing) — an owner editing
      //     their venue blanked the likers row and reset the count to 0 until
      //     the next refetch (`interestedPreview` / `interestedCount`, which
      //     replaced that row, are forwarded here for the same reason);
      //   • `primaryFacet` (new here) — would blank the pin's category art.
      // Fixed together because they are the identical defect in one method;
      // called out in the PR body as an out-of-scope drive-by.
      likersPreview: likersPreview,
      likesCount: likesCount,
      interestedPreview: interestedPreview,
      interestedCount: interestedCount,
      primaryFacet: primaryFacet,
      // Not owner-editable (the backend derives it from `types`) — forwarded
      // verbatim so the rebuild above cannot silently drop it.
      primaryTag: primaryTag,
    );
  }
}
