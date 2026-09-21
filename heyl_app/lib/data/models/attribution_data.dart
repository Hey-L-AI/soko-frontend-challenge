/// Attribution data for tracking marketing campaigns and user acquisition
class AttributionData {
  final String visitorId;
  final String platform; // 'webapp', 'ios', 'android'
  final String? utmSource;
  final String? utmMedium;
  final String? utmCampaign;
  final String? utmContent;
  final String? utmTerm;
  final String? referralSlug;
  final String? referralClickId;
  final String? landingUrl;
  final String? referrerUrl;

  /// Full Play install referrer string, Meta's encrypted blob intact
  /// (PROD-3478 → backend PROD-3480 decrypts it into ad-level acq_* props).
  final String? installReferrerRaw;

  /// PostHog distinct_id at touchpoint time so server-derived person
  /// properties attach to the correct (possibly anonymous) person.
  final String? posthogDistinctId;

  const AttributionData({
    required this.visitorId,
    required this.platform,
    this.utmSource,
    this.utmMedium,
    this.utmCampaign,
    this.utmContent,
    this.utmTerm,
    this.referralSlug,
    this.referralClickId,
    this.landingUrl,
    this.referrerUrl,
    this.installReferrerRaw,
    this.posthogDistinctId,
  });

  /// Whether this attribution data has any marketing parameters worth tracking
  bool get hasAttributionData =>
      utmSource != null ||
      utmMedium != null ||
      utmCampaign != null ||
      referralSlug != null ||
      referralClickId != null;

  /// Convert to JSON for API request
  Map<String, dynamic> toJson() {
    return {
      'visitor_id': visitorId,
      'platform': platform,
      if (utmSource != null) 'utm_source': utmSource,
      if (utmMedium != null) 'utm_medium': utmMedium,
      if (utmCampaign != null) 'utm_campaign': utmCampaign,
      if (utmContent != null) 'utm_content': utmContent,
      if (utmTerm != null) 'utm_term': utmTerm,
      if (referralSlug != null) 'referral_slug': referralSlug,
      if (referralClickId != null) 'referral_click_id': referralClickId,
      if (landingUrl != null) 'landing_url': landingUrl,
      if (referrerUrl != null) 'referrer_url': referrerUrl,
      if (installReferrerRaw != null)
        'install_referrer_raw': installReferrerRaw,
      if (posthogDistinctId != null) 'posthog_distinct_id': posthogDistinctId,
    };
  }

  /// Create from JSON (for storage/retrieval)
  factory AttributionData.fromJson(Map<String, dynamic> json) {
    return AttributionData(
      visitorId: json['visitor_id'] as String,
      platform: json['platform'] as String,
      utmSource: json['utm_source'] as String?,
      utmMedium: json['utm_medium'] as String?,
      utmCampaign: json['utm_campaign'] as String?,
      utmContent: json['utm_content'] as String?,
      utmTerm: json['utm_term'] as String?,
      referralSlug: json['referral_slug'] as String?,
      referralClickId: json['referral_click_id'] as String?,
      landingUrl: json['landing_url'] as String?,
      referrerUrl: json['referrer_url'] as String?,
      installReferrerRaw: json['install_referrer_raw'] as String?,
      posthogDistinctId: json['posthog_distinct_id'] as String?,
    );
  }

  AttributionData copyWith({
    String? visitorId,
    String? platform,
    String? utmSource,
    String? utmMedium,
    String? utmCampaign,
    String? utmContent,
    String? utmTerm,
    String? referralSlug,
    String? referralClickId,
    String? landingUrl,
    String? referrerUrl,
    String? installReferrerRaw,
    String? posthogDistinctId,
  }) {
    return AttributionData(
      visitorId: visitorId ?? this.visitorId,
      platform: platform ?? this.platform,
      utmSource: utmSource ?? this.utmSource,
      utmMedium: utmMedium ?? this.utmMedium,
      utmCampaign: utmCampaign ?? this.utmCampaign,
      utmContent: utmContent ?? this.utmContent,
      utmTerm: utmTerm ?? this.utmTerm,
      referralSlug: referralSlug ?? this.referralSlug,
      referralClickId: referralClickId ?? this.referralClickId,
      landingUrl: landingUrl ?? this.landingUrl,
      referrerUrl: referrerUrl ?? this.referrerUrl,
      installReferrerRaw: installReferrerRaw ?? this.installReferrerRaw,
      posthogDistinctId: posthogDistinctId ?? this.posthogDistinctId,
    );
  }

  @override
  String toString() {
    return 'AttributionData(visitorId: $visitorId, platform: $platform, '
        'utmSource: $utmSource, utmCampaign: $utmCampaign, referralSlug: $referralSlug)';
  }
}

/// Response from the touchpoint API
class TouchpointResponse {
  final String id;
  final String visitorId;
  final String platform;
  final int touchNumber;
  final DateTime touchedAt;

  const TouchpointResponse({
    required this.id,
    required this.visitorId,
    required this.platform,
    required this.touchNumber,
    required this.touchedAt,
  });

  factory TouchpointResponse.fromJson(Map<String, dynamic> json) {
    return TouchpointResponse(
      id: json['id'] as String,
      visitorId: json['visitor_id'] as String,
      platform: json['platform'] as String,
      touchNumber: json['touch_number'] as int,
      touchedAt: DateTime.parse(json['touched_at'] as String),
    );
  }
}
