import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/impression_scroll_tracker.dart';
import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import 'near_you_context_provider.dart';

/// State for the "Near you" places shelf (PT-PT: "Perto de ti",
/// PT-BR: "Perto de você") — proximity-ordered venue cards from
/// `/feed/near-you/places` (PROD-1963). Pagination is append-only so the
/// user's horizontal-scroll position survives the trailing see-more press.
///
/// PROD-1999 follow-up: routes through [nearYouContextProvider] so the
/// shelf reflects the city picker. See [happeningShelfProvider] for the
/// twin rationale — same picker-vs-GPS resolution applies here.
@immutable
class NearYouPlacesShelfState {
  final List<NearYouVenueItem> items;
  final int total;
  final bool isInitialLoading;
  final bool isLoadingMore;
  final Object? error;

  /// Whether the shelf has a resolved coord to render against. The shelf
  /// hides when this is false (no GPS, no IP fallback, no picker pick yet).
  final bool hasLocation;

  /// Venues seen-suppression hid this load within 250 m of the coord —
  /// `dropped.within_250m`. Drives the button's count LINE (hidden when 0). 0
  /// while unpersonalized (nothing is being hidden) or when the BE omits stats.
  final int hiddenCount;

  /// Total venues seen-suppression hid this load, any distance —
  /// `dropped.total`. Drives whether the button SHOWS AT ALL. Preserved
  /// across the toggle.
  final int hiddenTotal;

  /// Whether the shelf is showing the normal filtered feed (true) or the
  /// raw unfiltered "show everything" feed (false). The button reads its
  /// active state off this, not [hiddenCount].
  final bool personalized;

  /// A toggle re-fetch is in flight for a mode not yet cached. The current
  /// cards stay on screen (no skeleton wipe); only the button dims.
  final bool isToggling;

  const NearYouPlacesShelfState({
    this.items = const [],
    this.total = 0,
    this.isInitialLoading = true,
    this.isLoadingMore = false,
    this.error,
    this.hasLocation = false,
    this.hiddenCount = 0,
    this.hiddenTotal = 0,
    this.personalized = true,
    this.isToggling = false,
  });

  bool get hasMore => items.length < total;

  NearYouPlacesShelfState copyWith({
    List<NearYouVenueItem>? items,
    int? total,
    bool? isInitialLoading,
    bool? isLoadingMore,
    Object? error,
    bool clearError = false,
    bool? hasLocation,
    int? hiddenCount,
    int? hiddenTotal,
    bool? personalized,
    bool? isToggling,
  }) {
    return NearYouPlacesShelfState(
      items: items ?? this.items,
      total: total ?? this.total,
      isInitialLoading: isInitialLoading ?? this.isInitialLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: clearError ? null : (error ?? this.error),
      hasLocation: hasLocation ?? this.hasLocation,
      hiddenCount: hiddenCount ?? this.hiddenCount,
      hiddenTotal: hiddenTotal ?? this.hiddenTotal,
      personalized: personalized ?? this.personalized,
      isToggling: isToggling ?? this.isToggling,
    );
  }
}

const int _kPageSize = 10;

/// A fetched feed page kept per personalize-mode so toggling the "show
/// hidden" button re-shows an already-retrieved feed without a network call.
/// The two modes overlap heavily by design; each is cached independently.
class _PlacesFeedCache {
  final List<NearYouVenueItem> items;
  final int total;
  final int hiddenCount;
  final int hiddenTotal;
  final String? seed;
  final DateTime? snapshotAt;

  const _PlacesFeedCache({
    required this.items,
    required this.total,
    required this.hiddenCount,
    required this.hiddenTotal,
    required this.seed,
    required this.snapshotAt,
  });
}

class NearYouPlacesShelfNotifier
    extends StateNotifier<NearYouPlacesShelfState> {
  final Ref _ref;

  /// PROD-2654 — generation guard. Bumped on every [refresh] / [clear]; each
  /// async fetch captures it and discards its `state =` write if superseded.
  int _epoch = 0;

  /// Per-mode feed cache (`personalized` → page). Populated on each network
  /// fetch, read on toggle to avoid a round-trip, and cleared whenever the
  /// feed context changes ([refresh]) or on logout ([clear]).
  final Map<bool, _PlacesFeedCache> _cache = {};

  /// Shared, surface-agnostic impression + per-scroll seen-suppression
  /// bookkeeping. Owns the dedup set and the seed/snapshot passed to the feed.
  late final ImpressionScrollTracker _tracker = ImpressionScrollTracker(
    _ref,
    itemType: 'venue',
    shelfId: 'near_you_places',
  );

  /// Called by ImpressionDetector when a card crosses 70% visible (after dwell).
  void recordImpression(String id, {required int cardIndex}) =>
      _tracker.record(id, cardIndex: cardIndex);

  /// Surface identity for this shelf's `ImpressionDetector` keys. Read from
  /// the tracker rather than re-typed at the widget, so the detector key and
  /// the tracker's dedup gate cannot drift apart.
  String get impressionScopeId => _tracker.scopeId;

  NearYouPlacesShelfNotifier(this._ref)
    : super(const NearYouPlacesShelfState()) {
    refresh();
  }

  /// Pull-to-refresh / context-change / login entry point. Invalidates the
  /// per-mode cache (the feed context changed) and always resets to the
  /// personalized (filtered) feed — a fresh scroll starts filtered.
  Future<void> refresh() {
    _cache.clear();
    return _fetch(personalized: true);
  }

  /// Toggle the "show hidden" escape hatch. When the target mode is already
  /// cached (fetched earlier this context), re-show it instantly — no network
  /// call. Otherwise fetch it. Either way the horizontal scroll resets to the
  /// start of that mode's list.
  Future<void> togglePersonalized() {
    final target = !state.personalized;
    final cached = _cache[target];
    if (cached != null) {
      _restoreFromCache(personalized: target, cache: cached);
      return Future.value();
    }
    return _fetch(personalized: target, keepItems: true);
  }

  /// Re-show an already-fetched feed page without hitting the network. Adopts
  /// that scroll's seed so later pagination continues correctly, and bumps
  /// the epoch so any in-flight fetch can't clobber the restored state.
  void _restoreFromCache({
    required bool personalized,
    required _PlacesFeedCache cache,
  }) {
    _tracker.restoreScroll(cache.seed, cache.snapshotAt);
    _epoch++;
    state = NearYouPlacesShelfState(
      items: cache.items,
      total: cache.total,
      isInitialLoading: false,
      hasLocation: true,
      hiddenCount: cache.hiddenCount,
      hiddenTotal: cache.hiddenTotal,
      personalized: personalized,
    );
  }

  Future<void> _fetch({
    required bool personalized,
    bool keepItems = false,
  }) async {
    _tracker.startScroll();
    final myEpoch = ++_epoch; // PROD-2654 — supersede any in-flight fetch
    final context = await _ref.read(nearYouContextProvider.future);
    if (myEpoch != _epoch) return; // superseded → discard
    if (context == null) {
      state = state.copyWith(
        isInitialLoading: false,
        isToggling: false,
        hasLocation: false,
        items: [],
        total: 0,
        hiddenCount: 0,
        hiddenTotal: 0,
        personalized: personalized,
        clearError: true,
      );
      return;
    }
    // PROD-2878 — while the resolver is waiting for a precise fix (coarse
    // GPS + auto picker case), skip the feed request and hold the shelf in
    // its loading skeleton. `ref.listen(nearYouContextProvider, ...)` in the
    // notifier registration below re-fires `refresh()` when the context
    // transitions out of `awaitingPreciseFix` (precise fix arrives, or 15-s
    // timeout expires and the resolver falls through to picker centroid).
    if (context.awaitingPreciseFix) {
      state = state.copyWith(
        isInitialLoading: true,
        hasLocation: true,
        clearError: true,
      );
      return;
    }
    // `keepItems` (a toggle to an uncached mode) keeps the current cards on
    // screen and only dims the button; a cold load shows skeletons.
    state = keepItems
        ? state.copyWith(isToggling: true, clearError: true)
        : state.copyWith(isInitialLoading: true, clearError: true);
    try {
      logNearYouRequest(
        endpoint: '/feed/near-you/places',
        context: context,
        limit: _kPageSize,
        offset: 0,
      );
      final response = await _ref
          .read(feedApiProvider)
          .getNearYouPlacesFeed(
            latitude: context.latitude,
            longitude: context.longitude,
            limit: _kPageSize,
            offset: 0,
            seed: _tracker.seed,
            snapshotAt: _tracker.snapshotAt,
            // null → omit the param so the BE default (true) applies;
            // false → the raw unfiltered feed.
            personalize: personalized ? null : false,
          );
      if (myEpoch != _epoch) return; // stale response → discard
      // While showing the raw feed, the `dropped` stats are meaningless
      // (suppression is off — the BE reports 0/none), so preserve the last
      // personalized count. Only a personalized load updates it.
      final hidden = personalized
          ? (response.dropped?.within250m ?? state.hiddenCount)
          : state.hiddenCount;
      final hiddenTotal = personalized
          ? (response.dropped?.total ?? state.hiddenTotal)
          : state.hiddenTotal;
      _cache[personalized] = _PlacesFeedCache(
        items: response.items,
        total: response.total,
        hiddenCount: hidden,
        hiddenTotal: hiddenTotal,
        seed: _tracker.seed,
        snapshotAt: _tracker.snapshotAt,
      );
      state = NearYouPlacesShelfState(
        items: response.items,
        total: response.total,
        isInitialLoading: false,
        hasLocation: true,
        hiddenCount: hidden,
        hiddenTotal: hiddenTotal,
        personalized: personalized,
      );
    } catch (e) {
      if (myEpoch != _epoch) return; // stale failure → discard
      state = state.copyWith(
        isInitialLoading: false,
        isToggling: false,
        error: e,
        hasLocation: true,
      );
    }
  }

  /// PROD-2654 — clear synchronously on logout / account switch so guest
  /// discovery never renders the previous account's items. See
  /// [HappeningShelfNotifier.clear] for the twin rationale.
  void clear() {
    _tracker.reset();
    _cache.clear();
    _epoch++;
    state = const NearYouPlacesShelfState(isInitialLoading: false);
  }

  Future<void> loadMore() async {
    if (state.isLoadingMore || !state.hasMore) return;
    final myEpoch = _epoch; // PROD-2654 — discard append if superseded
    final context = await _ref.read(nearYouContextProvider.future);
    if (myEpoch != _epoch) return;
    if (context == null) return;
    // PROD-2878 — resolver in awaiting state means the initial page has
    // not been fetched yet; `loadMore` should not fire a second request.
    if (context.awaitingPreciseFix) return;
    state = state.copyWith(isLoadingMore: true, clearError: true);
    try {
      logNearYouRequest(
        endpoint: '/feed/near-you/places',
        context: context,
        limit: _kPageSize,
        offset: state.items.length,
      );
      final response = await _ref
          .read(feedApiProvider)
          .getNearYouPlacesFeed(
            latitude: context.latitude,
            longitude: context.longitude,
            limit: _kPageSize,
            offset: state.items.length,
            seed: _tracker.seed,
            snapshotAt: _tracker.snapshotAt,
            // Keep the current mode across pagination.
            personalize: state.personalized ? null : false,
          );
      if (myEpoch != _epoch) return; // stale response → discard
      final newItems = [...state.items, ...response.items];
      // Keep this mode's cache in sync so a later toggle back restores the
      // paginated list, not just page 0.
      _cache[state.personalized] = _PlacesFeedCache(
        items: newItems,
        total: response.total,
        hiddenCount: state.hiddenCount,
        hiddenTotal: state.hiddenTotal,
        seed: _tracker.seed,
        snapshotAt: _tracker.snapshotAt,
      );
      state = state.copyWith(
        items: newItems,
        total: response.total,
        isLoadingMore: false,
      );
    } catch (e) {
      if (myEpoch != _epoch) return; // stale failure → discard
      state = state.copyWith(isLoadingMore: false, error: e);
    }
  }
}

final nearYouPlacesShelfProvider =
    StateNotifierProvider.autoDispose<
      NearYouPlacesShelfNotifier,
      NearYouPlacesShelfState
    >((ref) {
      // PROD-2221 — outlive the per-page consumer. Same rationale as
      // `trendingShelfProvider` / `happeningShelfProvider`: idle Discovery
      // and the search overlay's `DefaultContentSection` both watch this,
      // and the brief refCount=0 window during the overlay-open transition
      // would otherwise dispose the notifier and lose loaded state.
      ref.keepAlive();
      final notifier = NearYouPlacesShelfNotifier(ref);
      ref.listen(nearYouContextProvider, (prev, next) {
        if (prev?.value == next.value) return;
        notifier.refresh();
      });
      // PROD-2654 — keepAlive() survives logout; reset on account change.
      // `clear()` removes A's items synchronously on logout; refresh()
      // re-fetches on login/switch.
      ref.listen<String?>(authStateProvider.select((s) => s.user?.id), (
        prev,
        next,
      ) {
        if (prev == next) return;
        if (next == null) {
          notifier.clear();
        } else {
          notifier.refresh();
        }
      });
      return notifier;
    });
