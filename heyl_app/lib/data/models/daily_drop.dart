/// Daily Drop recommendation model.
///
/// Represents a personalized daily suggestion with poster, matching the
/// DailyRecommendationResponse from the backend API.
class DailyDrop {
  final bool hasRecommendation;

  /// Top-level status from the response (PROD-2036). `null` for the
  /// regular success path; `"unsupported_city"` when the resolved city is
  /// outside the supported launch markets.
  final String? status;
  final String? recommendationId;
  final String? title;
  final String? description;
  final String? reason;
  final String? category;
  final String? itemType;
  final String? address;
  final String? city;
  final String? date;
  final String? startAt;
  final double? latitude;
  final double? longitude;
  final String? imageUrl;
  final String? coverImageUrl;
  final String? posterImageUrl;
  final String? posterStatus;
  final String? generatedAt;
  final String? batchId;
  final String? eventId;
  final String? venueId;
  final String? googlePlaceId;
  final String? externalUrl;
  final List<String> tags;

  const DailyDrop({
    required this.hasRecommendation,
    this.status,
    this.recommendationId,
    this.title,
    this.description,
    this.reason,
    this.category,
    this.itemType,
    this.address,
    this.city,
    this.date,
    this.startAt,
    this.latitude,
    this.longitude,
    this.imageUrl,
    this.coverImageUrl,
    this.posterImageUrl,
    this.posterStatus,
    this.generatedAt,
    this.batchId,
    this.eventId,
    this.venueId,
    this.googlePlaceId,
    this.externalUrl,
    this.tags = const [],
  });

  factory DailyDrop.empty() => const DailyDrop(hasRecommendation: false);

  factory DailyDrop.fromJson(Map<String, dynamic> json) {
    final rec = json['recommendation'] as Map<String, dynamic>?;
    final item = rec?['item'] as Map<String, dynamic>?;

    return DailyDrop(
      hasRecommendation: json['has_recommendation'] as bool? ?? false,
      status: json['status'] as String?,
      recommendationId: json['recommendation_id'] as String?,
      title: item?['title'] as String?,
      description: item?['description'] as String?,
      reason: rec?['reason'] as String?,
      category: item?['category'] as String?,
      itemType: item?['item_type'] as String?,
      address: item?['address'] as String?,
      city: item?['city'] as String?,
      date: item?['date'] as String?,
      startAt: item?['start_at'] as String?,
      latitude: (item?['latitude'] as num?)?.toDouble(),
      longitude: (item?['longitude'] as num?)?.toDouble(),
      imageUrl: json['image_url'] as String? ?? item?['image_url'] as String?,
      coverImageUrl:
          json['cover_image_url'] as String? ??
          rec?['cover_image_url'] as String?,
      posterImageUrl: json['poster_image_url'] as String?,
      posterStatus: json['poster_status'] as String?,
      generatedAt: json['generated_at'] as String?,
      batchId: json['batch_id'] as String?,
      eventId: item?['event_id'] as String?,
      venueId: item?['venue_id'] as String?,
      googlePlaceId: item?['google_place_id'] as String?,
      externalUrl: item?['external_url'] as String?,
      tags:
          (rec?['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ??
          (item?['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ??
          [],
    );
  }

  /// Whether the poster is fully generated and ready to display.
  bool get isPosterReady => posterStatus == 'ready' && posterImageUrl != null;

  /// Whether both recommendation and poster are available.
  bool get isFullyReady => hasRecommendation && isPosterReady;

  /// PROD-2036 — `true` when the BE reports the resolved city is outside
  /// the supported launch markets. FE renders the explanatory CTA.
  bool get isUnsupportedCity => status == 'unsupported_city';

  /// PROD-1988 — `true` when the BE reports the user is in the new-user
  /// profiling window (< 3 days since signup AND profiling not completed).
  /// FE renders the profiling CTA card and must NOT call POST `/daily/request`
  /// (the BE would refuse to enqueue with the same status).
  bool get isCtaProfiling => status == 'cta_profiling';

  /// PROD-3730 — `true` when the BE reports a generation task is already in
  /// flight for today (the Redis pending marker set by a prior
  /// POST `/daily/request` is still live; TTL 10 min).
  ///
  /// Honouring this on the GET is what stops the FE re-enqueueing: the POST
  /// handler does NOT check the marker and the Celery task has no singleton
  /// lock, so a second `POST /daily/request` during an in-flight generation
  /// starts a **second full LLM pipeline run**. Poll instead.
  bool get isGenerating => status == 'generating';

  /// Display-friendly venue/location string.
  String? get displayVenue => address ?? city;

  /// Display-friendly time string extracted from startAt.
  String? get displayTime {
    if (startAt == null) return null;
    try {
      final dt = DateTime.parse(startAt!);
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return null;
    }
  }

  DailyDrop copyWith({
    bool? hasRecommendation,
    String? status,
    String? recommendationId,
    String? title,
    String? description,
    String? reason,
    String? category,
    String? itemType,
    String? address,
    String? city,
    String? date,
    String? startAt,
    double? latitude,
    double? longitude,
    String? imageUrl,
    String? coverImageUrl,
    String? posterImageUrl,
    String? posterStatus,
    String? generatedAt,
    String? batchId,
    String? eventId,
    String? venueId,
    String? googlePlaceId,
    String? externalUrl,
    List<String>? tags,
  }) {
    return DailyDrop(
      hasRecommendation: hasRecommendation ?? this.hasRecommendation,
      status: status ?? this.status,
      recommendationId: recommendationId ?? this.recommendationId,
      title: title ?? this.title,
      description: description ?? this.description,
      reason: reason ?? this.reason,
      category: category ?? this.category,
      itemType: itemType ?? this.itemType,
      address: address ?? this.address,
      city: city ?? this.city,
      date: date ?? this.date,
      startAt: startAt ?? this.startAt,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      imageUrl: imageUrl ?? this.imageUrl,
      coverImageUrl: coverImageUrl ?? this.coverImageUrl,
      posterImageUrl: posterImageUrl ?? this.posterImageUrl,
      posterStatus: posterStatus ?? this.posterStatus,
      generatedAt: generatedAt ?? this.generatedAt,
      batchId: batchId ?? this.batchId,
      eventId: eventId ?? this.eventId,
      venueId: venueId ?? this.venueId,
      googlePlaceId: googlePlaceId ?? this.googlePlaceId,
      externalUrl: externalUrl ?? this.externalUrl,
      tags: tags ?? this.tags,
    );
  }
}
