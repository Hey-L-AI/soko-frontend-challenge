import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import 'api_provider.dart';

/// Provider for events list
final eventsProvider = FutureProvider<List<Event>>((ref) async {
  final api = ref.watch(eventsApiProvider);
  final response = await api.listEvents();
  return response.items;
});

/// Provider for events by city
final eventsByCityProvider =
    FutureProvider.family<List<Event>, String>((ref, city) async {
  final api = ref.watch(eventsApiProvider);
  final response = await api.listEvents(city: city);
  return response.items;
});

/// Provider for a single event (finds from cached list)
/// Note: For full event detail with occurrences, use eventsApiProvider.getEvent() instead
final eventByIdProvider =
    FutureProvider.family<Event?, String>((ref, eventId) async {
  // Get all events and find by ID (lightweight, no occurrence data)
  final events = await ref.watch(eventsProvider.future);
  return events.cast<Event?>().firstWhere(
        (e) => e?.id == eventId,
        orElse: () => null,
      );
});

/// Provider for venues list
final venuesProvider = FutureProvider<List<Venue>>((ref) async {
  final api = ref.watch(venuesApiProvider);
  final response = await api.listVenues();
  return response.items;
});

/// Provider for venues by city
final venuesByCityProvider =
    FutureProvider.family<List<Venue>, String>((ref, city) async {
  final api = ref.watch(venuesApiProvider);
  final response = await api.listVenues(city: city);
  return response.items;
});

/// Provider for a single venue (finds from cached list)
/// Note: No single-venue endpoint exists in OpenAPI spec
final venueByIdProvider =
    FutureProvider.family<Venue?, String>((ref, venueId) async {
  // Get all venues and find by ID (no single-venue endpoint in API)
  final venues = await ref.watch(venuesProvider.future);
  return venues.cast<Venue?>().firstWhere(
        (v) => v?.id == venueId,
        orElse: () => null,
      );
});
