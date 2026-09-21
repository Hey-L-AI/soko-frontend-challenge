/// Reusable lightweight reference to a hydratable entity (venue / event /
/// list). Mirrors the OpenAPI `EntityRef` schema. Currently powers the
/// Discovery Page History grid (PROD-1521); intended to be reused by future
/// surfaces (notifications, recent searches, share cards).
enum EntityKind { venue, event, list, unknown }

EntityKind _kindFromJson(String? raw) {
  switch (raw) {
    case 'venue':
      return EntityKind.venue;
    case 'event':
      return EntityKind.event;
    case 'list':
      return EntityKind.list;
    default:
      return EntityKind.unknown;
  }
}

class EntityRef {
  final EntityKind type;
  final String id;
  final String title;
  final String? imageUrl;
  final DateTime lastActivityAt;

  /// Normalized activity verb (created / saved / followed / shared / visited).
  /// Null on non-activity surfaces (e.g. the history grid).
  final String? verb;

  /// Full zine-cover recipe for `type=list` refs; null for venues/events.
  final ZineCoverRef? cover;

  const EntityRef({
    required this.type,
    required this.id,
    required this.title,
    required this.lastActivityAt,
    this.imageUrl,
    this.verb,
    this.cover,
  });

  factory EntityRef.fromJson(Map<String, dynamic> json) {
    final rawCover = json['cover'];
    return EntityRef(
      type: _kindFromJson(json['type'] as String?),
      id: json['id'] as String,
      title: json['title'] as String,
      imageUrl: json['image_url'] as String?,
      lastActivityAt: DateTime.parse(json['last_activity_at'] as String),
      verb: json['verb'] as String?,
      cover: rawCover is Map<String, dynamic>
          ? ZineCoverRef.fromJson(rawCover)
          : null,
    );
  }
}

/// The zine-cover recipe echoed on `type=list` refs so activity feeds can
/// render the real cover (title + logo on the styled cover) instead of a
/// generic thumbnail. Mirrors the OpenAPI `ZineCoverRef` schema; the fields
/// feed straight into `ZineCoverRecipe.fromFields` (PROD-2863).
class ZineCoverRef {
  final String coverType;
  final String? coverColor;
  final String? coverTexture;
  final String? coverTextColor;
  final String? coverItemId;
  final String? coverItemImageUrl;
  final String? coverImageUrl;
  final bool coverShowTitle;
  final bool coverShowTexture;
  final bool coverShowLogo;

  const ZineCoverRef({
    required this.coverType,
    this.coverColor,
    this.coverTexture,
    this.coverTextColor,
    this.coverItemId,
    this.coverItemImageUrl,
    this.coverImageUrl,
    this.coverShowTitle = true,
    this.coverShowTexture = true,
    this.coverShowLogo = true,
  });

  factory ZineCoverRef.fromJson(Map<String, dynamic> json) {
    return ZineCoverRef(
      coverType: json['cover_type'] as String? ?? 'background_color',
      coverColor: json['cover_color'] as String?,
      coverTexture: json['cover_texture'] as String?,
      coverTextColor: json['cover_text_color'] as String?,
      coverItemId: json['cover_item_id'] as String?,
      coverItemImageUrl: json['cover_item_image_url'] as String?,
      coverImageUrl: json['cover_image_url'] as String?,
      coverShowTitle: json['cover_show_title'] as bool? ?? true,
      coverShowTexture: json['cover_show_texture'] as bool? ?? true,
      coverShowLogo: json['cover_show_logo'] as bool? ?? true,
    );
  }
}

/// Response wrapper for `GET /api/v1/app/users/me/activity`.
class ActivityListResponse {
  final List<EntityRef> items;

  const ActivityListResponse({required this.items});

  factory ActivityListResponse.fromJson(Map<String, dynamic> json) {
    final raw = (json['items'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    return ActivityListResponse(items: raw.map(EntityRef.fromJson).toList());
  }
}
