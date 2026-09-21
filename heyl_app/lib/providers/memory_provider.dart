import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import 'api_provider.dart';
import 'locale_provider.dart';

/// State for user memory
class MemoryState {
  final UserMemory? memory;
  final List<MemoryItem> items;
  final bool isLoading;
  final String? error;
  final TranslationStatus translationStatus;
  final bool isPolling;

  const MemoryState({
    this.memory,
    this.items = const [],
    this.isLoading = true,
    this.error,
    this.translationStatus = TranslationStatus.ready,
    this.isPolling = false,
  });

  MemoryState copyWith({
    UserMemory? memory,
    List<MemoryItem>? items,
    bool? isLoading,
    String? error,
    TranslationStatus? translationStatus,
    bool? isPolling,
  }) {
    return MemoryState(
      memory: memory ?? this.memory,
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      translationStatus: translationStatus ?? this.translationStatus,
      isPolling: isPolling ?? this.isPolling,
    );
  }

  /// Get items grouped by category
  Map<MemoryCategory, List<MemoryItem>> get itemsByCategory {
    final grouped = <MemoryCategory, List<MemoryItem>>{};
    for (final category in MemoryCategory.values) {
      grouped[category] = items.where((m) => m.category == category).toList();
    }
    return grouped;
  }

  /// Total memory count
  int get totalCount => items.length;

  /// Check if translation is pending (includes both pending and refreshing states)
  bool get isTranslationPending =>
      translationStatus == TranslationStatus.pending ||
      translationStatus == TranslationStatus.refreshing;
}

/// Notifier for user memory
class MemoryNotifier extends StateNotifier<MemoryState> {
  final IMemoryApi _api;
  String? _lastLocale;

  // Polling configuration
  static const _pollingInterval = Duration(seconds: 2);
  static const _maxPollingAttempts = 30;
  Timer? _pollingTimer;
  int _pollingAttempts = 0;

  MemoryNotifier(this._api) : super(const MemoryState());

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }

  /// Load memory with optional locale for localized content
  Future<void> loadMemory({String? locale}) async {
    _lastLocale = locale;
    _stopPolling();
    state = state.copyWith(isLoading: true, error: null);

    try {
      final memory = await _api.getMemory(locale: locale);
      final items = await _api.getMemoryItems(locale: locale);
      final translationStatus = memory.translationStatus;

      state = state.copyWith(
        memory: memory,
        items: items,
        isLoading: false,
        translationStatus: translationStatus,
      );

      // Start polling if translation is pending or refreshing
      if (translationStatus == TranslationStatus.pending ||
          translationStatus == TranslationStatus.refreshing) {
        _startPolling(locale);
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Start polling for translation completion
  void _startPolling(String? locale) {
    _stopPolling();
    _pollingAttempts = 0;
    state = state.copyWith(isPolling: true);

    _pollingTimer = Timer.periodic(_pollingInterval, (_) {
      _pollForTranslation(locale);
    });
  }

  /// Poll for translation status
  Future<void> _pollForTranslation(String? locale) async {
    _pollingAttempts++;

    // Stop polling if max attempts reached
    if (_pollingAttempts >= _maxPollingAttempts) {
      _stopPolling();
      return;
    }

    try {
      final memory = await _api.getMemory(locale: locale);
      final translationStatus = memory.translationStatus;

      // Use memory.memoryItems directly from the freshly fetched object
      // to avoid cache-related timing issues with separate getMemoryItems() call
      state = state.copyWith(
        memory: memory,
        items: memory.memoryItems,
        translationStatus: translationStatus,
      );

      // Stop polling if translation is complete or not available
      if (translationStatus == TranslationStatus.ready ||
          translationStatus == TranslationStatus.notAvailable) {
        _stopPolling();
      }
    } catch (e) {
      // Don't stop polling on error, just log and continue
      // The UI will still show the last known state
    }
  }

  /// Stop polling
  void _stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _pollingAttempts = 0;
    if (state.isPolling) {
      state = state.copyWith(isPolling: false);
    }
  }

  /// Delete a memory item by index
  Future<bool> deleteItem(int index) async {
    try {
      await _api.deleteMemoryItem(MemoryItemDeleteRequest.fact(index));
      // Refresh the list from API after deletion to get correct indices
      // Use the last locale that was used to load memory
      await loadMemory(locale: _lastLocale);
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// Export memory as markdown bytes in the current locale
  /// Returns the raw bytes of the markdown file for download/sharing
  /// Uses the last locale that was used to load memory to ensure consistency
  Future<List<int>> exportMemory() async {
    return await _api.exportMemory(locale: _lastLocale);
  }

  /// Refresh memory with optional locale for localized content
  Future<void> refresh({String? locale}) => loadMemory(locale: locale);
}

/// Provider for memory state
final memoryProvider = StateNotifierProvider<MemoryNotifier, MemoryState>((ref) {
  final api = ref.watch(memoryApiProvider);
  final notifier = MemoryNotifier(api);

  // Listen for locale changes and refresh memory
  ref.listen<String?>(apiLocaleCodeProvider, (previous, next) {
    // Refresh when locale changes, including first time it's set (null → value)
    if (previous != next && next != null) {
      notifier.refresh(locale: next);
    }
  });

  return notifier;
});

/// Provider for memory count
final memoryCountProvider = Provider<int>((ref) {
  return ref.watch(memoryProvider).totalCount;
});

/// Provider for memory items by category
final memoryByCategoryProvider =
    Provider<Map<MemoryCategory, List<MemoryItem>>>((ref) {
  return ref.watch(memoryProvider).itemsByCategory;
});
