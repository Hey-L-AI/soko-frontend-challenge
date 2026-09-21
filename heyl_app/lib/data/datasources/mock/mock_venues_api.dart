import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'mock_data.dart';

/// Mock implementation of Venues API
class MockVenuesApi implements IVenuesApi {
  /// List venues
  Future<VenueListResponse> listVenues({
    String? city,
    int limit = 100,
    String? cursor,
  }) async {
    await _simulateDelay();

    var venues = List<Venue>.from(MockData.mockVenues);

    // Filter by city if provided
    if (city != null && city.isNotEmpty) {
      venues = venues
          .where((v) => v.city?.toLowerCase() == city.toLowerCase())
          .toList();
    }

    return VenueListResponse(
      items: venues.take(limit).toList(),
      nextCursor: null,
    );
  }

  /// Get a single venue by ID
  Future<Venue?> getVenue(String venueId) async {
    await _simulateDelay(milliseconds: 200);

    return MockData.mockVenues.cast<Venue?>().firstWhere(
      (v) => v?.id == venueId,
      orElse: () => null,
    );
  }

  @override
  Future<ResolveUrlResult> resolveVenueFromUrl(String url) async {
    await _simulateDelay(milliseconds: 400);
    // Deterministic mock: return the first mock venue as if resolved
    // from the URL so the sheet can render something sensible in
    // mock/fixture environments.
    final venue = MockData.mockVenues.first;
    return ResolveUrlPlace(
      ItemSuggestion(
        id: venue.id,
        name: venue.name,
        type: 'place',
        venueId: venue.id,
        address: venue.address,
        city: venue.city,
        latitude: venue.lat,
        longitude: venue.lon,
        tags: const [],
      ),
    );
  }

  @override
  Future<ItemSuggestion> resolvePlaceId(String googlePlaceId) async {
    await _simulateDelay(milliseconds: 300);
    // Deterministic mock: resolve to the first mock venue so the sheet can
    // render something sensible in mock/fixture environments.
    final venue = MockData.mockVenues.first;
    return ItemSuggestion(
      id: venue.id,
      name: venue.name,
      type: 'place',
      venueId: venue.id,
      address: venue.address,
      city: venue.city,
      latitude: venue.lat,
      longitude: venue.lon,
      googlePlaceId: googlePlaceId,
      tags: const [],
    );
  }

  Future<void> _simulateDelay({int milliseconds = 300}) async {
    await Future.delayed(Duration(milliseconds: milliseconds));
  }
}
