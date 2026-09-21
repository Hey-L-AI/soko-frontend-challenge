import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/datasources/api/search_api.dart';
import '../../../data/models/models.dart';
import '../../../data/models/resolved_search_location.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/location_provider.dart';
import '../../../providers/lists_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';
import '../models/search_scope.dart';
import 'list_suggestions_cache.dart';

/// How many suggestions we show on first load.
const int _kInitialDisplay = 5;

/// Upper bound on visible suggestions. Clicking "Find more" expands in
/// [_kExpandStep] increments until we hit this cap, then the button hides.
const int _kMaxDisplay = 10;

/// How many extra suggestions appear each time the user taps "Find more".
const int _kExpandStep = 5;

/// How many results to fetch from the backend per search. Over-fetching lets
/// us keep showing N unique cards even after the user has saved/dismissed a
/// few, without another round-trip.
const int _kFetchLimit = 20;

/// State for list suggestions (AI-curated items based on a prompt)
class ListSuggestionsState {
  final List<ItemSuggestion> suggestions;
  final Set<String> excludeIds; // saved + dismissed IDs
  final bool isLoading;
  final bool hasLoaded;
  final String? error;

  /// True when there are still unseen items in the fetched pool AND we
  /// haven't hit the `_kMaxDisplay` cap. The widget uses this to show/hide
  /// the "Find more suggestions" button.
  final bool canLoadMore;

  /// Set when a background save fails after retries. The widget layer watches
  /// this to show a snackbar. Cleared after being consumed.
  final String? lastSaveError;

  const ListSuggestionsState({
    this.suggestions = const [],
    this.excludeIds = const {},
    this.isLoading = false,
    this.hasLoaded = false,
    this.error,
    this.canLoadMore = false,
    this.lastSaveError,
  });

  ListSuggestionsState copyWith({
    List<ItemSuggestion>? suggestions,
    Set<String>? excludeIds,
    bool? isLoading,
    bool? hasLoaded,
    String? error,
    bool clearError = false,
    bool? canLoadMore,
    String? lastSaveError,
    bool clearLastSaveError = false,
  }) {
    return ListSuggestionsState(
      suggestions: suggestions ?? this.suggestions,
      excludeIds: excludeIds ?? this.excludeIds,
      isLoading: isLoading ?? this.isLoading,
      hasLoaded: hasLoaded ?? this.hasLoaded,
      error: clearError ? null : (error ?? this.error),
      canLoadMore: canLoadMore ?? this.canLoadMore,
      lastSaveError: clearLastSaveError
          ? null
          : (lastSaveError ?? this.lastSaveError),
    );
  }
}

/// Notifier that manages loading, saving, and dismissing suggestions for a list.
///
/// PROD-1429: first version — calls `/app/places/search` with the list's
/// prompt (mode=full for LLM-grounded reasons), persists results in
/// SharedPreferences for 24h, filters locally on save/dismiss.
class ListSuggestionsNotifier extends StateNotifier<ListSuggestionsState> {
  final String listId;
  final SearchApi _searchApi;
  final ListSuggestionsCache _cache;
  final Ref _ref;

  /// Cached full fetch (up to _kFetchLimit items). Kept in memory so
  /// save/dismiss can surface more cards without re-reading SharedPreferences.
  List<ItemSuggestion> _pool = const [];

  /// How many items the UI should currently render. Grows in [_kExpandStep]
  /// steps each time the user taps "Find more"; capped at [_kMaxDisplay].
  int _displayCount = _kInitialDisplay;

  /// Prompt currently being fetched — used as a stale-result guard. When
  /// the user changes the prompt mid-fetch, the in-flight request's result
  /// would normally overwrite the state for the new prompt. We record the
  /// prompt at the start of every fetch and, when the response arrives,
  /// only apply it if this field still matches. Otherwise the result is
  /// silently discarded and the most-recent fetch wins.
  String? _inFlightPrompt;

  ListSuggestionsNotifier({
    required this.listId,
    required SearchApi searchApi,
    required ListSuggestionsCache cache,
    required Ref ref,
  }) : _searchApi = searchApi,
       _cache = cache,
       _ref = ref,
       super(const ListSuggestionsState());

  /// Load suggestions for [prompt], preferring the local cache unless
  /// [forceRefresh] is true.
  ///
  /// Safe to call repeatedly with the same prompt — if a fetch for the same
  /// prompt is already in flight we skip. If the prompt changes mid-fetch
  /// the earlier response is discarded via [_inFlightPrompt] so whatever
  /// lands second reflects the user's latest input.
  Future<void> loadSuggestions(
    String prompt, {
    bool forceRefresh = false,
  }) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) {
      _inFlightPrompt = null;
      state = state.copyWith(
        suggestions: const [],
        hasLoaded: true,
        isLoading: false,
        clearError: true,
      );
      return;
    }

    // Same prompt already being fetched — no need to double up.
    if (!forceRefresh && state.isLoading && _inFlightPrompt == trimmed) {
      return;
    }

    _inFlightPrompt = trimmed;
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      List<ItemSuggestion>? pool;

      // PROD-2004 follow-up: the search location now follows the home-page
      // city pick. Falls back to device GPS only when no home scope is set.
      // The cache is also keyed by the scope fingerprint so switching from
      // Lisbon → Porto on home doesn't serve stale Lisbon results.
      final resolved = await _ref.read(resolvedSearchLocationProvider.future);
      final searchLocation = resolveSuggestionsSearchLocationFromResolved(
        resolved: resolved,
        lastLocation: _ref.read(locationProvider).lastLocation,
      );
      final scopeKey = suggestionsResolvedLocationCacheKey(resolved);

      // Try cache unless caller forced a fresh fetch.
      if (!forceRefresh) {
        pool = await _cache.read(listId, trimmed, scopeKey: scopeKey);
      }

      // Cache miss or forced refresh → call the search endpoint.
      if (pool == null) {
        pool = await _searchApi.searchPlaces(
          query: trimmed,
          latitude: searchLocation.latitude,
          longitude: searchLocation.longitude,
          country: searchLocation.country,
          mode: 'full',
          maxResults: _kFetchLimit,
        );
        await _cache.write(listId, trimmed, pool, scopeKey: scopeKey);
      }

      if (!mounted) return;
      // Stale-result guard: the user changed the prompt while we were
      // fetching. Drop these results; a newer in-flight call is already
      // racing to replace them.
      if (_inFlightPrompt != trimmed) return;

      _pool = pool;
      _displayCount = _kInitialDisplay;
      state = state.copyWith(
        suggestions: _visibleFromPool(),
        canLoadMore: _poolHasMoreThanVisible(),
        isLoading: false,
        hasLoaded: true,
      );
    } catch (e) {
      debugPrint('[ListSuggestions] Error loading suggestions: $e');
      if (!mounted) return;
      if (_inFlightPrompt != trimmed) return;
      state = state.copyWith(
        isLoading: false,
        hasLoaded: true,
        error: e.toString(),
      );
    }
  }

  /// Return the currently-visible slice of the filtered pool.
  ///
  /// Filter order: drop items in `excludeIds` (saved/dismissed) and items
  /// without an image — those are the unenriched results and render as a
  /// placeholder icon, which looks broken. Then slice the first
  /// `_displayCount` survivors. Better to show fewer good cards than more
  /// weak ones (matches PROD-1429's "quality over quantity" iteration 1).
  List<ItemSuggestion> _visibleFromPool() {
    return _filteredPool().take(_displayCount).toList();
  }

  /// The filtered pool (excludes saved/dismissed items dropped) with no
  /// display cap — the notifier uses this to decide whether "Find more" can
  /// still surface additional items.
  ///
  /// PROD-2004 follow-up: the previous "drop items without an image_url"
  /// filter (PROD-1429 iteration 1, "quality over quantity") silently
  /// hid the entire section when the backend's `cached_images` table was
  /// cold for the user's city — observed on staging with the broken image
  /// warmup pipeline emitting "Failed to dispatch image warmup: [Errno
  /// 111] Connection refused" for every search. SuggestionItemRow already
  /// renders a fallback place/event icon when imageUrl is null, so it's
  /// always better to show a typed-icon card than nothing.
  Iterable<ItemSuggestion> _filteredPool() {
    return _pool.where((s) => !state.excludeIds.contains(s.id));
  }

  bool _poolHasMoreThanVisible() {
    if (_displayCount >= _kMaxDisplay) return false;
    // We only need one more item than we're currently showing to enable the
    // button — no need to count the whole pool.
    return _filteredPool().skip(_displayCount).isNotEmpty;
  }

  /// Recompute the visible slice + the canLoadMore flag from the cached pool
  /// and the latest `excludeIds`. Called after save / dismiss so items
  /// disappear from view and the "Find more" button updates accordingly.
  void _recomputeVisible() {
    state = state.copyWith(
      suggestions: _visibleFromPool(),
      canLoadMore: _poolHasMoreThanVisible(),
    );
  }

  /// Save a suggestion to the list, then remove it from the suggestions list
  void saveSuggestion(ItemSuggestion suggestion) {
    // Remove from suggestions and track exclusion
    final updatedExcludeIds = {...state.excludeIds, suggestion.id};

    state = state.copyWith(excludeIds: updatedExcludeIds);
    _recomputeVisible();

    // Use the existing optimistic save flow
    _ref
        .read(listsProvider.notifier)
        .addToListsOptimistic(
          [listId],
          suggestion,
          source: ListSource.listUi,
          onSuccess: () {
            debugPrint(
              '[ListSuggestions] Saved suggestion: ${suggestion.name}',
            );
          },
          onError: (errorMessage, canRetry, retry) {
            debugPrint('[ListSuggestions] Save error: $errorMessage');
          },
        );
  }

  /// Start saving a suggestion immediately (triggers backend save + optimistic
  /// list item) but keeps the card in the suggestions list so the exit
  /// animation can play. Call [removeSuggestion] after the animation completes.
  void startSave(ItemSuggestion suggestion) {
    // Track exclusion immediately (prevents duplicates on refresh)
    final updatedExcludeIds = {...state.excludeIds, suggestion.id};
    state = state.copyWith(excludeIds: updatedExcludeIds);

    // Fire the optimistic save — this updates pendingItems which triggers
    // mergeOptimisticItemsLocally in the unified list provider.
    _ref
        .read(listsProvider.notifier)
        .addToListsOptimistic(
          [listId],
          suggestion,
          source: ListSource.listUi,
          onSuccess: () {
            debugPrint(
              '[ListSuggestions] Saved suggestion: ${suggestion.name}',
            );
          },
          onError: (errorMessage, canRetry, retry) {
            debugPrint('[ListSuggestions] Save error: $errorMessage');
            if (!mounted) return;

            // Remove from excludeIds so the suggestion can reappear on next refresh
            final revertedExcludeIds = {...state.excludeIds}
              ..remove(suggestion.id);
            state = state.copyWith(
              excludeIds: revertedExcludeIds,
              lastSaveError: errorMessage,
            );
            _recomputeVisible();
          },
        );
  }

  /// Clear the [lastSaveError] after it has been shown to the user.
  void clearLastSaveError() {
    state = state.copyWith(clearLastSaveError: true);
  }

  /// Remove a suggestion from the visible list (called after exit animation).
  void removeSuggestion(String suggestionId) {
    _recomputeVisible();
  }

  /// Dismiss a suggestion (remove from list, no backend call)
  void dismissSuggestion(ItemSuggestion suggestion) {
    final updatedExcludeIds = {...state.excludeIds, suggestion.id};
    state = state.copyWith(excludeIds: updatedExcludeIds);
    _recomputeVisible();
  }

  /// Reset state (used when suggestions are disabled)
  void clear() {
    _pool = const [];
    _displayCount = _kInitialDisplay;
    _inFlightPrompt = null;
    state = const ListSuggestionsState();
  }

  /// "Find more suggestions" — append the next batch to the already-visible
  /// cards. We never replace what the user is already looking at: previously
  /// shown suggestions stay in place and up to [_kExpandStep] new items
  /// appear below them. Growth tops out at [_kMaxDisplay]; once that cap is
  /// hit (or the pool has nothing left to offer), `canLoadMore` flips to
  /// false and the widget hides the button.
  ///
  /// No network call: we slice deeper into the same 20-item fetch.
  void expandVisible() {
    if (!state.canLoadMore) return;
    _displayCount = (_displayCount + _kExpandStep).clamp(
      _kInitialDisplay,
      _kMaxDisplay,
    );
    _recomputeVisible();
  }
}

/// Provider for list suggestions, keyed by listId
final listSuggestionsProvider =
    StateNotifierProvider.family<
      ListSuggestionsNotifier,
      ListSuggestionsState,
      String
    >((ref, listId) {
      final searchApi = ref.watch(searchApiProvider);
      final cache = ref.watch(listSuggestionsCacheProvider);
      return ListSuggestionsNotifier(
        listId: listId,
        searchApi: searchApi,
        cache: cache,
        ref: ref,
      );
    });

// ── PROD-2004 follow-up: search-location resolution ────────────────────

/// Triple of params passed to `searchPlaces` from the suggestions provider.
/// `country` is null when the home scope is unset or doesn't carry an ISO
/// code (the GPS-fallback case).
@immutable
class SuggestionsSearchLocation {
  final double? latitude;
  final double? longitude;
  final String? country;

  const SuggestionsSearchLocation({
    this.latitude,
    this.longitude,
    this.country,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SuggestionsSearchLocation &&
        other.latitude == latitude &&
        other.longitude == longitude &&
        other.country == country;
  }

  @override
  int get hashCode => Object.hash(latitude, longitude, country);
}

/// Pure resolution of the search-location triple used by
/// [ListSuggestionsNotifier._resolveSearchLocation]. Extracted so the
/// priority + city-centroid logic is unit-testable without a real
/// Riverpod container.
///
/// Priority:
///   1. [cityScope] — explicit home pick. City centroid + ISO2.
///   2. [cityAutoScope] — profile/IP-derived. City centroid + ISO2 when
///      coords are present, otherwise country-only.
///   3. [lastLocation] — device GPS/IP. Raw coords, no country.
@visibleForTesting
SuggestionsSearchLocation resolveSuggestionsSearchLocation({
  required SearchScope? cityScope,
  required SearchScope? cityAutoScope,
  required LocationSnapshot? lastLocation,
}) {
  final home = cityScope ?? cityAutoScope;
  if (home is SearchScopeCountryCity && home.city.hasCoordinates) {
    return SuggestionsSearchLocation(
      latitude: home.city.latitude,
      longitude: home.city.longitude,
      country: home.iso2,
    );
  }
  // A map-picked area anchors on its own center (PROD-3181) rather than
  // falling through to raw GPS. `country` comes from the seeded city when the
  // backend supplied one.
  if (home is SearchScopeArea) {
    return SuggestionsSearchLocation(
      latitude: home.centerLat,
      longitude: home.centerLng,
      country: home.city?.countryCode,
    );
  }
  if (home is SearchScopeCountry) {
    return SuggestionsSearchLocation(country: home.iso2);
  }
  // SearchScopeCountryCity without coords — fall through to GPS rather
  // than send a half-set location.
  return SuggestionsSearchLocation(
    latitude: lastLocation?.lat,
    longitude: lastLocation?.lon,
  );
}

/// Canonical-resolution counterpart of [resolveSuggestionsSearchLocation].
/// Production callers consume the shared resolver; the legacy helper remains
/// to preserve focused unit coverage of scope persistence and migration.
@visibleForTesting
SuggestionsSearchLocation resolveSuggestionsSearchLocationFromResolved({
  required ResolvedSearchLocation resolved,
  required LocationSnapshot? lastLocation,
}) {
  if (resolved.hasCenter) {
    return SuggestionsSearchLocation(
      latitude: resolved.centerLat,
      longitude: resolved.centerLon,
      country: resolved.countryCode,
    );
  }
  if (resolved.countryCode != null) {
    return SuggestionsSearchLocation(country: resolved.countryCode);
  }
  return SuggestionsSearchLocation(
    latitude: lastLocation?.lat,
    longitude: lastLocation?.lon,
  );
}

/// Cache key for the canonical search location. Include the area center as
/// well as city id: two neighbourhood picks can share a seeded city while
/// correctly producing different nearby suggestions.
@visibleForTesting
String suggestionsResolvedLocationCacheKey(ResolvedSearchLocation resolved) =>
    'r:${resolved.origin.name}:${resolved.boundaryId ?? '-'}:'
    '${resolved.cityId ?? '-'}:${resolved.centerLat ?? '-'},'
    '${resolved.centerLon ?? '-'}:${resolved.radiusMeters ?? '-'}:'
    '${resolved.countryCode ?? '-'}';

/// Cache fingerprint for a [SearchScope]. Identical scopes produce
/// identical keys; switching from Lisbon → Porto produces different
/// keys so the cache lookup misses and a fresh fetch fires.
@visibleForTesting
String suggestionsScopeCacheKey(SearchScope? scope) {
  return switch (scope) {
    SearchScopeCountryCity s => 'c:${s.iso2}:${s.city.id}',
    SearchScopeCountry s => 'co:${s.iso2}',
    // Always key on center+radius (a boundary id alone can't distinguish two
    // area picks); include the id when present for readability. Include the
    // seeded city id too: it changes the request's `country`, so a null-city
    // entry must not be reused after the area resolves a city (PROD-3181).
    SearchScopeArea s =>
      'a:${s.boundaryId ?? 'pt'}:${s.centerLat},${s.centerLng}:${s.radiusMeters}:${s.city?.id ?? '-'}',
    null => 'gps',
  };
}
