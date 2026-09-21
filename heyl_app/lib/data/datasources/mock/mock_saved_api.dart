import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'mock_data.dart';

/// Mock implementation of Saved Items API
class MockSavedApi implements ISavedApi {
  final List<SavedItem> _savedItems = List.from(MockData.mockSavedItems);

  /// List saved items
  Future<SavedListResponse> listSaved({
    String? type,
    int limit = 50,
    String? cursor,
  }) async {
    await _simulateDelay();

    var items = List<SavedItem>.from(_savedItems);

    // Filter by type if provided
    if (type != null && type != 'all') {
      final savedType = type == 'event'
          ? SavedItemType.event
          : SavedItemType.place;
      items = items.where((i) => i.type == savedType).toList();
    }

    // Sort by createdAt descending
    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return SavedListResponse(
      items: items.take(limit).toList(),
      nextCursor: null,
    );
  }

  /// Save an item
  Future<SavedItem> saveItem(SavedCreateRequest request) async {
    await _simulateDelay();

    // Check if already saved
    final existing = _savedItems.where((i) {
      if (request.type == SavedItemType.event) {
        return i.eventId == request.eventId;
      } else {
        return i.venueId == request.venueId;
      }
    }).firstOrNull;

    if (existing != null) {
      return existing;
    }

    // Create new saved item
    final item = SavedItem(
      savedId: 'saved_${DateTime.now().millisecondsSinceEpoch}',
      type: request.type,
      eventId: request.eventId,
      venueId: request.venueId,
      createdAt: DateTime.now(),
    );

    _savedItems.insert(0, item);
    return item;
  }

  /// Remove a saved item
  @override
  Future<void> deleteSaved(String savedId) async {
    await _simulateDelay(milliseconds: 200);
    _savedItems.removeWhere((i) => i.savedId == savedId);
  }

  /// Check if an item is saved
  bool isSaved({String? eventId, String? venueId}) {
    return _savedItems.any((i) {
      if (eventId != null) return i.eventId == eventId;
      if (venueId != null) return i.venueId == venueId;
      return false;
    });
  }

  /// Clear cached data (call on logout)
  @override
  void clearCache() {
    // No-op for mock
  }

  Future<void> _simulateDelay({int milliseconds = 300}) async {
    await Future.delayed(Duration(milliseconds: milliseconds));
  }
}
