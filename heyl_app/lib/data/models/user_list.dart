import 'package:uuid/uuid.dart';

import 'chat_message.dart';
import 'map_pin.dart' show FacetPair;
import 'note_action.dart';
import 'saved_item.dart';
import '../../core/utils/city_resolver.dart';
import '../../core/utils/datetime_parsing.dart';

/// Max length of a saved list item's `tip` (the per-list user note), mirroring
/// the backend `UserListItemCreate.tip` / `UserListItemUpdate.tip`
/// `maxLength: 500` in `open-api/heyl-webapp-v1.openapi.yaml`. Enforce this
/// client-side so notes never 422 on save (PROD-2430 raised the cap from 280).
const int kUserListItemTipMaxLength = 500;

/// List visibility enum
enum ListVisibility {
  public,
  followers,
  private;

  String toJson() => name;

  static ListVisibility fromJson(String json) {
    return ListVisibility.values.firstWhere(
      (e) => e.name == json,
      orElse: () => ListVisibility.private,
    );
  }
}

/// Response fields whose presence matters independently of UI defaults.
/// Explicit null role/kind is meaningful; absent or malformed values are not.
Set<String> _knownListContextFields(Map<String, dynamic> json) =>
    Set.unmodifiable({
      if (ListVisibility.values.any((v) => v.name == json['visibility']))
        'visibility',
      for (final key in ['editor_pick', 'city_guide', 'verified'])
        if (json[key] is bool) key,
      for (final key in ['user_role', 'system_kind'])
        if (json.containsKey(key) &&
            (json[key] == null ||
                (json[key] is String && (json[key] as String).isNotEmpty)))
          key,
    });

/// User list model matching OpenAPI UserListOut schema
class UserList {
  final String id;
  final String ownerId;
  final String name;
  final String? slug;
  final String? description;
  final ListVisibility visibility;
  final bool isCollaborative;
  final bool isDefault;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int itemCount;
  final int memberCount;
  final int followerCount;
  final String? userRole; // 'owner', 'collaborator', 'follower', null
  final bool? isFollowing;

  /// AI suggestions prompt for smart lists
  final String? prompt;

  /// Owner's display name (from owner.full_name)
  final String? ownerName;

  /// Owner's handle (from owner.handle)
  final String? ownerHandle;

  /// Owner's avatar URL (from `owner.avatar_url`).
  ///
  /// **The backend DOES send this** — `PublicListOwnerOut.avatar_url`, added
  /// with the social-profile pilot, which closed the PROD-1703 gap. This
  /// comment used to say the opposite long after it stopped being true, and
  /// that stale claim was taken at face value while scoping the feed's zine
  /// attribution. Null only when the owner has uploaded no photo, in which
  /// case `PersonDot` falls back to their seeded initial.
  final String? ownerAvatarUrl;

  /// Owner's Expert tag (backend PROD-3336, from owner.is_expert). Drives the
  /// compact Expert badge next to the owner name on list attribution.
  final bool ownerIsExpert;

  /// First item's image URL for display (optional, loaded separately)
  final String? coverImageUrl;

  /// PROD-1907 cover recipe (zine cover) — see
  /// `heyl_app/lib/features/lists/utils/zine_cover_recipe.dart`. Stored
  /// raw as strings so the FE resolver can apply deterministic fallbacks
  /// when values are missing or unsupported. Empty/legacy rows still
  /// render because `ZineCoverRecipe.fromFields` consumes nulls.
  final String? coverType;
  final String? coverColor;
  final String? coverTexture;
  final String? coverTextColor;
  final String? coverItemId;

  /// PROD-1932 — server-resolved image URL for `cover_item_id` when
  /// `cover_type='item_image'`. Already proxied via the BE's image_proxy
  /// so the FE renders directly with no client-side URL transformation.
  /// Null when `cover_type != item_image`, the referenced item is
  /// deleted, or the item has no image. Closes the shelf-vs-zine cover
  /// divergence — discovery shelves and lists-hub cards (which lack the
  /// full items collection) can now render the item photo without a
  /// client-side lookup. Read-only from the FE perspective; never sent
  /// back on `UserListUpdate`.
  final String? coverItemImageUrl;

  /// PROD-3217 — proxy URL of the app-rendered 4:5 zine-cover PNG the
  /// backend composites into the IG-Story share card. The Flutter app is
  /// the single renderer of the cover (glyph + title + texture baked in);
  /// it uploads the capture via `POST /lists/{id}/cover/share-render` on
  /// cover-save (debounced) and share-if-missing. Null means no render has
  /// been uploaded yet — the backend then falls back to a plain solid
  /// cover, and the FE uses null to decide whether to render before
  /// sharing. Read-only / BE-derived: never sent back on `UserListUpdate`.
  final String? coverShareRenderUrl;

  /// PROD-3217 — sha1 signature of the cover recipe [coverShareRenderUrl] was
  /// rendered from. The BE stamps it on every render upload; the FE recomputes
  /// it from the cover fields (`computeCoverRenderSignature`) and re-renders +
  /// uploads whenever it drifts, so the shared card stays fresh across app
  /// restarts and edit paths the in-memory counters missed. Null means the
  /// render was never stamped → the FE treats it as stale. Read-only / BE-derived.
  final String? coverShareRenderSignature;

  /// PROD-2297 — per-list curator toggles that hide individual cover
  /// chrome elements (title text, paper-texture overlay, Soko logo).
  /// Default `true` so older API responses that omit the keys keep
  /// rendering chrome. For `from_profiling` lists the BE writes `false`
  /// (both backfill and creation path), so the curated
  /// `Zine-Profiling-*.jpg` artwork renders clean. Renderer ANDs each
  /// with the widget-level `showTitle/Logo` args — either hiding gate
  /// wins.
  final bool coverShowTitle;
  final bool coverShowTexture;
  final bool coverShowLogo;

  /// Preview images from first few items (for collage display)
  final List<String>? previewImages;

  /// Discovery-shelf flags (PROD-1513). Default false when the backend
  /// payload omits the field — older list endpoints don't include them.
  final bool editorPick;
  final bool cityGuide;
  final bool verified;

  /// System-managed identity of this list (PROD-1741). `null` for user-
  /// created lists. Documented values: `from_instagram_share` (IG-share
  /// auto-list), `from_onboarding` (onboarding seed lists), `saved_items`
  /// (per-user Saved Items list), `weekly_bundle` (auto-managed "This Week"
  /// list mirrored from the weekly bundle), `user_contributions` (PROD-2404
  /// auto-managed "As minhas contribuições" list, lazy-created on first
  /// successful photo→event extraction), `saved_places` / `saved_events`
  /// (PROD-3873 auto-filed "Os meus sítios" / "Os meus eventos"). Treat
  /// unknown values as opaque
  /// per the OpenAPI contract: always go through [isSystemManaged] /
  /// kind-specific getters or explicit equality — never substring-match
  /// the list name.
  final String? systemKind;

  /// Keeps absent response metadata distinct from display defaults. Locally
  /// constructed lists know their required visibility; callers may explicitly
  /// declare additional known fields. Preserved through copies and caching.
  final Set<String> knownContextFields;

  /// True for any backend-managed list (Instagram share, onboarding seed,
  /// saved items, weekly bundle, future kinds). Use this to gate the
  /// "Auto" badge + rename/delete guards — the per-kind getters are only
  /// for branch-specific behaviour like icons or open helpers.
  bool get isSystemManaged => systemKind != null;

  /// True when the backend has marked this list as the auto-managed
  /// "From Instagram" list. Use this — never `name.contains('instagram')` —
  /// to gate Instagram-share-specific UI / behaviour.
  bool get isFromInstagramShare => systemKind == 'from_instagram_share';

  /// True when this is the auto-managed "As minhas contribuições" list
  /// (PROD-2404). Lazy-created on first successful photo→event extraction.
  /// Use this — never `name.contains('contribu')` — to gate contribution-
  /// specific UI / behaviour.
  bool get isUserContributions => systemKind == 'user_contributions';

  /// True for the per-user "Saved Items" ledger (`saved_items`). Every genuine
  /// save also lands here; it is the canonical record.
  bool get isSavedItems => systemKind == 'saved_items';

  /// True for the auto-filed "Os meus sítios" list (`saved_places`, PROD-3873).
  /// Populated by the server routing venue saves — the user never files here.
  bool get isSavedPlaces => systemKind == 'saved_places';

  /// True for the auto-filed "Os meus eventos" list (`saved_events`,
  /// PROD-3873). Populated by the server routing event saves.
  bool get isSavedEvents => systemKind == 'saved_events';

  /// True for the three auto-managed "save" lists shown together in their own
  /// hub section above the user's zines (PROD-3873): the Saved Items ledger and
  /// the two typed lists. Distinct from [isSystemManaged], which also covers
  /// weekly-bundle / onboarding / IG-share kinds that don't belong in that
  /// section.
  bool get isSavedCollection => isSavedItems || isSavedPlaces || isSavedEvents;

  /// URL-friendly identifier (slug if available, otherwise UUID)
  String get urlIdentifier => slug ?? id;

  const UserList({
    required this.id,
    required this.ownerId,
    required this.name,
    this.slug,
    this.description,
    required this.visibility,
    required this.isCollaborative,
    required this.isDefault,
    required this.createdAt,
    required this.updatedAt,
    required this.itemCount,
    required this.memberCount,
    required this.followerCount,
    this.userRole,
    this.isFollowing,
    this.prompt,
    this.ownerName,
    this.ownerHandle,
    this.ownerAvatarUrl,
    this.ownerIsExpert = false,
    this.coverImageUrl,
    this.coverType,
    this.coverColor,
    this.coverTexture,
    this.coverTextColor,
    this.coverItemId,
    this.coverItemImageUrl,
    this.coverShareRenderUrl,
    this.coverShareRenderSignature,
    this.coverShowTitle = true,
    this.coverShowTexture = true,
    this.coverShowLogo = true,
    this.previewImages,
    this.editorPick = false,
    this.cityGuide = false,
    this.verified = false,
    this.systemKind,
    this.knownContextFields = const {'visibility'},
  });

  factory UserList.fromJson(Map<String, dynamic> json) {
    // Parse owner name from nested owner object
    final owner = json['owner'] as Map<String, dynamic>?;

    return UserList(
      knownContextFields: _knownListContextFields(json),
      id: json['id'] as String,
      ownerId: json['owner_id'] as String,
      name: json['name'] as String,
      slug: json['slug'] as String?,
      description: json['description'] as String?,
      visibility: ListVisibility.fromJson(
        json['visibility'] as String? ?? 'private',
      ),
      isCollaborative: json['is_collaborative'] as bool? ?? false,
      isDefault: json['is_default'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      itemCount: json['item_count'] as int? ?? 0,
      memberCount: json['member_count'] as int? ?? 0,
      followerCount: json['follower_count'] as int? ?? 0,
      userRole: json['user_role'] as String?,
      isFollowing: json['is_following'] as bool?,
      prompt: json['prompt'] as String?,
      ownerName: owner?['full_name'] as String?,
      ownerHandle: owner?['handle'] as String?,
      ownerAvatarUrl: owner?['avatar_url'] as String?,
      ownerIsExpert: owner?['is_expert'] as bool? ?? false,
      coverImageUrl: json['cover_image_url'] as String?,
      coverType: json['cover_type'] as String?,
      coverColor: json['cover_color'] as String?,
      coverTexture: json['cover_texture'] as String?,
      coverTextColor: json['cover_text_color'] as String?,
      coverItemId: json['cover_item_id'] as String?,
      coverItemImageUrl: json['cover_item_image_url'] as String?,
      coverShareRenderUrl: json['cover_share_render_url'] as String?,
      coverShareRenderSignature:
          json['cover_share_render_signature'] as String?,
      coverShowTitle: json['cover_show_title'] as bool? ?? true,
      coverShowTexture: json['cover_show_texture'] as bool? ?? true,
      coverShowLogo: json['cover_show_logo'] as bool? ?? true,
      previewImages: (json['preview_images'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      editorPick: json['editor_pick'] as bool? ?? false,
      cityGuide: json['city_guide'] as bool? ?? false,
      verified: json['verified'] as bool? ?? false,
      systemKind: json['system_kind'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'owner_id': ownerId,
      'name': name,
      if (slug != null) 'slug': slug,
      if (description != null) 'description': description,
      if (knownContextFields.contains('visibility'))
        'visibility': visibility.toJson(),
      'is_collaborative': isCollaborative,
      'is_default': isDefault,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'item_count': itemCount,
      'member_count': memberCount,
      'follower_count': followerCount,
      if (userRole != null || knownContextFields.contains('user_role'))
        'user_role': userRole,
      if (isFollowing != null) 'is_following': isFollowing,
      if (prompt != null) 'prompt': prompt,
      if (coverImageUrl != null) 'cover_image_url': coverImageUrl,
      if (coverType != null) 'cover_type': coverType,
      if (coverColor != null) 'cover_color': coverColor,
      if (coverTexture != null) 'cover_texture': coverTexture,
      if (coverTextColor != null) 'cover_text_color': coverTextColor,
      if (coverItemId != null) 'cover_item_id': coverItemId,
      if (coverItemImageUrl != null) 'cover_item_image_url': coverItemImageUrl,
      if (coverShareRenderUrl != null)
        'cover_share_render_url': coverShareRenderUrl,
      if (coverShareRenderSignature != null)
        'cover_share_render_signature': coverShareRenderSignature,
      'cover_show_title': coverShowTitle,
      'cover_show_texture': coverShowTexture,
      'cover_show_logo': coverShowLogo,
      if (previewImages != null) 'preview_images': previewImages,
      if (editorPick || knownContextFields.contains('editor_pick'))
        'editor_pick': editorPick,
      if (cityGuide || knownContextFields.contains('city_guide'))
        'city_guide': cityGuide,
      if (verified || knownContextFields.contains('verified'))
        'verified': verified,
      if (systemKind != null || knownContextFields.contains('system_kind'))
        'system_kind': systemKind,
      if (ownerHandle != null || ownerName != null || ownerAvatarUrl != null)
        'owner': {
          'id': ownerId,
          if (ownerHandle != null) 'handle': ownerHandle,
          if (ownerName != null) 'full_name': ownerName,
          if (ownerAvatarUrl != null) 'avatar_url': ownerAvatarUrl,
          'is_expert': ownerIsExpert,
        },
    };
  }

  UserList copyWith({
    String? id,
    String? ownerId,
    String? name,
    String? slug,
    String? description,
    ListVisibility? visibility,
    bool? isCollaborative,
    bool? isDefault,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? itemCount,
    int? memberCount,
    int? followerCount,
    String? userRole,
    bool? isFollowing,
    String? prompt,
    bool clearPrompt = false,
    String? ownerName,
    String? ownerHandle,
    String? ownerAvatarUrl,
    bool? ownerIsExpert,
    String? coverImageUrl,
    bool clearCover = false,
    String? coverType,
    String? coverColor,
    bool clearCoverColor = false,
    String? coverTexture,
    bool clearCoverTexture = false,
    String? coverTextColor,
    bool clearCoverTextColor = false,
    String? coverItemId,
    bool clearCoverItemId = false,
    String? coverItemImageUrl,
    bool clearCoverItemImageUrl = false,
    String? coverShareRenderUrl,
    String? coverShareRenderSignature,
    bool clearCoverRecipe = false,
    bool? coverShowTitle,
    bool? coverShowTexture,
    bool? coverShowLogo,
    List<String>? previewImages,
    bool? editorPick,
    bool? cityGuide,
    bool? verified,
    String? systemKind,
  }) {
    return UserList(
      knownContextFields: Set.unmodifiable({
        ...knownContextFields,
        if (visibility != null) 'visibility',
        if (userRole != null) 'user_role',
        if (systemKind != null) 'system_kind',
        if (editorPick != null) 'editor_pick',
        if (cityGuide != null) 'city_guide',
        if (verified != null) 'verified',
      }),
      id: id ?? this.id,
      ownerId: ownerId ?? this.ownerId,
      name: name ?? this.name,
      slug: slug ?? this.slug,
      description: description ?? this.description,
      visibility: visibility ?? this.visibility,
      isCollaborative: isCollaborative ?? this.isCollaborative,
      isDefault: isDefault ?? this.isDefault,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      itemCount: itemCount ?? this.itemCount,
      memberCount: memberCount ?? this.memberCount,
      followerCount: followerCount ?? this.followerCount,
      userRole: userRole ?? this.userRole,
      isFollowing: isFollowing ?? this.isFollowing,
      prompt: clearPrompt ? null : (prompt ?? this.prompt),
      ownerName: ownerName ?? this.ownerName,
      ownerHandle: ownerHandle ?? this.ownerHandle,
      ownerAvatarUrl: ownerAvatarUrl ?? this.ownerAvatarUrl,
      ownerIsExpert: ownerIsExpert ?? this.ownerIsExpert,
      coverImageUrl: clearCover ? null : (coverImageUrl ?? this.coverImageUrl),
      coverType: clearCoverRecipe ? null : (coverType ?? this.coverType),
      coverColor: (clearCoverRecipe || clearCoverColor)
          ? null
          : (coverColor ?? this.coverColor),
      coverTexture: (clearCoverRecipe || clearCoverTexture)
          ? null
          : (coverTexture ?? this.coverTexture),
      coverTextColor: (clearCoverRecipe || clearCoverTextColor)
          ? null
          : (coverTextColor ?? this.coverTextColor),
      coverItemId: (clearCoverRecipe || clearCoverItemId)
          ? null
          : (coverItemId ?? this.coverItemId),
      coverItemImageUrl: (clearCoverRecipe || clearCoverItemImageUrl)
          ? null
          : (coverItemImageUrl ?? this.coverItemImageUrl),
      coverShareRenderUrl: coverShareRenderUrl ?? this.coverShareRenderUrl,
      coverShareRenderSignature:
          coverShareRenderSignature ?? this.coverShareRenderSignature,
      coverShowTitle: coverShowTitle ?? this.coverShowTitle,
      coverShowTexture: coverShowTexture ?? this.coverShowTexture,
      coverShowLogo: coverShowLogo ?? this.coverShowLogo,
      previewImages: previewImages ?? this.previewImages,
      editorPick: editorPick ?? this.editorPick,
      cityGuide: cityGuide ?? this.cityGuide,
      verified: verified ?? this.verified,
      systemKind: systemKind ?? this.systemKind,
    );
  }

  bool get isOwner => userRole == 'owner';
}

/// User list item model matching OpenAPI UserListItemOut schema
class UserListItem {
  final String id;
  final String listId;
  final String addedById;
  final SavedItemType itemType;
  final String? eventId;
  final String? venueId;
  final String? tip;
  final int sortOrder;
  final DateTime addedAt;
  final DateTime? updatedAt;
  final bool isDeleted;
  final DateTime? deletedAt;

  /// Whether this item's image is used as the list cover
  final bool isCover;

  /// PROD-2935 — this item is kept out of the algorithm (power-user opt-out).
  final bool excludeFromAlgorithm;

  /// Expanded event data
  final Map<String, dynamic>? event;

  /// Expanded venue data
  final Map<String, dynamic>? venue;

  /// User who added the item
  final Map<String, dynamic>? addedBy;

  /// Display name of the person who added the item (the note's author).
  /// From `added_by.full_name`; null when the backend didn't expand it.
  String? get addedByName => (addedBy?['full_name'] as String?)?.trim();

  /// Avatar URL of the person who added the item, when the backend expands it.
  /// Often null today — pair with [addedByName]/[addedById] so a `PersonDot`
  /// degrades to the seeded initial until the photo ships.
  String? get addedByAvatarUrl => (addedBy?['avatar_url'] as String?)?.trim();

  /// PROD-3829 — the item's primary discovery facet, when the backend sends
  /// one. Selects the map pin's teardrop art via `mapPinKey(primaryFacet:)`.
  ///
  /// **Forward-compatible parse: no payload carries this field yet.** Absent
  /// / null / `{}` all resolve to null (`FacetPair.fromJson` returns null for
  /// a missing or parentless object), and a null facet renders the generic
  /// pink `pin-default`. The day an endpoint starts sending it, the category
  /// art appears on the next payload with **no app release** — which is the
  /// whole point of parsing it before it exists (PROD-3831/3832 ship it
  /// server-side).
  ///
  /// ⚠️ NEVER synthesise this from `category`, `tags` or `place_types`. The
  /// id↔category expansion is deliberately server-side (PROD-2369) so a
  /// stale client can't drift from it. A null facet stays null.
  ///
  /// Deliberately **top-level**, NOT inside the synthesized [event] / [venue]
  /// maps. Those maps mirror wire shapes and already stuff `category` into
  /// `'tags': [category]`; following that pattern here would weld the pin
  /// payloads' wire format to this internal model. The three slim-pin
  /// adapters copy the facet across into this field instead.
  final FacetPair? primaryFacet;

  const UserListItem({
    required this.id,
    required this.listId,
    required this.addedById,
    required this.itemType,
    this.eventId,
    this.venueId,
    this.tip,
    this.sortOrder = 0,
    required this.addedAt,
    this.updatedAt,
    this.isDeleted = false,
    this.deletedAt,
    this.isCover = false,
    this.excludeFromAlgorithm = false,
    this.event,
    this.venue,
    this.addedBy,
    this.primaryFacet,
  });

  /// Display title (from event or venue)
  String? get title {
    if (event != null) {
      return event!['title'] as String?;
    } else if (venue != null) {
      return venue!['name'] as String?;
    }
    return null;
  }

  /// Display image URL (from event or venue)
  String? get imageUrl {
    if (event != null) {
      return event!['image_url'] as String?;
    } else if (venue != null) {
      return venue!['image_url'] as String?;
    }
    return null;
  }

  /// Display category
  String? get category {
    if (event != null) {
      return event!['category'] as String?;
    } else if (venue != null) {
      final tags = venue!['tags'] as List<dynamic>?;
      return tags?.isNotEmpty == true ? tags!.first as String? : null;
    }
    return null;
  }

  /// The second-level type beneath [category] — the localized display label
  /// the backend derives from the event's `sub_categories[0]` (e.g. "Festival"
  /// under "Culture") or the venue's `types[1]`. Distinct from [category]
  /// (which the eyebrow shows), so surfaces can render both without repeating.
  /// Null when the entity carries no sub-category / second type.
  String? get subcategory {
    final raw = (event?['subcategory'] ?? venue?['subcategory']) as String?;
    final trimmed = raw?.trim();
    return (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
  }

  /// Curated short description for the underlying entity. Reads
  /// `description_short` from the embedded `venue` / `event` map (per
  /// OpenAPI `Venue.description_short` / `Event.description_short`).
  ///
  /// For venues this is an LLM-generated 10-20 word tag-line and is
  /// the right value to render in compact list rows (matches Figma's
  /// "Bar de vinhos naturais" expectation on `6197:5954` § Sítios).
  ///
  /// For events the field semantics differ — see the OpenAPI doc on
  /// `Event.description_short`: scraper-produced, highly variable
  /// length, ~54 % NULL, ~6 % equal to `description_long`. Callers
  /// rendering compact rows for events should fall back to other
  /// fields when this is null or too long for the slot.
  String? get descriptionShort {
    if (event != null) {
      return event!['description_short'] as String?;
    } else if (venue != null) {
      return venue!['description_short'] as String?;
    }
    return null;
  }

  /// PROD-4072 — already-localized, already-formatted price string for
  /// display (e.g. `Grátis`, `10–20 €`, `A partir de 12 €`). Mirrors the
  /// discovery feed's `FeedEventItem.price_label`: render exactly as
  /// received, never re-derive from raw fields. Events only (venues carry no
  /// price); `null` when there is nothing to show — the common case.
  String? get priceLabel {
    if (event != null) {
      return (event!['price_label'] as String?)?.trim();
    }
    return null;
  }

  /// Latitude for map display
  double? get latitude {
    if (event != null) {
      return (event!['latitude'] as num?)?.toDouble();
    } else if (venue != null) {
      return (venue!['latitude'] as num?)?.toDouble();
    }
    return null;
  }

  /// Longitude for map display
  double? get longitude {
    if (event != null) {
      return (event!['longitude'] as num?)?.toDouble();
    } else if (venue != null) {
      return (venue!['longitude'] as num?)?.toDouble();
    }
    return null;
  }

  /// Event date (for calendar view) — single date.
  ///
  /// For multi-occurrence events this returns only the FIRST occurrence's
  /// `start_at` (because the BE populates `event.start_datetime` with the
  /// earliest upcoming occurrence). Prefer [occurrenceDates] when rendering
  /// calendar marks so every date is represented.
  DateTime? get eventDate {
    if (event != null) {
      final dateStr = (event!['start_datetime'] ?? event!['date']) as String?;
      if (dateStr != null) {
        return parseBackendDateTime(dateStr);
      }
    }
    return null;
  }

  /// Every date this event happens on. For multi-occurrence events the
  /// BE returns `event.occurrences` (a list of `{start_at, …}` objects)
  /// alongside the legacy `start_datetime`; this getter unifies both:
  ///
  /// - If `event.occurrences` is a non-empty list, returns every
  ///   `start_at` parsed to `DateTime`. Each occurrence yields one entry.
  /// - Otherwise falls back to `[eventDate]` when [eventDate] is non-null.
  /// - Otherwise returns an empty list.
  ///
  /// Used by `ListCalendarView` to mark every date an event occurs on.
  /// Returning a `List` (not a `Set`) preserves BE-provided order
  /// (sorted ASC by `start_at`) so the calendar renders entries in
  /// chronological order without re-sorting.
  List<DateTime> get occurrenceDates {
    if (event != null) {
      final occs = event!['occurrences'];
      if (occs is List && occs.isNotEmpty) {
        final dates = <DateTime>[];
        for (final o in occs) {
          if (o is Map) {
            final parsed = parseBackendDateTime(o['start_at'] as String?);
            if (parsed != null) dates.add(parsed);
          }
        }
        if (dates.isNotEmpty) return dates;
      }
    }
    final single = eventDate;
    return single == null ? const [] : [single];
  }

  /// Every calendar day this event is present on, with multi-day occurrences
  /// expanded into the full set of `[start_at .. end_at]` days (inclusive).
  ///
  /// Unlike [occurrenceDates] — which lists each occurrence's `start_at` as a
  /// single point in time — this getter walks each occurrence's date range
  /// and emits one entry per midnight-truncated day it spans. Days are
  /// deduped across occurrences. Used by `ListCalendarView` to highlight
  /// every day in a multi-day event's range (PROD-2018).
  ///
  /// Falls back to `[eventDate]` (day-truncated) when no `occurrences` are
  /// present, mirroring the [occurrenceDates] fallback.
  List<DateTime> get occurrenceDays {
    final raw = event?['occurrences'];
    if (raw is List && raw.isNotEmpty) {
      final days = <DateTime>[];
      final seen = <int>{};
      for (final o in raw) {
        if (o is! Map) continue;
        final start = parseBackendDateTime(o['start_at'] as String?);
        if (start == null) continue;
        // Malformed end_at falls back to a single-day occurrence.
        final end = parseBackendDateTime(o['end_at'] as String?) ?? start;
        final firstDay = DateTime(start.year, start.month, start.day);
        final lastDay = DateTime(end.year, end.month, end.day);
        final span = lastDay.difference(firstDay).inDays;
        if (span < 0) continue;
        for (int i = 0; i <= span; i++) {
          final d = DateTime(firstDay.year, firstDay.month, firstDay.day + i);
          final key = d.year * 10000 + d.month * 100 + d.day;
          if (seen.add(key)) days.add(d);
        }
      }
      if (days.isNotEmpty) return days;
    }
    final single = eventDate;
    if (single == null) return const [];
    return [DateTime(single.year, single.month, single.day)];
  }

  /// Address for display
  String? get address {
    if (event != null) {
      return event!['venue_address'] as String?;
    } else if (venue != null) {
      return venue!['address'] as String?;
    }
    return null;
  }

  /// City for display
  String? get city {
    if (event != null) {
      return event!['venue_city'] as String?;
    } else if (venue != null) {
      return venue!['city'] as String?;
    }
    return null;
  }

  /// URL for external links
  String? get url {
    if (event != null) {
      return event!['url'] as String?;
    } else if (venue != null) {
      return venue!['google_maps_url'] as String?;
    }
    return null;
  }

  /// Venue website URL
  String? get website {
    if (venue != null) {
      return venue!['website'] as String?;
    }
    return null;
  }

  /// Google Maps URL
  String? get googleMapsUrl {
    if (venue != null) {
      return venue!['google_maps_url'] as String?;
    }
    return null;
  }

  /// Venue phone number
  String? get phone {
    if (venue != null) {
      return venue!['phone'] as String?;
    }
    return null;
  }

  /// Venue opening hours (raw JSON map with lowercase day keys)
  Map<String, dynamic>? get openingHours {
    if (venue != null) {
      return venue!['opening_hours'] as Map<String, dynamic>?;
    }
    return null;
  }

  /// Description for detail view
  String? get description {
    if (event != null) {
      return event!['description'] as String?;
    } else if (venue != null) {
      return venue!['description'] as String?;
    }
    return null;
  }

  /// Venue name for events
  String? get venueName {
    if (event != null) {
      return event!['venue_name'] as String?;
    }
    return null;
  }

  /// Neighbourhood (finer than city). PROD-4115 — events carry it on the
  /// `event` map (from the linked venue); places on the `venue` map. Null when
  /// the backend has no neighbourhood for the entity.
  String? get neighbourhood =>
      (event?['neighborhood'] ?? venue?['neighborhood']) as String?;

  /// The earliest occurrence whose calendar day matches [day] (year /
  /// month / day equality; time-of-day ignored). Returns null when the
  /// item has no occurrences on that day. Used by the calendar agenda
  /// row to pick which occurrence's time-of-day to render when an
  /// event has multiple occurrences (e.g. morning + evening shows).
  ListItemEventOccurrence? firstOccurrenceOnDay(DateTime day) {
    final all = occurrences;
    if (all.isEmpty) return null;
    ListItemEventOccurrence? best;
    for (final o in all) {
      if (o.startAt.year == day.year &&
          o.startAt.month == day.month &&
          o.startAt.day == day.day) {
        if (best == null || o.startAt.isBefore(best.startAt)) {
          best = o;
        }
      }
    }
    return best;
  }

  /// Upcoming occurrences for the event (sorted by start_at ASC).
  /// Empty for non-event items, or for events whose only occurrences are
  /// in the past — in that case the legacy `start_datetime` / `venue_*`
  /// fields above still surface the earliest past occurrence.
  List<ListItemEventOccurrence> get occurrences {
    if (event == null) return const [];
    final raw = event!['occurrences'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(ListItemEventOccurrence.fromJson)
        .toList();
  }

  /// Total upcoming occurrences. Equals `occurrences.length` today; the
  /// field exists so clients can decide between full list and "+N more".
  int get totalOccurrences {
    if (event == null) return 0;
    final v = event!['total_occurrences'];
    if (v is int) return v;
    return occurrences.length;
  }

  /// Rating for places
  double? get rating {
    if (venue != null) {
      return (venue!['rating'] as num?)?.toDouble();
    }
    return null;
  }

  /// Rating count for places
  int? get ratingCount {
    if (venue != null) {
      return venue!['rating_count'] as int?;
    }
    return null;
  }

  /// Google Place ID for matching external places
  String? get googlePlaceId {
    if (venue != null) {
      return venue!['google_place_id'] as String?;
    }
    return null;
  }

  /// The actual target ID (either event or venue)
  String get targetId =>
      itemType == SavedItemType.event ? (eventId ?? '') : (venueId ?? '');

  /// Stable identity for the underlying entity, used to dedupe items that
  /// represent the same event/venue saved across multiple lists. Same
  /// entity in two lists → same [entityKey]; different list rows therefore
  /// collapse to a single calendar entry (PROD-1975). Falls through
  /// `eventId → venueId → googlePlaceId`; returns `null` when none are
  /// available (callers should fall back to [id]).
  String? get entityKey => eventId ?? venueId ?? googlePlaceId;

  /// Build a [SavedItem] view of this list item for the detail sheet.
  SavedItem toSavedItem() {
    return SavedItem(
      savedId: id,
      type: itemType,
      eventId: eventId,
      venueId: venueId,
      createdAt: addedAt,
      title: title,
      imageUrl: imageUrl,
      category: category,
      address: address,
      city: city,
      latitude: latitude,
      longitude: longitude,
      website: website,
      googleMapsUrl: googleMapsUrl,
      phone: phone,
      openingHours: openingHours,
      description: description,
      url: url,
      date: eventDate?.toIso8601String(),
      venueName: venueName,
    );
  }

  factory UserListItem.fromJson(Map<String, dynamic> json) {
    return UserListItem(
      id: json['id'] as String,
      listId: json['list_id'] as String,
      addedById: json['added_by_id'] as String,
      itemType: SavedItemType.fromJson(json['item_type'] as String? ?? 'event'),
      eventId: json['event_id'] as String?,
      venueId: json['venue_id'] as String?,
      tip: json['tip'] as String?,
      sortOrder: json['sort_order'] as int? ?? 0,
      addedAt: DateTime.parse(json['added_at'] as String),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : null,
      isDeleted: json['is_deleted'] as bool? ?? false,
      deletedAt: json['deleted_at'] != null
          ? DateTime.parse(json['deleted_at'] as String)
          : null,
      isCover: json['is_cover'] as bool? ?? false,
      excludeFromAlgorithm: json['exclude_from_algorithm'] as bool? ?? false,
      event: json['event'] as Map<String, dynamic>?,
      venue: json['venue'] as Map<String, dynamic>?,
      addedBy: json['added_by'] as Map<String, dynamic>?,
      primaryFacet: FacetPair.readFrom(json),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'list_id': listId,
      'added_by_id': addedById,
      'item_type': itemType.toJson(),
      if (eventId != null) 'event_id': eventId,
      if (venueId != null) 'venue_id': venueId,
      if (tip != null) 'tip': tip,
      'sort_order': sortOrder,
      'added_at': addedAt.toIso8601String(),
      if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
      'is_deleted': isDeleted,
      if (deletedAt != null) 'deleted_at': deletedAt!.toIso8601String(),
      'is_cover': isCover,
      if (event != null) 'event': event,
      if (venue != null) 'venue': venue,
      if (addedBy != null) 'added_by': addedBy,
      if (primaryFacet != null) 'primary_facet': primaryFacet!.toJson(),
    };
  }

  UserListItem copyWith({
    String? id,
    String? listId,
    String? addedById,
    SavedItemType? itemType,
    String? eventId,
    String? venueId,
    String? tip,
    bool clearTip = false,
    int? sortOrder,
    DateTime? addedAt,
    DateTime? updatedAt,
    bool? isDeleted,
    DateTime? deletedAt,
    bool? isCover,
    Map<String, dynamic>? event,
    Map<String, dynamic>? venue,
    Map<String, dynamic>? addedBy,
    bool? excludeFromAlgorithm,
    FacetPair? primaryFacet,
  }) {
    return UserListItem(
      id: id ?? this.id,
      listId: listId ?? this.listId,
      addedById: addedById ?? this.addedById,
      itemType: itemType ?? this.itemType,
      eventId: eventId ?? this.eventId,
      venueId: venueId ?? this.venueId,
      tip: clearTip ? null : (tip ?? this.tip),
      sortOrder: sortOrder ?? this.sortOrder,
      addedAt: addedAt ?? this.addedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
      isCover: isCover ?? this.isCover,
      event: event ?? this.event,
      venue: venue ?? this.venue,
      addedBy: addedBy ?? this.addedBy,
      // PROD-3829: both of these MUST be forwarded. `copyWith` rebuilds the
      // object through the constructor, so any field it omits silently falls
      // back to the constructor default rather than being preserved — the
      // copy comes back with the value erased, and nothing warns.
      //
      // `excludeFromAlgorithm` was already being dropped this way (it defaults
      // to `false`, so every copyWith quietly opted a power-user's excluded
      // item back into the algorithm). Fixed here as a one-line drive-by
      // rather than left in place next to its identical twin — see the PR body.
      excludeFromAlgorithm: excludeFromAlgorithm ?? this.excludeFromAlgorithm,
      primaryFacet: primaryFacet ?? this.primaryFacet,
    );
  }
}

/// Response of `POST /app/lists/{list_id}/items` — the written item plus what
/// the add actually did (`UserListItemAddOut`, OpenAPI v1.50.0 / PROD-3295).
///
/// Exists as a wrapper rather than as fields on [UserListItem] because that
/// model is also what every *read* path returns; a count there would be a
/// defaulted, meaningless number on every GET. The backend split the schema for
/// the same reason.
///
/// Both extra fields are **nullable** on purpose: they are additive, and a
/// backend predating PROD-3295 simply omits them (production runs `main`, which
/// does not carry it yet). Callers must treat null as "unknown" and omit the
/// analytics property rather than substituting a locally-derived guess — see
/// [UserListItemAddResult.listItemCount].
class UserListItemAddResult {
  const UserListItemAddResult({
    required this.item,
    this.listItemCount,
    this.created,
    this.noteAction = NoteAction.unknown,
  });

  /// The created — or, when [created] is false, the pre-existing — item.
  final UserListItem item;

  /// The list's true non-deleted item count AFTER this write, computed by the
  /// backend inside the writing transaction and serialised per list, so
  /// consecutive adds never skip or repeat a value.
  ///
  /// This is the ONLY valid source for the `list_size_after` analytics
  /// property. Do not clamp it, `max()` it against local state, or fall back to
  /// the provider's optimistic count when it looks wrong — that reintroduces
  /// exactly the drift PROD-3296 removed. Null means the backend didn't send
  /// it; omit the property in that case.
  final int? listItemCount;

  /// Whether this request actually inserted, as opposed to being an idempotent
  /// re-add of an item already in the list.
  ///
  /// When false the list did not grow and [listItemCount] is unchanged, so no
  /// `list_item_add` may be emitted: a repeated value is indistinguishable from
  /// the defect this replaced, and it would re-fire Growth's
  /// `list_size_after == 3` Klaviyo flow for a user who added nothing.
  final bool? created;

  /// The authoritative note transition this write applied to the item's note,
  /// derived by the backend inside the writing transaction (PROD-4552). A
  /// backend predating that contract omits `note_action`; [NoteAction.fromWire]
  /// maps the absence to [NoteAction.unknown] so the client reports "unknown"
  /// rather than inferring a transition.
  final NoteAction noteAction;

  /// `UserListItemAddOut` is `allOf: [UserListItemOut, {...}]`, i.e. a flat
  /// object, so the item parses from the same map.
  factory UserListItemAddResult.fromJson(Map<String, dynamic> json) {
    return UserListItemAddResult(
      item: UserListItem.fromJson(json),
      listItemCount: json['list_item_count'] as int?,
      created: json['created'] as bool?,
      noteAction: NoteAction.fromWire(json['note_action'] as String?),
    );
  }
}

/// Result of a list-item **tip edit** (`PATCH /lists/{id}/items/{item_id}`,
/// response schema `UserListItemWriteOut`): the echoed membership row plus the
/// authoritative [noteAction] the write applied. Kept distinct from
/// [UserListItemAddResult] because a PATCH is never an insertion — it carries no
/// `created`/`list_item_count` — but, like the add path, needs the backend's
/// note transition so the client can emit the right `list_element_note` (and
/// suppress `unchanged`) without inferring it from a stale local tip.
class UserListItemWriteResult {
  const UserListItemWriteResult({
    required this.item,
    this.noteAction = NoteAction.unknown,
  });

  /// The membership row after the write.
  final UserListItem item;

  /// The authoritative note transition (PROD-4552); [NoteAction.unknown] when an
  /// older backend omits the field.
  final NoteAction noteAction;

  factory UserListItemWriteResult.fromJson(Map<String, dynamic> json) {
    return UserListItemWriteResult(
      item: UserListItem.fromJson(json),
      noteAction: NoteAction.fromWire(json['note_action'] as String?),
    );
  }
}

/// Source types for list/item creation tracking
class ListSource {
  static const String chat = 'chat';
  static const String listUi = 'list_ui';
  static const String listSearch = 'list_search';
  static const String dailyDrop = 'daily_drop';
  static const String weeklyBundle = 'weekly_bundle';
  static const String detail = 'detail';
  static const String map = 'map';

  /// The server-driven Discovery feed (PROD-3998). Distinct from [listUi] and
  /// from the legacy Discovery shelves, which have no constant of their own —
  /// so a query can tell a save made from the new feed apart from every other
  /// surface without inferring it.
  static const String discoveryFeed = 'discovery_feed';
}

/// Request model for creating a list
class UserListCreate {
  final String name;
  final String? description;
  final ListVisibility visibility;

  /// AI suggestions prompt for smart lists
  final String? prompt;

  /// Source of the list creation for analytics tracking.
  /// Use [ListSource] constants: 'chat' or 'list_ui'
  final String? source;

  /// PROD-1908 cover recipe overrides. Each field is optional — the BE
  /// fills any field the client doesn't send. FE uses [coverTexture] to
  /// pick a random texture from `kZineTextureCatalog` at creation, so
  /// the BE doesn't need to track the FE-owned catalog. Other fields
  /// stay null and the BE applies its defaults (random colour, etc.).
  final String? coverType;
  final String? coverColor;
  final String? coverTexture;
  final String? coverTextColor;
  final String? coverItemId;

  const UserListCreate({
    required this.name,
    this.description,
    this.visibility = ListVisibility.private,
    this.prompt,
    this.source,
    this.coverType,
    this.coverColor,
    this.coverTexture,
    this.coverTextColor,
    this.coverItemId,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      if (description != null) 'description': description,
      'visibility': visibility.toJson(),
      if (prompt != null) 'prompt': prompt,
      if (source != null) 'source': source,
      if (coverType != null) 'cover_type': coverType,
      if (coverColor != null) 'cover_color': coverColor,
      if (coverTexture != null) 'cover_texture': coverTexture,
      if (coverTextColor != null) 'cover_text_color': coverTextColor,
      if (coverItemId != null) 'cover_item_id': coverItemId,
    };
  }
}

/// Request model for updating a list
class UserListUpdate {
  final String? name;
  final String? description;
  final ListVisibility? visibility;

  /// AI suggestions prompt for smart lists
  final String? prompt;

  /// When true, explicitly sends `"prompt": null` to clear the prompt on the backend.
  /// Needed because a null [prompt] alone is ambiguous ("don't change" vs "clear").
  final bool clearPrompt;

  /// Cover image URL. Set a URL to use as cover.
  final String? coverImageUrl;

  /// When true, sends empty string to clear the cover on the backend.
  final bool clearCover;

  /// PROD-1907 cover recipe fields. Each is a tri-state:
  ///   - field is `null` AND its `clearX` flag is `false` → key omitted from
  ///     PATCH (BE leaves the row's value unchanged)
  ///   - field has a value → key sent with that value
  ///   - `clearX = true` → key sent with `null` (BE clears, FE falls back)
  /// `cover_type` is non-nullable on the row (no `clearCoverType`).
  /// The codegen serialiser gotcha BE flagged on PROD-1907 — unset
  /// nullable fields serialised as `null` — is sidestepped here by
  /// hand-building the JSON map below.
  final String? coverType;
  final String? coverColor;
  final bool clearCoverColor;
  final String? coverTexture;
  final bool clearCoverTexture;
  final String? coverTextColor;
  final bool clearCoverTextColor;
  final String? coverItemId;
  final bool clearCoverItemId;

  const UserListUpdate({
    this.name,
    this.description,
    this.visibility,
    this.prompt,
    this.clearPrompt = false,
    this.coverImageUrl,
    this.clearCover = false,
    this.coverType,
    this.coverColor,
    this.clearCoverColor = false,
    this.coverTexture,
    this.clearCoverTexture = false,
    this.coverTextColor,
    this.clearCoverTextColor = false,
    this.coverItemId,
    this.clearCoverItemId = false,
  });

  Map<String, dynamic> toJson() {
    return {
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (visibility != null) 'visibility': visibility!.toJson(),
      if (prompt != null) 'prompt': prompt else if (clearPrompt) 'prompt': null,
      if (coverImageUrl != null)
        'cover_image_url': coverImageUrl
      else if (clearCover)
        'cover_image_url': '',
      if (coverType != null) 'cover_type': coverType,
      if (coverColor != null)
        'cover_color': coverColor
      else if (clearCoverColor)
        'cover_color': null,
      if (coverTexture != null)
        'cover_texture': coverTexture
      else if (clearCoverTexture)
        'cover_texture': null,
      if (coverTextColor != null)
        'cover_text_color': coverTextColor
      else if (clearCoverTextColor)
        'cover_text_color': null,
      if (coverItemId != null)
        'cover_item_id': coverItemId
      else if (clearCoverItemId)
        'cover_item_id': null,
    };
  }
}

/// Request model for adding an item to a list
class UserListItemCreate {
  final SavedItemType itemType;
  final String? eventId;
  final String? venueId;

  /// PROD-3116 — save a single occurrence of the event instead of the whole
  /// event. Only meaningful for event items with an [eventId]; null saves the
  /// whole event.
  final String? eventOccurrenceId;
  final String? tip;
  // External data for Mode 2 saving (items not in DB)
  final ExternalEventData? eventData;
  final ExternalPlaceData? placeData;

  /// Source of the item addition for analytics tracking.
  /// Use [ListSource] constants: 'chat' or 'list_ui'
  final String? source;

  const UserListItemCreate({
    required this.itemType,
    this.eventId,
    this.venueId,
    this.eventOccurrenceId,
    this.tip,
    this.eventData,
    this.placeData,
    this.source,
  });

  // Mode 1: Add by existing DB ID
  factory UserListItemCreate.event(
    String eventId, {
    String? tip,
    String? eventOccurrenceId,
  }) {
    return UserListItemCreate(
      itemType: SavedItemType.event,
      eventId: eventId,
      eventOccurrenceId: eventOccurrenceId,
      tip: tip,
    );
  }

  factory UserListItemCreate.place(String venueId, {String? tip}) {
    return UserListItemCreate(
      itemType: SavedItemType.place,
      venueId: venueId,
      tip: tip,
    );
  }

  // Mode 2: Add with external data
  factory UserListItemCreate.externalEvent(
    ExternalEventData data, {
    String? tip,
  }) {
    return UserListItemCreate(
      itemType: SavedItemType.event,
      eventData: data,
      tip: tip,
    );
  }

  factory UserListItemCreate.externalPlace(
    ExternalPlaceData data, {
    String? tip,
  }) {
    return UserListItemCreate(
      itemType: SavedItemType.place,
      placeData: data,
      tip: tip,
    );
  }

  /// Create from ItemSuggestion
  /// Backend requires EITHER an ID (for existing DB items) OR external data (for new items).
  /// If the item has a DB ID (eventId/venueId), use that. Otherwise, include the external data.
  /// Async because city resolution may require reverse geocoding.
  static Future<UserListItemCreate> fromItemSuggestion(
    ItemSuggestion place, {
    String? tip,
    String? eventOccurrenceId,
  }) async {
    if (place.type == 'event') {
      // If we have an eventId, the item exists in DB - just reference it
      if (place.eventId != null) {
        return UserListItemCreate(
          itemType: SavedItemType.event,
          eventId: place.eventId,
          // PROD-3116 — occurrence scope only applies to existing DB events;
          // external events create fresh occurrences with new ids.
          eventOccurrenceId: eventOccurrenceId,
          tip: tip,
        );
      }

      // No eventId - this is an external event, include full data for creation
      final eventData = ExternalEventData(
        title: place.name,
        url: place.url ?? '',
        date: place.date,
        description: place.description,
        location: place.location,
        city: place.city,
        category: place.category,
        imageUrl: place.imageUrl,
        latitude: place.latitude,
        longitude: place.longitude,
      );

      return UserListItemCreate(
        itemType: SavedItemType.event,
        eventData: eventData,
        tip: tip,
      );
    } else if (place.type == 'place') {
      // If we have a venueId, the item exists in DB - just reference it
      if (place.venueId != null) {
        return UserListItemCreate(
          itemType: SavedItemType.place,
          venueId: place.venueId,
          tip: tip,
        );
      }

      // No venueId - this is an external place, include full data for creation
      // Resolve city: backend value → reverse geocoding → address parsing → fallback
      final city =
          await CityResolver.resolveCity(
            city: place.city,
            lat: place.latitude,
            lng: place.longitude,
            address: place.address,
          ) ??
          'Unknown';

      final placeData = ExternalPlaceData(
        name: place.name,
        city: city,
        latitude: place.latitude,
        longitude: place.longitude,
        address: place.address,
        rating: place.rating,
        ratingCount: place.ratingCount,
        types: place.types,
        googlePlaceId: place.googlePlaceId,
        googleMapsUrl: place.googleMapsUrl,
        imageUrl: place.imageUrl,
        description: place.description,
      );

      return UserListItemCreate(
        itemType: SavedItemType.place,
        placeData: placeData,
        tip: tip,
      );
    }
    throw ArgumentError(
      'Cannot create UserListItemCreate: missing required data',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'item_type': itemType.toJson(),
      if (eventId != null) 'event_id': eventId,
      if (venueId != null) 'venue_id': venueId,
      if (eventOccurrenceId != null) 'event_occurrence_id': eventOccurrenceId,
      if (tip != null) 'tip': tip,
      if (eventData != null) 'event_data': eventData!.toJson(),
      if (placeData != null) 'place_data': placeData!.toJson(),
      if (source != null) 'source': source,
    };
  }

  /// Create a copy with the specified source
  UserListItemCreate copyWithSource(String? source) {
    return UserListItemCreate(
      itemType: itemType,
      eventId: eventId,
      venueId: venueId,
      eventOccurrenceId: eventOccurrenceId,
      tip: tip,
      eventData: eventData,
      placeData: placeData,
      source: source,
    );
  }
}

/// Request model for updating a list item
class UserListItemUpdate {
  final String? tip;

  /// PROD-2935 — keep THIS item out of the algorithm (social-proof counts,
  /// ranking, recommender inputs). Null = leave unchanged.
  final bool? excludeFromAlgorithm;

  const UserListItemUpdate({this.tip, this.excludeFromAlgorithm});

  Map<String, dynamic> toJson() {
    return {
      if (tip != null) 'tip': tip,
      if (excludeFromAlgorithm != null)
        'exclude_from_algorithm': excludeFromAlgorithm,
    };
  }
}

/// Response model for lists
class UserListsResponse {
  final List<UserList> items;
  final int total;
  final bool hasMore;

  /// Raw `has_more` as the backend sent it — `null` when the field was
  /// absent from the response. PROD-3267: lets pagination consumers
  /// treat an explicit backend `has_more` as authoritative while falling
  /// back to a full-page heuristic (`page.length == pageSize`) when the
  /// backend doesn't send it, instead of depending on `total` (which
  /// `/lists/public` computes via an expensive second query execution
  /// the BE wants to drop — PROD-3242/PROD-3246).
  final bool? hasMoreExplicit;

  const UserListsResponse({
    required this.items,
    required this.total,
    this.hasMore = false,
    this.hasMoreExplicit,
  });

  factory UserListsResponse.fromJson(Map<String, dynamic> json) {
    final items = (json['items'] as List<dynamic>)
        .map((e) => UserList.fromJson(e as Map<String, dynamic>))
        .toList();
    final total = json['total'] as int? ?? 0;
    // `has_more` is authoritative when the backend sends it (e.g. the
    // discover endpoint). When absent (e.g. `listMyLists`, which only
    // returns `{items, total}`), callers must compute cumulative
    // `loaded.length < total` themselves — we can't do it here because
    // `fromJson` only sees one page. Default to `false` so a missing
    // `has_more` never causes a spurious "Ver mais" / infinite-scroll
    // trigger. PROD-1430 (PR #228) was fixed this way after an earlier
    // `items.length < total` fallback incorrectly showed more-available
    // on every single page. [hasMoreExplicit] preserves the raw
    // tri-state for consumers that need "absent" ≠ "false" (PROD-3267).
    final hasMoreRaw = json['has_more'] as bool?;
    return UserListsResponse(
      items: items,
      total: total,
      hasMore: hasMoreRaw ?? false,
      hasMoreExplicit: hasMoreRaw,
    );
  }
}

/// Response model for /lists/discover (all 4 sections)
class DiscoverListsResponse {
  final UserListsResponse yourLists;
  final UserListsResponse curated;
  final UserListsResponse following;
  final UserListsResponse recommended;

  const DiscoverListsResponse({
    required this.yourLists,
    required this.curated,
    required this.following,
    required this.recommended,
  });

  factory DiscoverListsResponse.fromJson(Map<String, dynamic> json) {
    return DiscoverListsResponse(
      yourLists: UserListsResponse.fromJson(
        json['your_lists'] as Map<String, dynamic>? ??
            {'items': [], 'total': 0},
      ),
      curated: UserListsResponse.fromJson(
        json['curated'] as Map<String, dynamic>? ?? {'items': [], 'total': 0},
      ),
      following: UserListsResponse.fromJson(
        json['following'] as Map<String, dynamic>? ?? {'items': [], 'total': 0},
      ),
      recommended: UserListsResponse.fromJson(
        json['recommended'] as Map<String, dynamic>? ??
            {'items': [], 'total': 0},
      ),
    );
  }
}

/// Response model for list items
class UserListItemsResponse {
  final List<UserListItem> items;
  final int total;

  const UserListItemsResponse({required this.items, required this.total});

  factory UserListItemsResponse.fromJson(Map<String, dynamic> json) {
    return UserListItemsResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => UserListItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
    );
  }
}

// ============================================================================
// Public List Models (for unauthenticated access)
// ============================================================================

/// Owner info for public lists (limited data for privacy)
class PublicListOwner {
  final String id;
  final String? fullName;
  final String? handle;

  /// Manually-assigned Expert tag (backend PROD-3336). Drives the Expert badge
  /// next to the owner's name on list-owner attribution.
  final bool isExpert;

  const PublicListOwner({
    required this.id,
    this.fullName,
    this.handle,
    this.isExpert = false,
  });

  factory PublicListOwner.fromJson(Map<String, dynamic> json) {
    return PublicListOwner(
      id: json['id'] as String,
      fullName: json['full_name'] as String?,
      handle: json['handle'] as String?,
      isExpert: json['is_expert'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      if (fullName != null) 'full_name': fullName,
      if (handle != null) 'handle': handle,
      if (isExpert) 'is_expert': isExpert,
    };
  }

  /// Display name (full name or handle or "Unknown")
  String get displayName => fullName ?? handle ?? 'Unknown';
}

/// Public list model for unauthenticated access
///
/// This is similar to [UserList] but:
/// - Only includes owner's public info (id, full_name, handle)
/// - Does not include owner_id, is_collaborative, is_default, member_count
class PublicList {
  final String id;
  final String name;
  final String? slug;
  final String? description;
  final ListVisibility visibility;
  final PublicListOwner owner;
  final int itemCount;
  final int followerCount;
  final List<String>? previewImages;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? systemKind;
  final bool editorPick;
  final bool cityGuide;
  final bool verified;
  final Set<String> knownContextFields;

  /// PROD-1907 cover recipe (see UserList for the long-form description).
  final String? coverImageUrl;
  final String? coverType;
  final String? coverColor;
  final String? coverTexture;
  final String? coverTextColor;
  final String? coverItemId;

  /// PROD-1932 — server-resolved image URL for `cover_item_id`. See
  /// [UserList.coverItemImageUrl].
  final String? coverItemImageUrl;

  /// PROD-2297 — per-list curator cover toggles. See
  /// [UserList.coverShowTitle] for semantics. Default `true` keeps older
  /// API responses rendering chrome.
  final bool coverShowTitle;
  final bool coverShowTexture;
  final bool coverShowLogo;

  const PublicList({
    required this.id,
    required this.name,
    this.slug,
    this.description,
    required this.visibility,
    required this.owner,
    required this.itemCount,
    required this.followerCount,
    this.previewImages,
    required this.createdAt,
    required this.updatedAt,
    this.systemKind,
    this.editorPick = false,
    this.cityGuide = false,
    this.verified = false,
    this.knownContextFields = const {'visibility'},
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

  factory PublicList.fromJson(Map<String, dynamic> json) {
    return PublicList(
      knownContextFields: _knownListContextFields(json),
      systemKind: json['system_kind'] as String?,
      editorPick: json['editor_pick'] as bool? ?? false,
      cityGuide: json['city_guide'] as bool? ?? false,
      verified: json['verified'] as bool? ?? false,
      id: json['id'] as String,
      name: json['name'] as String,
      slug: json['slug'] as String?,
      description: json['description'] as String?,
      visibility: ListVisibility.fromJson(
        json['visibility'] as String? ?? 'public',
      ),
      owner: PublicListOwner.fromJson(json['owner'] as Map<String, dynamic>),
      itemCount: json['item_count'] as int? ?? 0,
      followerCount: json['follower_count'] as int? ?? 0,
      previewImages: (json['preview_images'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
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

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (slug != null) 'slug': slug,
      if (description != null) 'description': description,
      if (knownContextFields.contains('visibility'))
        'visibility': visibility.toJson(),
      if (systemKind != null || knownContextFields.contains('system_kind'))
        'system_kind': systemKind,
      if (editorPick || knownContextFields.contains('editor_pick'))
        'editor_pick': editorPick,
      if (cityGuide || knownContextFields.contains('city_guide'))
        'city_guide': cityGuide,
      if (verified || knownContextFields.contains('verified'))
        'verified': verified,
      'owner': owner.toJson(),
      'item_count': itemCount,
      'follower_count': followerCount,
      if (previewImages != null) 'preview_images': previewImages,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      if (coverImageUrl != null) 'cover_image_url': coverImageUrl,
      if (coverType != null) 'cover_type': coverType,
      if (coverColor != null) 'cover_color': coverColor,
      if (coverTexture != null) 'cover_texture': coverTexture,
      if (coverTextColor != null) 'cover_text_color': coverTextColor,
      if (coverItemId != null) 'cover_item_id': coverItemId,
      if (coverItemImageUrl != null) 'cover_item_image_url': coverItemImageUrl,
      'cover_show_title': coverShowTitle,
      'cover_show_texture': coverShowTexture,
      'cover_show_logo': coverShowLogo,
    };
  }
}

/// Response model for public list items
class PublicListItemsResponse {
  final List<UserListItem> items;
  final int total;

  const PublicListItemsResponse({required this.items, required this.total});

  factory PublicListItemsResponse.fromJson(Map<String, dynamic> json) {
    return PublicListItemsResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => UserListItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
    );
  }
}

// ============================================================================
// Suggested List Models (personalized recommendations)
// ============================================================================

/// Suggested list model with relevance metadata
///
/// Extends [UserList] with additional fields for personalization:
/// - [relevanceScore]: Composite score (0-1) based on location and interest matching
/// - [locationMatch]: True if list has items in user's city
/// - [interestMatchCount]: Number of interest tags matched
class SuggestedList extends UserList {
  final double relevanceScore;
  final bool locationMatch;
  final int interestMatchCount;

  /// Distance in km from the user's location to the nearest item in this list.
  /// Returned by the backend; max 100km (lists beyond 100km are excluded).
  final double? minDistanceKm;

  const SuggestedList({
    required super.id,
    required super.ownerId,
    required super.name,
    super.description,
    required super.visibility,
    required super.isCollaborative,
    required super.isDefault,
    required super.createdAt,
    required super.updatedAt,
    required super.itemCount,
    required super.memberCount,
    required super.followerCount,
    super.userRole,
    super.isFollowing,
    super.prompt,
    super.ownerName,
    super.ownerHandle,
    super.ownerAvatarUrl,
    super.ownerIsExpert,
    super.coverImageUrl,
    super.coverType,
    super.coverColor,
    super.coverTexture,
    super.coverTextColor,
    super.coverItemId,
    super.coverItemImageUrl,
    super.coverShowTitle,
    super.coverShowTexture,
    super.coverShowLogo,
    super.previewImages,
    super.editorPick,
    super.cityGuide,
    super.verified,
    super.systemKind,
    super.knownContextFields,
    required this.relevanceScore,
    required this.locationMatch,
    required this.interestMatchCount,
    this.minDistanceKm,
  });

  factory SuggestedList.fromJson(Map<String, dynamic> json) {
    // Parse owner name from nested owner object
    final owner = json['owner'] as Map<String, dynamic>?;

    return SuggestedList(
      knownContextFields: _knownListContextFields(json),
      systemKind: json['system_kind'] as String?,
      id: json['id'] as String,
      ownerId: json['owner_id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      visibility: ListVisibility.fromJson(
        json['visibility'] as String? ?? 'private',
      ),
      isCollaborative: json['is_collaborative'] as bool? ?? false,
      isDefault: json['is_default'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      itemCount: json['item_count'] as int? ?? 0,
      memberCount: json['member_count'] as int? ?? 0,
      followerCount: json['follower_count'] as int? ?? 0,
      userRole: json['user_role'] as String?,
      isFollowing: json['is_following'] as bool?,
      prompt: json['prompt'] as String?,
      ownerName: owner?['full_name'] as String?,
      ownerHandle: owner?['handle'] as String?,
      ownerAvatarUrl: owner?['avatar_url'] as String?,
      ownerIsExpert: owner?['is_expert'] as bool? ?? false,
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
      previewImages: (json['preview_images'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      editorPick: json['editor_pick'] as bool? ?? false,
      cityGuide: json['city_guide'] as bool? ?? false,
      verified: json['verified'] as bool? ?? false,
      relevanceScore: (json['relevance_score'] as num?)?.toDouble() ?? 0.0,
      locationMatch: json['location_match'] as bool? ?? false,
      interestMatchCount: json['interest_match_count'] as int? ?? 0,
      minDistanceKm: (json['min_distance_km'] as num?)?.toDouble(),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final base = super.toJson();
    return {
      ...base,
      'relevance_score': relevanceScore,
      'location_match': locationMatch,
      'interest_match_count': interestMatchCount,
      'min_distance_km': minDistanceKm,
    };
  }
}

/// Response model for suggested lists
class SuggestedListsResponse {
  final List<SuggestedList> items;
  final int total;

  const SuggestedListsResponse({required this.items, required this.total});

  factory SuggestedListsResponse.fromJson(Map<String, dynamic> json) {
    return SuggestedListsResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => SuggestedList.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
    );
  }
}

// ============================================================================
// Optimistic Item Model (for pending saves before API confirmation)
// ============================================================================

/// An optimistic list item pending backend confirmation.
///
/// This is used to display items immediately after the user saves them,
/// before the backend API call completes. Once confirmed, the item is
/// removed from pending and the real item from the backend is displayed.
class OptimisticListItem {
  /// Unique ID for tracking this optimistic item
  final String tempId;

  /// The list this item is being added to
  final String listId;

  /// The place data being saved
  final ItemSuggestion place;

  /// Optional user tip/note
  final String? tip;

  /// When the optimistic save was initiated
  final DateTime addedAt;

  const OptimisticListItem({
    required this.tempId,
    required this.listId,
    required this.place,
    this.tip,
    required this.addedAt,
  });

  /// Generate a new optimistic item with a unique ID
  factory OptimisticListItem.create({
    required String listId,
    required ItemSuggestion place,
    String? tip,
  }) {
    return OptimisticListItem(
      tempId: const Uuid().v4(),
      listId: listId,
      place: place,
      tip: tip,
      addedAt: DateTime.now(),
    );
  }

  /// Convert to a UserListItem for display purposes.
  ///
  /// This creates a display-ready item from the optimistic data,
  /// allowing it to be shown alongside real items from the backend.
  UserListItem toUserListItem(String userId) {
    final isEvent = place.type == 'event';

    return UserListItem(
      id: tempId,
      listId: listId,
      addedById: userId,
      itemType: isEvent ? SavedItemType.event : SavedItemType.place,
      eventId: place.eventId,
      venueId: place.venueId,
      tip: tip,
      addedAt: addedAt,
      event: isEvent ? _buildEventMap() : null,
      venue: !isEvent ? _buildVenueMap() : null,
      // PROD-3829: carry the facet through the OPTIMISTIC path too. Without
      // it, saving an item shows the generic pink pin in local list state and
      // only snaps to the category art after a refetch — a visible flicker
      // once the backend starts sending the field. Same class of silent drop
      // as the `copyWith` hole above.
      primaryFacet: place.primaryFacet,
    );
  }

  /// Build event map from ItemSuggestion for display
  Map<String, dynamic> _buildEventMap() {
    return {
      'title': place.name,
      'image_url': place.imageUrl,
      'category': place.category,
      'start_datetime': place.date,
      'latitude': place.latitude,
      'longitude': place.longitude,
      'venue_address': place.address,
      'venue_city': place.city,
      'venue_name': place.location,
      'url': place.url,
      'description': place.description,
    };
  }

  /// Build venue map from ItemSuggestion for display
  Map<String, dynamic> _buildVenueMap() {
    return {
      'name': place.name,
      'image_url': place.imageUrl,
      'tags': place.tags,
      'latitude': place.latitude,
      'longitude': place.longitude,
      'address': place.address,
      'city': place.city,
      'rating': place.rating,
      'rating_count': place.ratingCount,
      'google_place_id': place.googlePlaceId,
      'google_maps_url': place.googleMapsUrl,
      'description': place.description,
    };
  }

  OptimisticListItem copyWith({
    String? tempId,
    String? listId,
    ItemSuggestion? place,
    String? tip,
    DateTime? addedAt,
  }) {
    return OptimisticListItem(
      tempId: tempId ?? this.tempId,
      listId: listId ?? this.listId,
      place: place ?? this.place,
      tip: tip ?? this.tip,
      addedAt: addedAt ?? this.addedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'temp_id': tempId,
      'list_id': listId,
      'place': place.toJson(),
      if (tip != null) 'tip': tip,
      'added_at': addedAt.toIso8601String(),
    };
  }

  factory OptimisticListItem.fromJson(Map<String, dynamic> json) {
    return OptimisticListItem(
      tempId: json['temp_id'] as String,
      listId: json['list_id'] as String,
      place: ItemSuggestion.fromJson(json['place'] as Map<String, dynamic>),
      tip: json['tip'] as String?,
      addedAt: DateTime.parse(json['added_at'] as String),
    );
  }
}

/// Result of `POST /api/v1/app/lists/{list_id}/items/bulk-delete` (PROD-1722).
class BulkDeleteItemsResponse {
  final List<String> deleted;
  final List<BulkDeleteSkippedItem> skipped;

  /// Every list that lost a row from the cascade, including the target list
  /// (PROD-3873). The owner's unsave removes the entity from every list they
  /// hold it in; these ids are the invalidation input. Empty for a
  /// collaborator (they only ever get the single-row removal).
  final List<String> cascadedListIds;

  const BulkDeleteItemsResponse({
    required this.deleted,
    required this.skipped,
    this.cascadedListIds = const [],
  });

  factory BulkDeleteItemsResponse.fromJson(Map<String, dynamic> json) {
    return BulkDeleteItemsResponse(
      deleted: (json['deleted'] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList(),
      skipped: (json['skipped'] as List<dynamic>? ?? const [])
          .map((e) => BulkDeleteSkippedItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      cascadedListIds: (json['cascaded_list_ids'] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList(),
    );
  }
}

class BulkDeleteSkippedItem {
  final String itemId;

  /// `not_found` (already deleted / wrong list) or `forbidden`
  /// (collaborator who didn't add the item).
  final String reason;

  const BulkDeleteSkippedItem({required this.itemId, required this.reason});

  factory BulkDeleteSkippedItem.fromJson(Map<String, dynamic> json) {
    return BulkDeleteSkippedItem(
      itemId: json['item_id'] as String,
      reason: json['reason'] as String,
    );
  }
}

/// One upcoming occurrence of an event embedded in a [UserListItem].
/// Mirrors the OpenAPI `ListItemEventOccurrence` schema: per-occurrence
/// venue resolution (different occurrences of the same event can sit at
/// different venues — e.g. a touring show or a multi-room festival).
class ListItemEventOccurrence {
  final DateTime startAt;
  final DateTime? endAt;
  final String? venueId;
  final String? venueName;
  final String? venueAddress;
  final String? venueCity;

  const ListItemEventOccurrence({
    required this.startAt,
    this.endAt,
    this.venueId,
    this.venueName,
    this.venueAddress,
    this.venueCity,
  });

  factory ListItemEventOccurrence.fromJson(Map<String, dynamic> json) {
    return ListItemEventOccurrence(
      startAt: parseBackendDateTimeRequired(json['start_at'] as String),
      endAt: parseBackendDateTime(json['end_at'] as String?),
      venueId: json['venue_id'] as String?,
      venueName: json['venue_name'] as String?,
      venueAddress: json['venue_address'] as String?,
      venueCity: json['venue_city'] as String?,
    );
  }
}
