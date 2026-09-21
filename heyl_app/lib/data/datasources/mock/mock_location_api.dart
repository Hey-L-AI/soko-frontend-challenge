import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'mock_data.dart';

/// Mock implementation of Location API
class MockLocationApi implements ILocationApi {
  LocationSnapshot? _lastLocation = MockData.mockLocation;

  /// Update location
  @override
  Future<LocationUpdateResponse> updateLocation(
    LocationUpdateRequest request,
  ) async {
    await _simulateDelay(milliseconds: 200);

    _lastLocation = LocationSnapshot(
      lat: request.lat,
      lon: request.lon,
      accuracyM: request.accuracyM,
      source: request.source.asLocationSource,
      capturedAt: request.capturedAt,
    );

    final now = DateTime.now();
    return LocationUpdateResponse(
      id: 'mock-location-${now.millisecondsSinceEpoch}',
      latitude: request.lat,
      longitude: request.lon,
      geoHash: 'mock_geohash',
      capturedAt: request.capturedAt,
      createdAt: now,
      updatedAt: now,
      accuracyM: request.accuracyM,
      source: request.source.toJson(),
    );
  }

  /// Update tagged location (e.g., "current", "home")
  @override
  Future<LocationUpdateResponse> updateTaggedLocation(
    String tag,
    LocationUpdateRequest request,
  ) async {
    await _simulateDelay(milliseconds: 200);

    final now = DateTime.now();
    return LocationUpdateResponse(
      id: 'mock-tagged-$tag-${now.millisecondsSinceEpoch}',
      latitude: request.lat,
      longitude: request.lon,
      geoHash: 'mock_geohash',
      capturedAt: request.capturedAt,
      createdAt: now,
      updatedAt: now,
      accuracyM: request.accuracyM,
      source: request.source.toJson(),
    );
  }

  /// Get last known location
  @override
  Future<LocationSnapshot?> getLocation() async {
    await _simulateDelay(milliseconds: 200);
    return _lastLocation;
  }

  /// Create share link
  @override
  Future<Map<String, dynamic>> createShareLink({
    int expiresInHours = 24,
  }) async {
    await _simulateDelay();

    final shareId = 'locshare_${DateTime.now().millisecondsSinceEpoch}';
    final expiresAt = DateTime.now().add(Duration(hours: expiresInHours));

    return {
      'share_id': shareId,
      'expires_at': expiresAt.toIso8601String(),
      'url': 'https://heyl.ai/location/share/$shareId',
    };
  }

  /// Set location (for testing)
  void setLocation(LocationSnapshot location) {
    _lastLocation = location;
  }

  Future<void> _simulateDelay({int milliseconds = 300}) async {
    await Future.delayed(Duration(milliseconds: milliseconds));
  }
}
