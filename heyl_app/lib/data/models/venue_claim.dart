/// Business ownership claim DTOs (PROD-3709).
///
/// The claim endpoints are feature-gated, so a malformed response should
/// degrade to a non-actionable state rather than crash venue detail.
String _string(Map<String, dynamic> json, String key) =>
    json[key] is String ? json[key] as String : '';

bool _bool(Map<String, dynamic> json, String key) =>
    json[key] is bool ? json[key] as bool : false;

DateTime _dateTime(Map<String, dynamic> json, String key) =>
    DateTime.tryParse(_string(json, key)) ??
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

class ClaimSummary {
  const ClaimSummary({
    required this.id,
    required this.venueId,
    required this.status,
    required this.method,
    required this.source,
    required this.createdAt,
    this.tier,
  });

  final String id;
  final String venueId;
  final String status;
  final String? tier;
  final String method;
  final String source;
  final DateTime createdAt;

  factory ClaimSummary.fromJson(Map<String, dynamic> json) => ClaimSummary(
    id: _string(json, 'id'),
    venueId: _string(json, 'venue_id'),
    status: _string(json, 'status'),
    tier: json['tier'] as String?,
    method: _string(json, 'method'),
    source: _string(json, 'source'),
    createdAt: _dateTime(json, 'created_at'),
  );
}

class ClaimStateResponse {
  const ClaimStateResponse({
    required this.venueId,
    required this.isOwner,
    this.claim,
  });

  final String venueId;
  final bool isOwner;
  final ClaimSummary? claim;

  factory ClaimStateResponse.fromJson(Map<String, dynamic> json) =>
      ClaimStateResponse(
        venueId: _string(json, 'venue_id'),
        isOwner: _bool(json, 'is_owner'),
        claim: json['claim'] == null
            ? null
            : ClaimSummary.fromJson(json['claim'] as Map<String, dynamic>),
      );
}

class ClaimInitiateResponse {
  const ClaimInitiateResponse({required this.authorizationUrl});

  final String authorizationUrl;

  factory ClaimInitiateResponse.fromJson(Map<String, dynamic> json) =>
      ClaimInitiateResponse(
        authorizationUrl: _string(json, 'authorization_url'),
      );
}

class OwnedVenueSummary {
  const OwnedVenueSummary({required this.venueId});

  final String venueId;

  factory OwnedVenueSummary.fromJson(Map<String, dynamic> json) =>
      OwnedVenueSummary(venueId: _string(json, 'venue_id'));
}

class OwnedBusiness {
  const OwnedBusiness({
    required this.id,
    required this.name,
    required this.venues,
  });

  final String id;
  final String name;
  final List<OwnedVenueSummary> venues;

  factory OwnedBusiness.fromJson(Map<String, dynamic> json) => OwnedBusiness(
    id: _string(json, 'id'),
    name: _string(json, 'name'),
    venues: (json['venues'] as List<dynamic>)
        .map((item) => OwnedVenueSummary.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
}

class OwnerVenueUpdate {
  const OwnerVenueUpdate(this.fields);

  final Map<String, dynamic> fields;
}
