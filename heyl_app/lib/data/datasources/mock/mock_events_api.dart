import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'mock_data.dart';

/// Mock implementation of Events API
class MockEventsApi implements IEventsApi {
  /// List events
  Future<EventListResponse> listEvents({
    String? city,
    String? startDate,
    String? endDate,
    int limit = 100,
    String? cursor,
  }) async {
    await _simulateDelay();

    var events = List<Event>.from(MockData.mockEvents);

    // Filter by city if provided
    if (city != null && city.isNotEmpty) {
      events = events.where((e) =>
        e.city?.toLowerCase() == city.toLowerCase()
      ).toList();
    }

    // Filter by date range if provided
    if (startDate != null) {
      final start = DateTime.parse(startDate);
      events = events.where((e) =>
        e.startDate == null || e.startDate!.isAfter(start)
      ).toList();
    }

    if (endDate != null) {
      final end = DateTime.parse(endDate);
      events = events.where((e) =>
        e.startDate == null || e.startDate!.isBefore(end)
      ).toList();
    }

    return EventListResponse(
      items: events.take(limit).toList(),
      nextCursor: null,
    );
  }

  @override
  Future<EventDetailResponse> getEvent(String eventId, {String? startDate, String? endDate}) async {
    await _simulateDelay(milliseconds: 200);

    final event = MockData.mockEvents.cast<Event?>().firstWhere(
      (e) => e?.id == eventId,
      orElse: () => null,
    );

    if (event == null) {
      throw Exception('Event not found: $eventId');
    }

    return EventDetailResponse(
      id: event.id,
      title: event.title,
      category: event.category,
      description: event.description,
      imageUrl: event.imageUrl,
      venueName: event.venueName,
      city: event.city,
    );
  }

  Future<void> _simulateDelay({int milliseconds = 300}) async {
    await Future.delayed(Duration(milliseconds: milliseconds));
  }
}
