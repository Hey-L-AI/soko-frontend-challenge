/// Client-side Google Maps URL classification.
///
/// Mirrors the backend extraction in `heyl/apps/webapp/services/
/// google_maps_list_scraper.py:18` so that input detected here will also
/// be accepted by `POST /api/v1/app/venues/resolve-url`.
class GoogleMapsUrl {
  GoogleMapsUrl._();

  /// Case-insensitive patterns for the URL formats we accept.
  /// Order matters: more specific slug-bearing patterns first.
  static final List<RegExp> _patterns = <RegExp>[
    RegExp(r'https?://maps\.app\.goo\.gl/[A-Za-z0-9_-]+', caseSensitive: false),
    RegExp(r'https?://goo\.gl/maps/[A-Za-z0-9_-]+', caseSensitive: false),
    RegExp(
      r'https?://(?:www\.)?google\.[a-z.]+/maps/[^\s]+',
      caseSensitive: false,
    ),
    RegExp(r'https?://maps\.google\.[a-z.]+/[^\s]*', caseSensitive: false),
    RegExp(r'maps\.app\.goo\.gl/[A-Za-z0-9_-]+', caseSensitive: false),
    RegExp(r'goo\.gl/maps/[A-Za-z0-9_-]+', caseSensitive: false),
  ];

  /// Returns true when [input] contains (or is) a recognized Google Maps URL.
  ///
  /// Tolerates surrounding whitespace and text; matches short links, legacy
  /// short links, and full `google.com/maps/*` URLs (including ccTLD variants
  /// like `google.co.uk`).
  static bool looksLike(String input) {
    return extract(input) != null;
  }

  /// Extracts the first recognized Google Maps URL from [input].
  ///
  /// Returns the URL with `https://` prepended if missing, or null when
  /// no pattern matches. The input is trimmed before matching.
  static String? extract(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    for (final pattern in _patterns) {
      final match = pattern.firstMatch(trimmed);
      if (match == null) continue;
      final raw = match.group(0)!;
      return raw.startsWith('http') ? raw : 'https://$raw';
    }

    return null;
  }

  /// Build a Google Maps URL that resolves in BOTH browsers and the native
  /// Google Maps app on iOS/Android.
  ///
  /// Uses the documented Google Maps URLs API search action with `query`
  /// (human-readable name; also the fallback when Maps can't resolve the
  /// place_id) + `query_place_id` (canonical ChIJ… place_id). The older
  /// `q=place_id:<ID>` syntax — what the backend emits in `google_maps_url`
  /// — works in browsers but the native Google Maps app dumps the literal
  /// `place_id:<ID>` string into its search bar (PROD-1673).
  ///
  /// Returns null when there is no usable input.
  static String? canonicalPlaceUrl({
    String? placeId,
    String? name,
    double? latitude,
    double? longitude,
  }) {
    final hasPlaceId = placeId != null && placeId.isNotEmpty;
    final hasName = name != null && name.isNotEmpty;

    if (hasPlaceId || hasName) {
      final query = hasName ? name : placeId!;
      final buf = StringBuffer(
        'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(query)}',
      );
      if (hasPlaceId) buf.write('&query_place_id=$placeId');
      return buf.toString();
    }

    if (latitude != null && longitude != null) {
      return 'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude';
    }

    return null;
  }
}
