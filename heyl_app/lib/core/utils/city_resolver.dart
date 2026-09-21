import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geocoding/geocoding.dart' as geocoding;

/// Resolves city name from available place data using a priority cascade:
/// 1. Backend-provided city (direct passthrough)
/// 2. Reverse geocoding from coordinates (iOS/Android only)
/// 3. Address string parsing (all platforms)
/// 4. null (never hardcodes a city name)
class CityResolver {
  /// Resolve city from available place data.
  ///
  /// Tries each source in priority order and returns the first non-empty result.
  /// Returns null if city cannot be determined — callers should handle this
  /// gracefully rather than using a hardcoded fallback.
  static Future<String?> resolveCity({
    String? city,
    double? lat,
    double? lng,
    String? address,
  }) async {
    // 1. Use backend-provided city if available
    if (city != null && city.isNotEmpty) return city;

    // 2. Reverse geocode from coordinates (iOS/Android only)
    if (!kIsWeb && lat != null && lng != null) {
      final resolved = await _reverseGeocode(lat, lng);
      if (resolved != null && resolved.isNotEmpty) return resolved;
    }

    // 3. Parse city from address string
    if (address != null && address.isNotEmpty) {
      final parsed = extractCityFromAddress(address);
      if (parsed != null && parsed.isNotEmpty) return parsed;
    }

    // 4. No city found — return null, never hardcode
    return null;
  }

  /// Reverse geocode coordinates to get city name using native platform APIs.
  static Future<String?> _reverseGeocode(double lat, double lng) async {
    try {
      final placemarks = await geocoding.placemarkFromCoordinates(lat, lng);
      if (placemarks.isNotEmpty) {
        final placemark = placemarks.first;
        // locality = city name (works globally)
        if (placemark.locality != null && placemark.locality!.isNotEmpty) {
          return placemark.locality;
        }
        // Some regions use subAdministrativeArea instead of locality
        if (placemark.subAdministrativeArea != null &&
            placemark.subAdministrativeArea!.isNotEmpty) {
          return placemark.subAdministrativeArea;
        }
      }
    } catch (_) {
      // Geocoding can fail (no network, service unavailable, etc.)
      // Fall through to address parsing
    }
    return null;
  }

  /// Extract city from a formatted address string.
  ///
  /// Uses heuristics that work across many international address formats:
  /// - Portuguese postal codes (e.g., "1700-036 Lisboa")
  /// - Comma-separated parts with the city typically as the second-to-last
  ///   segment before the country
  static String? extractCityFromAddress(String? address) {
    if (address == null || address.isEmpty) return null;

    final parts = address.split(',').map((p) => p.trim()).toList();

    // For Portugal-style addresses with postal codes like "1700-036 Lisboa"
    final postalPattern = RegExp(r'^\d{4}-\d{3}\s+(.+)$');

    for (final part in parts) {
      final match = postalPattern.firstMatch(part);
      if (match != null) {
        return match.group(1);
      }
    }

    // Fallback: use second-to-last part (before country)
    if (parts.length >= 2) {
      final potentialCity = parts[parts.length - 2];
      final match = postalPattern.firstMatch(potentialCity);
      if (match != null) {
        return match.group(1);
      }
      // Strip postcodes embedded in the city part (e.g., "Glasgow G3 8AG" → "Glasgow")
      final stripped = potentialCity.replaceAll(RegExp(r'\s+[A-Z0-9]{2,4}\s+[A-Z0-9]{3,4}$'), '').trim();
      if (stripped.isNotEmpty && !RegExp(r'^[\d\s-]+$').hasMatch(stripped)) {
        return stripped;
      }
    }

    return null;
  }
}
