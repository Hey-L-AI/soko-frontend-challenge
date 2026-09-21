/// One source-backed memory fact as surfaced to the user-facing memory page.
///
/// Mirrors `MemoryFactView` in `open-api/heyl-webapp-v1.openapi.yaml`.
class MemoryFactView {
  final String id;
  final String category;
  final String content;
  final String source;
  final String signalStrength;
  final String persistence;
  final String? sourceSessionId;
  final DateTime validFrom;
  final DateTime? lastSeenAt;

  /// Entity reference for action-sourced facts (saved venue/event, followed
  /// list). Null for chat/onboarding facts. For `list_followed` facts,
  /// `entityType` is null but `entityId` still carries the `list_id`.
  final String? entityId;
  final String? entityType;

  /// Hydrated display fields populated by the backend for action-sourced
  /// facts only. `entityImageUrl` is a single resolved URL (first venue
  /// image, event main poster, or list cover). `entitySubtitle` is a short
  /// label like the first venue type, event category, or zine visibility.
  /// Both are null when the entity could not be resolved or has no image
  /// of its own — the webapp falls back to the seed-coloured block.
  final String? entityImageUrl;
  final String? entitySubtitle;

  /// Names of the user's own zines (created/owned lists) that contain this
  /// venue/event. Used to caption the entity card with "From your zine «…»".
  /// Empty when the entity isn't in any of the user's zines.
  final List<String> inZines;

  /// PROD-2799 #5-img: the referenced zine's cover recipe (list entities only),
  /// so the card renders the real cover — a solid colour + texture, or the
  /// uploaded photo — instead of a generic block. Null for non-list entities
  /// and legacy payloads.
  final EntityCoverView? entityCover;

  const MemoryFactView({
    required this.id,
    required this.category,
    required this.content,
    required this.source,
    required this.signalStrength,
    required this.persistence,
    required this.validFrom,
    this.sourceSessionId,
    this.lastSeenAt,
    this.entityId,
    this.entityType,
    this.entityImageUrl,
    this.entitySubtitle,
    this.inZines = const [],
    this.entityCover,
  });

  bool get isUserStated => source == 'user_stated';

  // TODO: required-string casts retained pending the Phase 3 `requireString`
  // helper (see docs/platform/error-handling-discipline.md). Drop the
  // `gstack:allow` markers once it lands.
  factory MemoryFactView.fromJson(Map<String, dynamic> json) {
    final id =
        json['id']
            as String; // gstack:allow check-error-handling json-cast-string
    final category =
        json['category']
            as String; // gstack:allow check-error-handling json-cast-string
    final content =
        json['content']
            as String; // gstack:allow check-error-handling json-cast-string
    final source =
        json['source']
            as String; // gstack:allow check-error-handling json-cast-string
    final signalStrength =
        json['signal_strength']
            as String; // gstack:allow check-error-handling json-cast-string
    final persistence =
        json['persistence']
            as String; // gstack:allow check-error-handling json-cast-string
    final validFromRaw =
        json['valid_from']
            as String; // gstack:allow check-error-handling json-cast-string
    final lastSeenAtRaw = json['last_seen_at'] as String?;
    return MemoryFactView(
      id: id,
      category: category,
      content: content,
      source: source,
      signalStrength: signalStrength,
      persistence: persistence,
      sourceSessionId: json['source_session_id'] as String?,
      validFrom: DateTime.parse(validFromRaw),
      lastSeenAt: lastSeenAtRaw == null ? null : DateTime.parse(lastSeenAtRaw),
      entityId: json['entity_id'] as String?,
      entityType: json['entity_type'] as String?,
      entityImageUrl: json['entity_image_url'] as String?,
      entitySubtitle: json['entity_subtitle'] as String?,
      inZines:
          (json['in_zines'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList(growable: false) ??
          const [],
      entityCover: json['entity_cover'] == null
          ? null
          : EntityCoverView.fromJson(
              json['entity_cover'] as Map<String, dynamic>,
            ),
    );
  }
}

/// PROD-2799 #5-img: a zine's cover recipe (mirrors the backend `EntityCoverView`
/// and the `user_lists` cover columns), so the memory entity card renders the
/// real cover via `ZineCoverRecipe.fromFields` instead of a generic block.
class EntityCoverView {
  final String type; // background_color | item_image | uploaded_photo
  final String? color;
  final String? texture;
  final String? textColor;
  final String? imageUrl;

  const EntityCoverView({
    required this.type,
    this.color,
    this.texture,
    this.textColor,
    this.imageUrl,
  });

  factory EntityCoverView.fromJson(Map<String, dynamic> json) {
    return EntityCoverView(
      type:
          json['type']
              as String, // gstack:allow check-error-handling json-cast-string
      color: json['color'] as String?,
      texture: json['texture'] as String?,
      textColor: json['text_color'] as String?,
      imageUrl: json['image_url'] as String?,
    );
  }
}
