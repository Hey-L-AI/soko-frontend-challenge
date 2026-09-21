/// Business Connect portal venue search / resolve DTOs (PROD-4039 / PROD-4040).
///
/// Consumed by the authed claim flow: the owner searches for their venue
/// (local-only autocomplete) or pastes a Google Maps link to resolve it. Both
/// surfaces return [PortalVenueCandidate]s whose [claimStatus] is caller-
/// relative — "you already own it" vs "someone else claimed it" vs "free to
/// claim". These endpoints are flag-gated server-side (404 while
/// BUSINESS_OWNERSHIP_ENABLED is off), so a malformed response should degrade
/// gracefully rather than crash the dashboard.
library;

/// Caller-relative ownership state of a candidate venue (not a global flag).
enum PortalClaimStatus {
  unclaimed,
  ownedByMe,
  claimedByOther,

  /// Wire value we don't recognise — treat as non-actionable.
  unknown;

  static PortalClaimStatus fromWire(Object? value) {
    switch (value) {
      case 'unclaimed':
        return PortalClaimStatus.unclaimed;
      case 'owned_by_me':
        return PortalClaimStatus.ownedByMe;
      case 'claimed_by_other':
        return PortalClaimStatus.claimedByOther;
      default:
        return PortalClaimStatus.unknown;
    }
  }

  /// Google-tier variant: the wire field is nullable, and a *null* status is
  /// meaningful ("not yet in our DB — resolve the place id before claiming"),
  /// distinct from [unknown] (a non-null value we don't recognise). Returns
  /// null only for a null wire value.
  static PortalClaimStatus? fromWireOrNull(Object? value) =>
      value == null ? null : fromWire(value);
}

double? _double(Object? value) => value is num ? value.toDouble() : null;

String? _stringOrNull(Object? value) => value is String ? value : null;

String _string(Object? value) => value is String ? value : '';

class PortalVenueCandidate {
  const PortalVenueCandidate({
    required this.venueId,
    required this.claimStatus,
    this.name,
    this.address,
    this.city,
    this.neighborhood,
    this.googlePlaceId,
    this.latitude,
    this.longitude,
    this.created,
  });

  final String venueId;
  final PortalClaimStatus claimStatus;
  final String? name;
  final String? address;
  final String? city;
  final String? neighborhood;
  final String? googlePlaceId;
  final double? latitude;
  final double? longitude;

  /// Resolve only: `true` when the paste minted the venue via Google Places
  /// fallback (HTTP 201). `null` for search results and already-known venues.
  final bool? created;

  factory PortalVenueCandidate.fromJson(Map<String, dynamic> json) =>
      PortalVenueCandidate(
        venueId: _string(json['venue_id']),
        claimStatus: PortalClaimStatus.fromWire(json['claim_status']),
        name: _stringOrNull(json['name']),
        address: _stringOrNull(json['address']),
        city: _stringOrNull(json['city']),
        neighborhood: _stringOrNull(json['neighborhood']),
        googlePlaceId: _stringOrNull(json['google_place_id']),
        latitude: _double(json['latitude']),
        longitude: _double(json['longitude']),
        created: json['created'] is bool ? json['created'] as bool : null,
      );
}

class PortalVenueSearchResponse {
  const PortalVenueSearchResponse({required this.results});

  final List<PortalVenueCandidate> results;

  factory PortalVenueSearchResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['results'];
    final results = raw is List
        ? raw
              .whereType<Map<String, dynamic>>()
              .map(PortalVenueCandidate.fromJson)
              .toList()
        : <PortalVenueCandidate>[];
    return PortalVenueSearchResponse(results: results);
  }
}

/// Whether the transient Google search returned every candidate's core display
/// fields ([complete]) or at least one was missing name/address/coordinates
/// ([partial] — a thin Google payload). Any unrecognised wire value degrades to
/// [complete] rather than crashing the panel.
enum PortalGoogleSearchStatus {
  complete,
  partial;

  static PortalGoogleSearchStatus fromWire(Object? value) => value == 'partial'
      ? PortalGoogleSearchStatus.partial
      : PortalGoogleSearchStatus.complete;
}

/// A Google-place candidate from the transient name search (S4,
/// `GET /business/venues/search/google`). Place-centric: [googlePlaceId] is the
/// identity. [venueId] / [claimStatus] are set ONLY when an active canonical
/// venue already carries this place id (a read-only lookup — the search mints
/// nothing). A null [claimStatus] means "not yet in our DB"; the owner resolves
/// the place id via `POST /business/venues/resolve` (which may mint) before
/// claiming.
class PortalGoogleVenueCandidate {
  const PortalGoogleVenueCandidate({
    required this.googlePlaceId,
    this.name,
    this.address,
    this.city,
    this.country,
    this.latitude,
    this.longitude,
    this.venueId,
    this.claimStatus,
  });

  final String googlePlaceId;
  final String? name;
  final String? address;
  final String? city;
  final String? country;
  final double? latitude;
  final double? longitude;

  /// Canonical venue id when this place is already an active venue in our DB,
  /// else null (the place must be resolved before it can be claimed).
  final String? venueId;

  /// Caller-relative claim state when [venueId] is set, else null.
  final PortalClaimStatus? claimStatus;

  factory PortalGoogleVenueCandidate.fromJson(Map<String, dynamic> json) =>
      PortalGoogleVenueCandidate(
        googlePlaceId: _string(json['google_place_id']),
        name: _stringOrNull(json['name']),
        address: _stringOrNull(json['address']),
        city: _stringOrNull(json['city']),
        country: _stringOrNull(json['country']),
        latitude: _double(json['latitude']),
        longitude: _double(json['longitude']),
        venueId: _stringOrNull(json['venue_id']),
        claimStatus: PortalClaimStatus.fromWireOrNull(json['claim_status']),
      );
}

class PortalGoogleSearchResponse {
  const PortalGoogleSearchResponse({
    required this.candidates,
    required this.status,
    required this.attribution,
  });

  final List<PortalGoogleVenueCandidate> candidates;
  final PortalGoogleSearchStatus status;

  /// Google Places attribution string. Parsed for contract fidelity; the portal
  /// deliberately does not render it (decided 2026-09-08 — the app shows
  /// un-attributed Google rows elsewhere and these read as regular venues).
  final String attribution;

  factory PortalGoogleSearchResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['candidates'];
    final candidates = raw is List
        ? raw
              .whereType<Map<String, dynamic>>()
              .map(PortalGoogleVenueCandidate.fromJson)
              .toList()
        : <PortalGoogleVenueCandidate>[];
    return PortalGoogleSearchResponse(
      candidates: candidates,
      status: PortalGoogleSearchStatus.fromWire(json['status']),
      attribution: _string(json['attribution']),
    );
  }
}
