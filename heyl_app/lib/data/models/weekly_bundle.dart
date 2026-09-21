/// Weekly Bundle recommendation model.
///
/// Represents a personalized weekly bundle with journal page images,
/// matching the WeeklyBundleResponse from the backend API.
class WeeklyBundle {
  final bool hasBundle;
  final String? batchId;
  final String? weekStart;
  final String? weekEnd;
  final String? status;
  final List<String> pageImageUrls;
  final List<WeeklyBundleItem> items;
  final String? generatedAt;

  /// UUID of the auto-managed "This Week" system list
  /// (`system_kind = weekly_bundle`) that mirrors the bundle's items.
  /// Stable across weeks; populated by the backend once the bundle has
  /// been materialized. PROD-1953 — gates the "View as Zine" button in
  /// [WeeklyBundleOverlay]; when null the overlay stays in flipbook mode
  /// only (forward-compat with pre-materialization responses).
  final String? listId;

  const WeeklyBundle({
    required this.hasBundle,
    this.batchId,
    this.weekStart,
    this.weekEnd,
    this.status,
    this.pageImageUrls = const [],
    this.items = const [],
    this.generatedAt,
    this.listId,
  });

  factory WeeklyBundle.empty() => const WeeklyBundle(hasBundle: false);

  factory WeeklyBundle.fromJson(Map<String, dynamic> json) {
    final itemsList =
        (json['items'] as List<dynamic>?)
            ?.map((e) => WeeklyBundleItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    final pageUrls =
        (json['page_image_urls'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList() ??
        [];

    return WeeklyBundle(
      hasBundle: json['has_bundle'] as bool? ?? false,
      batchId: json['batch_id'] as String?,
      weekStart: json['week_start'] as String?,
      weekEnd: json['week_end'] as String?,
      status: json['status'] as String?,
      pageImageUrls: pageUrls,
      items: itemsList,
      generatedAt: json['generated_at'] as String?,
      listId: json['list_id'] as String?,
    );
  }

  bool get isReady => hasBundle && status == 'ready';
  bool get hasPages => pageImageUrls.isNotEmpty;
  int get pageCount => pageImageUrls.length;
  int get itemCount => items.length;

  /// PROD-2036 — `true` when the BE reports the resolved city is outside
  /// the supported launch markets. FE renders the explanatory CTA.
  bool get isUnsupportedCity => status == 'unsupported_city';
}

class WeeklyBundleItem {
  final String? recommendationId;
  final String? title;
  final String? category;
  final String? reason;
  final String? itemType;
  final String? imageUrl;
  final String? address;
  final String? city;
  final double? latitude;
  final double? longitude;
  final String? eventId;
  final String? venueId;
  final String? googlePlaceId;
  final String? externalUrl;
  final String? date;
  final String? startAt;
  final String? userAction;

  const WeeklyBundleItem({
    this.recommendationId,
    this.title,
    this.category,
    this.reason,
    this.itemType,
    this.imageUrl,
    this.address,
    this.city,
    this.latitude,
    this.longitude,
    this.eventId,
    this.venueId,
    this.googlePlaceId,
    this.externalUrl,
    this.date,
    this.startAt,
    this.userAction,
  });

  factory WeeklyBundleItem.fromJson(Map<String, dynamic> json) {
    return WeeklyBundleItem(
      recommendationId: json['recommendation_id'] as String?,
      title: json['title'] as String?,
      category: json['category'] as String?,
      reason: json['reason'] as String?,
      itemType: json['item_type'] as String?,
      imageUrl: json['image_url'] as String?,
      address: json['address'] as String?,
      city: json['city'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      eventId: json['event_id'] as String?,
      venueId: json['venue_id'] as String?,
      googlePlaceId: json['google_place_id'] as String?,
      externalUrl: json['external_url'] as String?,
      date: json['date'] as String?,
      startAt: json['start_at'] as String?,
      userAction: json['user_action'] as String?,
    );
  }

  WeeklyBundleItem copyWith({String? userAction}) {
    return WeeklyBundleItem(
      recommendationId: recommendationId,
      title: title,
      category: category,
      reason: reason,
      itemType: itemType,
      imageUrl: imageUrl,
      address: address,
      city: city,
      latitude: latitude,
      longitude: longitude,
      eventId: eventId,
      venueId: venueId,
      googlePlaceId: googlePlaceId,
      externalUrl: externalUrl,
      date: date,
      startAt: startAt,
      userAction: userAction ?? this.userAction,
    );
  }
}
