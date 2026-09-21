import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Result from IP-based geolocation containing coordinates and region info.
class IpGeolocationResult {
  final String countryCode;
  final double latitude;
  final double longitude;
  final String? city;
  final String? region;

  const IpGeolocationResult({
    required this.countryCode,
    required this.latitude,
    required this.longitude,
    this.city,
    this.region,
  });

  Map<String, dynamic> toJson() => {
    'countryCode': countryCode,
    'latitude': latitude,
    'longitude': longitude,
    'city': city,
    'region': region,
  };

  factory IpGeolocationResult.fromJson(Map<String, dynamic> json) {
    return IpGeolocationResult(
      countryCode: json['countryCode'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      city: json['city'] as String?,
      region: json['region'] as String?,
    );
  }
}

/// Service for detecting user's location via IP address.
/// Uses ipapi.co (free, supports HTTPS, no API key required).
///
/// Results are cached locally for 24 hours to minimize API usage
/// (ipapi.co free tier has a daily request limit).
class IpGeolocationService {
  /// Ordered provider chain. Both are free, keyless and HTTPS. We try each in
  /// turn and return the first valid result, so a rate-limit/timeout on the
  /// primary (PROD-4278 — the dominant cause of the missing IP fix) is covered
  /// by the backup instead of falling through to "no location".
  static const List<String> _providerUrls = [
    'https://ipapi.co/json/', // primary
    'https://ipwho.is/', // backup
  ];
  static const Duration _timeout = Duration(seconds: 4);
  static const Duration _cacheTtl = Duration(hours: 24);
  static const String _cacheKey = 'ip_geolocation_cache';
  static const String _cacheTimestampKey = 'ip_geolocation_cache_ts';

  /// Detects the user's location via IP address.
  ///
  /// Returns a cached result if available and less than 24 hours old.
  /// Otherwise makes a fresh API call and caches the result.
  /// If the API call fails, returns a stale cache (any age) as fallback.
  Future<IpGeolocationResult?> detectLocation() async {
    // Try cache first
    final cached = await _loadCache();
    if (cached != null) {
      final age = DateTime.now().difference(cached.$2);
      if (age < _cacheTtl) {
        debugPrint(
          '[IpGeolocationService] Using cached result (age: ${age.inMinutes}m)',
        );
        return cached.$1;
      }
      debugPrint(
        '[IpGeolocationService] Cache expired (age: ${age.inHours}h), refreshing',
      );
    }

    // Fetch fresh result
    final fresh = await _fetchFromApi();
    if (fresh != null) {
      await _saveCache(fresh);
      return fresh;
    }

    // API failed — fall back to stale cache if available
    if (cached != null) {
      debugPrint(
        '[IpGeolocationService] API failed, using stale cache as fallback',
      );
      return cached.$1;
    }

    return null;
  }

  /// Detects the user's country code via IP address.
  /// Returns ISO 3166-1 alpha-2 country code (e.g., "BR", "PT", "US")
  /// or null if detection fails.
  Future<String?> detectCountryCode() async {
    final result = await detectLocation();
    return result?.countryCode;
  }

  Future<IpGeolocationResult?> _fetchFromApi() async {
    // Try each provider in order; return the first valid fix. Providers share
    // a response shape (ipapi.co and ipwho.is both expose
    // country_code/latitude/longitude), and ipwho.is adds a `success` flag we
    // honour below.
    for (final url in _providerUrls) {
      final result = await _fetchFromProvider(url);
      if (result != null) return result;
    }

    debugPrint('[IpGeolocationService] All providers failed to detect location');
    return null;
  }

  Future<IpGeolocationResult?> _fetchFromProvider(String url) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(_timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;

        // ipwho.is signals a failed lookup with `success: false` (still HTTP
        // 200); ipapi.co has no such flag, so absence is treated as success.
        if (data['success'] == false) {
          debugPrint(
            '[IpGeolocationService] $url reported failure: ${data['message']}',
          );
          return null;
        }

        final countryCode = data['country_code'] as String?;
        final latitude = (data['latitude'] as num?)?.toDouble();
        final longitude = (data['longitude'] as num?)?.toDouble();

        if (countryCode != null &&
            countryCode.isNotEmpty &&
            latitude != null &&
            longitude != null) {
          debugPrint(
            '[IpGeolocationService] Detected via $url: '
            '$countryCode ($latitude, $longitude)',
          );
          return IpGeolocationResult(
            countryCode: countryCode.toUpperCase(),
            latitude: latitude,
            longitude: longitude,
            city: data['city'] as String?,
            region: data['region'] as String?,
          );
        }
      }

      debugPrint(
        '[IpGeolocationService] $url failed: status=${response.statusCode}',
      );
      return null;
    } on TimeoutException {
      debugPrint('[IpGeolocationService] $url timed out');
      return null;
    } catch (e) {
      debugPrint('[IpGeolocationService] $url error: $e');
      return null;
    }
  }

  Future<(IpGeolocationResult, DateTime)?> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_cacheKey);
      final tsMs = prefs.getInt(_cacheTimestampKey);
      if (jsonStr == null || tsMs == null) return null;

      final result = IpGeolocationResult.fromJson(
        json.decode(jsonStr) as Map<String, dynamic>,
      );
      final timestamp = DateTime.fromMillisecondsSinceEpoch(tsMs);
      return (result, timestamp);
    } catch (e) {
      debugPrint('[IpGeolocationService] Failed to load cache: $e');
      return null;
    }
  }

  Future<void> _saveCache(IpGeolocationResult result) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, json.encode(result.toJson()));
      await prefs.setInt(
        _cacheTimestampKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      debugPrint('[IpGeolocationService] Failed to save cache: $e');
    }
  }

  /// Clears the IP-geolocation cache. Used by [detectedCountryCodeProvider]
  /// when invalidating across an authenticated-identity change so the next
  /// detection re-resolves against the new session's egress IP (PROD-2285).
  Future<void> clearCache(SharedPreferences prefs) async {
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheTimestampKey);
  }
}
