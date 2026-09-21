import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../core/services/storage_service.dart';
import '../core/services/unified_analytics_service.dart';
import '../data/models/models.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import 'api_provider.dart';

/// State for saved items
class SavedState {
  final List<SavedItem> items;
  final bool isLoading;
  final String? error;

  const SavedState({this.items = const [], this.isLoading = false, this.error});

  SavedState copyWith({
    List<SavedItem>? items,
    bool? isLoading,
    String? error,
  }) {
    return SavedState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  /// Get saved events
  List<SavedItem> get events =>
      items.where((i) => i.type == SavedItemType.event).toList();

  /// Get saved places
  List<SavedItem> get places =>
      items.where((i) => i.type == SavedItemType.place).toList();
}

/// Notifier for saved items
class SavedNotifier extends StateNotifier<SavedState> {
  final ISavedApi _api;
  final StorageService _storageService;
  final UnifiedAnalyticsService _analytics;

  SavedNotifier(this._api, this._storageService, this._analytics)
    : super(const SavedState()) {
    _loadFromStorage();
  }

  /// Load saved items from local storage first
  void _loadFromStorage() {
    final cachedItems = _storageService.loadSavedItems();
    if (cachedItems.isNotEmpty) {
      state = state.copyWith(items: cachedItems);
    }
  }

  /// Persist current items to storage
  Future<void> _persistToStorage() async {
    await _storageService.saveSavedItems(state.items);
  }

  /// Load saved items
  Future<void> loadSaved({String? type}) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final response = await _api.listSaved(type: type);
      state = state.copyWith(items: response.items, isLoading: false);
      await _persistToStorage();
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Save an event
  Future<bool> saveEvent(String eventId) async {
    try {
      final item = await _api.saveItem(SavedCreateRequest.event(eventId));
      state = state.copyWith(items: [item, ...state.items]);
      await _persistToStorage();
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// Save a place
  Future<bool> savePlace(String venueId) async {
    try {
      final item = await _api.saveItem(SavedCreateRequest.place(venueId));
      state = state.copyWith(items: [item, ...state.items]);
      await _persistToStorage();
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// Save a ItemSuggestion (auto-detects Mode 1 vs Mode 2)
  /// Mode 1: Has DB ID (eventId or venueId)
  /// Mode 2: External data (title+url for events, name+city for places)
  Future<bool> saveItemSuggestion(ItemSuggestion place) async {
    try {
      final request = await SavedCreateRequest.fromItemSuggestion(place);
      final item = await _api.saveItem(request);
      state = state.copyWith(items: [item, ...state.items]);
      await _persistToStorage();
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// Remove a saved item
  Future<bool> removeSaved(String savedId) async {
    // Lookup the item for the analytics payload. firstWhereOrNull guards
    // against `state.items` being empty (e.g., the unsave was triggered
    // before the saved-list cache loaded) — without it, the previous
    // `orElse: () => state.items.first` would throw on an empty list
    // and bail before the API call ran. (PROD-2084 audit)
    final item = state.items.firstWhereOrNull((i) => i.savedId == savedId);

    try {
      // Call API to delete
      await _api.deleteSaved(savedId);

      // Remove from local state
      state = state.copyWith(
        items: state.items.where((i) => i.savedId != savedId).toList(),
      );
      await _persistToStorage();
      if (item != null) {
        _analytics.trackItemUnsave(itemId: savedId, itemType: item.type.name);
      }
      return true;
    } catch (e, st) {
      // PROD-2084 — forward to Sentry so the next regression in this
      // path doesn't stay invisible. Best-effort; `unawaited` keeps
      // the captureException Future from changing this method's
      // return value or timing.
      unawaited(Sentry.captureException(e, stackTrace: st));
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// Check if an item is saved
  bool isSaved({String? eventId, String? venueId}) {
    return _api.isSaved(eventId: eventId, venueId: venueId);
  }

  /// Refresh saved items
  Future<void> refresh() => loadSaved();
}

/// Provider for saved state
final savedProvider = StateNotifierProvider<SavedNotifier, SavedState>((ref) {
  final api = ref.watch(savedApiProvider);
  final storageService = ref.watch(storageServiceProvider);
  final analytics = ref.watch(unifiedAnalyticsProvider);
  final notifier = SavedNotifier(api, storageService, analytics);
  notifier.loadSaved();
  return notifier;
});

/// Provider for saved events count
final savedEventsCountProvider = Provider<int>((ref) {
  return ref.watch(savedProvider).events.length;
});

/// Provider for saved places count
final savedPlacesCountProvider = Provider<int>((ref) {
  return ref.watch(savedProvider).places.length;
});
