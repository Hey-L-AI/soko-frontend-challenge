import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/utils/backoff_poller.dart';
import '../../../data/datasources/api/daily_drop_api.dart';
import '../../../data/models/daily_drop.dart';
import '../../../data/models/resolved_search_location.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';
import '../../user_profiling/providers/user_profiling_gate_provider.dart';

/// State for the Daily Drop feature.
class DailyDropState {
  final DailyDrop? drop;
  final bool isGenerating;
  final bool isReady;
  final bool hasError;
  final String? errorMessage;

  /// PROD-1988 — BE reports the user is in the new-user profiling window
  /// (`status == cta_profiling`). The FE skips polling and renders the
  /// profiling CTA card in place of the daily drop.
  final bool isCtaProfiling;

  /// PROD-2036 / PROD-2045 — BE reports the resolved city is outside the
  /// supported launch markets (`status == unsupported_city`). The FE
  /// skips polling and renders the explanatory CTA card.
  final bool isUnsupportedCity;

  /// PROD-3730 — the poller reached its 2-minute cap without the drop
  /// appearing. Deliberately **not** [hasError]: a transient request
  /// failure is silent (the drop is optional and the section collapses),
  /// but giving up after two minutes of visibly "picking your drop" is a
  /// final outcome the user watched happen, so it gets its own surface.
  ///
  /// The cap coincides with Celery's `soft_time_limit`, so a task that ran
  /// this long has almost certainly produced nothing.
  final bool hasTimedOut;

  const DailyDropState({
    this.drop,
    this.isGenerating = false,
    this.isReady = false,
    this.hasError = false,
    this.errorMessage,
    this.isCtaProfiling = false,
    this.isUnsupportedCity = false,
    this.hasTimedOut = false,
  });

  DailyDropState copyWith({
    DailyDrop? drop,
    bool? isGenerating,
    bool? isReady,
    bool? hasError,
    String? errorMessage,
    bool? isCtaProfiling,
    bool? isUnsupportedCity,
    bool? hasTimedOut,
  }) {
    return DailyDropState(
      drop: drop ?? this.drop,
      isGenerating: isGenerating ?? this.isGenerating,
      isReady: isReady ?? this.isReady,
      hasError: hasError ?? this.hasError,
      errorMessage: errorMessage ?? this.errorMessage,
      isCtaProfiling: isCtaProfiling ?? this.isCtaProfiling,
      isUnsupportedCity: isUnsupportedCity ?? this.isUnsupportedCity,
      hasTimedOut: hasTimedOut ?? this.hasTimedOut,
    );
  }

  /// True when nothing has resolved yet — no fetch has landed and no
  /// terminal outcome has been reached. Callers use this to decide whether
  /// an [DailyDropNotifier.initialize] is still owed.
  bool get isPristine =>
      !isReady &&
      !isGenerating &&
      !isUnsupportedCity &&
      !isCtaProfiling &&
      !hasError &&
      !hasTimedOut &&
      drop == null;
}

/// Notifier that manages the daily drop lifecycle:
/// check → request generation → poll → ready.
/// PROD-4531 — one location resolution: the REQUEST args and the analytics
/// facets, side by side.
///
/// ⚠️ **Two shapes in one record, deliberately.** [cityId] / [lat] / [lon] are
/// what the recommendation call sends and stay **mutually exclusive**, because
/// that exclusion is the `/feed/highlighted` contract the backend reads —
/// widening it would change what every request asks for. [originName] /
/// [centerLat] / [centerLon] are what `unsupported_city_impression` reports and
/// are **never exclusive**: a row wants everything that was known.
///
/// That difference is the whole of PROD-4531 §4. The event inherited the
/// request's exclusion, so every reader whose city resolved — the common case —
/// produced an expansion-pressure row carrying no coordinates at all, and the
/// map of where demand comes from was built from the minority who had none.
typedef _DropLocation = ({
  String? cityId,
  double? lat,
  double? lon,
  String? source,
  String? originName,
  double? centerLat,
  double? centerLon,
});

class DailyDropNotifier extends StateNotifier<DailyDropState> {
  final DailyDropApi _api;
  final Ref _ref;
  final BackoffPoller _poller = BackoffPoller();
  bool _unsupportedCityImpressionLogged = false;

  /// PROD-2654 — generation guard. Bumped on every [initialize] / [reset].
  /// Each async fetch captures the epoch at the start and drops its
  /// `state =` write if a newer reset/init has since bumped it. This is what
  /// stops a slow request for account A from writing A's drop into the
  /// notifier after the user has switched to account B (the bug), and also
  /// kills the double-fetch window (a second `initialize()` supersedes the
  /// first) and the city-switch race.
  int _epoch = 0;

  DailyDropNotifier({required DailyDropApi api, required Ref ref})
    : _api = api,
      _ref = ref,
      super(const DailyDropState());

  /// Resolves the structured location signals sent on every recommendation
  /// call (PROD-2045), plus the facets the impression event reports
  /// (PROD-4531). Mirrors the `/feed/highlighted` contract:
  /// `city_id` from the picker wins; otherwise picker-derived coords;
  /// otherwise nothing (BE falls back to `user.current_location.city`).
  ///
  /// ⚠️ **Two shapes in one record, deliberately.** `cityId` / `lat` / `lon`
  /// are the REQUEST args and stay mutually exclusive, because that exclusion
  /// is the contract the backend reads — changing it would change what every
  /// recommendation call asks for. `originName` / `centerLat` / `centerLon`
  /// are for the impression event and are never exclusive: a row wants
  /// everything that was known. That difference is the whole of PROD-4531 §4 —
  /// the event inherited the request's exclusion, so every reader whose city
  /// resolved (the common case) produced an expansion-pressure row with no
  /// coordinates at all.
  Future<_DropLocation> _resolveLocationArgs() async {
    try {
      final resolved = await _ref.read(resolvedSearchLocationProvider.future);
      final origin = resolved.origin.wire;
      final coords = resolved.center;
      final cityId = resolved.cityId;
      if (cityId != null) {
        return (
          cityId: cityId,
          lat: null,
          lon: null,
          source: 'picker',
          originName: origin,
          centerLat: coords?.lat,
          centerLon: coords?.lon,
        );
      }
      if (coords != null) {
        return (
          cityId: null,
          lat: coords.lat,
          lon: coords.lon,
          source: 'picker',
          originName: origin,
          centerLat: coords.lat,
          centerLon: coords.lon,
        );
      }
      // Nothing resolved to send, but WHICH cascade produced the nothing is
      // still worth a row.
      return (
        cityId: null,
        lat: null,
        lon: null,
        source: null,
        originName: origin,
        centerLat: null,
        centerLon: null,
      );
    } catch (_) {
      // Don't block the drop call on a transient picker-resolution error;
      // BE falls back to the stored location.
    }
    return (
      cityId: null,
      lat: null,
      lon: null,
      source: null,
      originName: null,
      centerLat: null,
      centerLon: null,
    );
  }

  /// PROD-4531 — takes the whole resolution rather than three loose values, so
  /// a new facet reaches all three call sites at once instead of being added to
  /// two of them.
  void _logUnsupportedCityImpressionOnce({
    required String surface,
    required _DropLocation location,
  }) {
    if (_unsupportedCityImpressionLogged) return;
    _unsupportedCityImpressionLogged = true;
    _ref
        .read(unifiedAnalyticsProvider)
        .trackUnsupportedCityImpression(
          surface: surface,
          cityId: location.cityId,
          latitude: location.centerLat,
          longitude: location.centerLon,
          locationSource: location.originName,
        );
  }

  /// Called on app launch and on every Discovery-city change (PROD-2045).
  /// Always safe to invoke — any in-flight poller is stopped and state is
  /// reset before the fresh fetch runs.
  ///
  /// PROD-1570: cover_image_url is delivered alongside the recommendation
  /// (no separate Gemini poster step), so once `hasRecommendation` is true
  /// the drop is ready to display — no poster polling required.
  ///
  /// PROD-1988: when the request endpoint returns `cta_profiling`, the
  /// user is in the new-user profiling window — short-circuit the polling
  /// loop and surface the profiling CTA card instead.
  ///
  /// PROD-2036 / PROD-2045: when either the GET response carries
  /// `status: "unsupported_city"` or the POST returns the same status,
  /// short-circuit the polling loop and hide the section.
  Future<void> initialize() async {
    final myEpoch = ++_epoch; // PROD-2654 — supersede any in-flight fetch
    _stopPolling();
    state = const DailyDropState();
    try {
      final loc = await _resolveLocationArgs();
      if (myEpoch != _epoch) return; // account/city changed → abandon
      final drop = await _api.getDailyDrop(
        cityId: loc.cityId,
        latitude: loc.lat,
        longitude: loc.lon,
        locationSource: loc.source,
      );
      if (myEpoch != _epoch) return; // stale response → discard

      if (drop.hasRecommendation) {
        state = DailyDropState(drop: drop, isReady: true);
        return;
      }

      if (drop.isUnsupportedCity) {
        state = const DailyDropState(isUnsupportedCity: true);
        _logUnsupportedCityImpressionOnce(surface: 'daily', location: loc);
        return;
      }

      if (drop.isCtaProfiling) {
        // PROD-1988 — short-circuit on the GET. The OpenAPI contract is
        // explicit that POST `/daily/request` would refuse to enqueue
        // with the same status, so calling it would just waste a
        // round-trip and leave the section flashing `isGenerating`
        // while we wait.
        //
        // …unless the FE already knows profiling is complete (local
        // gate set after submit / skip). In that race the BE write
        // hasn't propagated to the recommendation read path yet —
        // showing the CTA would loop the user back into the flow they
        // just finished. Treat it as transient and start polling; GET
        // will keep returning until BE catches up.
        if (_ref.read(hasFinishedUserProfilingLocallyProvider)) {
          state = const DailyDropState(isGenerating: true);
          _startPolling(loc);
          return;
        }
        state = const DailyDropState(isCtaProfiling: true);
        return;
      }

      // PROD-3730 — a task is already in flight for today (BE sets a Redis
      // pending marker on enqueue and reports it here). POSTing again would
      // start a SECOND full generation: the POST handler doesn't check the
      // marker and the Celery task has no singleton lock. Poll instead.
      if (drop.isGenerating) {
        state = const DailyDropState(isGenerating: true);
        _startPolling(loc);
        return;
      }

      // No daily yet — ask the BE what to do.
      state = const DailyDropState(isGenerating: true);
      final status = await _api.requestDailyDrop(
        cityId: loc.cityId,
        latitude: loc.lat,
        longitude: loc.lon,
        locationSource: loc.source,
      );
      if (myEpoch != _epoch) return; // stale response → discard

      switch (status) {
        case DailyDropRequestStatus.unsupportedCity:
          state = const DailyDropState(isUnsupportedCity: true);
          _logUnsupportedCityImpressionOnce(surface: 'daily', location: loc);
          return;
        case DailyDropRequestStatus.ctaProfiling:
          // Same race as the GET branch above: FE-finished + stale BE
          // → keep polling instead of surfacing the CTA.
          if (_ref.read(hasFinishedUserProfilingLocallyProvider)) {
            _startPolling(loc);
            return;
          }
          state = const DailyDropState(isCtaProfiling: true);
          return;
        case DailyDropRequestStatus.ready:
          // BE raced us — re-fetch to pick up the recommendation.
          final fresh = await _api.getDailyDrop(
            cityId: loc.cityId,
            latitude: loc.lat,
            longitude: loc.lon,
            locationSource: loc.source,
          );
          if (myEpoch != _epoch) return; // stale response → discard
          if (fresh.hasRecommendation) {
            state = DailyDropState(drop: fresh, isReady: true);
            return;
          }
          _startPolling(loc);
        case DailyDropRequestStatus.generating:
        case DailyDropRequestStatus.unknown:
          _startPolling(loc);
      }
    } catch (e) {
      if (myEpoch != _epoch) return; // stale failure → discard
      // Don't show errors to user — daily drop is optional
      state = DailyDropState(hasError: true, errorMessage: e.toString());
    }
  }

  /// Poll GET /daily via [BackoffPoller] (1s/2s/3s backoff, then 5s steady,
  /// capped at 2 min).
  void _startPolling(_DropLocation loc) {
    final pollEpoch = _epoch; // PROD-2654 — tie poll writes to this generation
    _poller.start(
      poll: () async {
        final drop = await _api.getDailyDrop(
          cityId: loc.cityId,
          latitude: loc.lat,
          longitude: loc.lon,
          locationSource: loc.source,
        );
        if (pollEpoch != _epoch) return true; // superseded → stop, drop result
        if (drop.hasRecommendation) {
          state = DailyDropState(drop: drop, isReady: true);
          return true;
        }
        if (drop.isUnsupportedCity) {
          state = const DailyDropState(isUnsupportedCity: true);
          _logUnsupportedCityImpressionOnce(surface: 'daily', location: loc);
          return true;
        }
        return false;
      },
      onTimeout: () {
        if (pollEpoch != _epoch) return; // superseded → don't write
        // PROD-3730 — distinct from `hasError`. See [DailyDropState.hasTimedOut].
        state = state.copyWith(isGenerating: false, hasTimedOut: true);
        _ref.read(unifiedAnalyticsProvider).trackDailyDropGenerationTimeout();
      },
    );
  }

  /// PROD-3730 — recovery after the app returns from the background.
  ///
  /// [BackoffPoller] is a plain Dart `Timer`. iOS suspends the VM on
  /// background and Android freezes cached processes, so a generation the
  /// user backgrounded comes back with nothing scheduled to move it — the
  /// notifier sits on `isGenerating` forever, and the card spins forever.
  /// Worse, if a suspended timer does fire late, `BackoffPoller` compares
  /// wall-clock elapsed against its 2-minute cap and reports a timeout for
  /// a drop that is very likely ready.
  ///
  /// GET-only on purpose: this must never re-enqueue generation (see the
  /// `drop.isGenerating` branch in [initialize]). A no-op unless we are
  /// actually mid-wait.
  Future<void> refreshAfterResume() async {
    if (!state.isGenerating && !state.hasTimedOut) return;
    final myEpoch = _epoch;
    try {
      final loc = await _resolveLocationArgs();
      if (myEpoch != _epoch) return;
      final drop = await _api.getDailyDrop(
        cityId: loc.cityId,
        latitude: loc.lat,
        longitude: loc.lon,
        locationSource: loc.source,
      );
      if (myEpoch != _epoch) return;

      if (drop.hasRecommendation) {
        _stopPolling();
        state = DailyDropState(drop: drop, isReady: true);
        return;
      }
      if (drop.isGenerating) {
        // Still working. Restart the poller from zero — the old one is
        // either dead or about to false-timeout on stale wall-clock.
        state = const DailyDropState(isGenerating: true);
        _startPolling(loc);
        return;
      }
      // `not_ready` with no marker: the task died without producing a row
      // and its 10-minute marker has expired. Surface the timeout state
      // rather than leaving the card spinning on nothing.
      _stopPolling();
      state = const DailyDropState(hasTimedOut: true);
    } catch (_) {
      // Transient failure on resume — leave the existing state alone and
      // let the poller (if any) carry on.
    }
  }

  void _stopPolling() => _poller.stop();

  /// PROD-2654 — clear all per-account state (used on logout / account
  /// switch). Bumps the epoch so any in-flight fetch is discarded, stops the
  /// poller, and resets to pristine so the next account never sees the
  /// previous account's drop. Runs synchronously (no await) so the clear
  /// lands before the next frame.
  void reset() {
    _epoch++;
    _stopPolling();
    _unsupportedCityImpressionLogged = false;
    state = const DailyDropState();
  }

  /// PROD-3730 — retry after [DailyDropState.hasTimedOut]. Not wired to any
  /// user-facing control today (Decision 15: the failure state offers no
  /// retry, because re-running costs a full LLM pipeline and a task that hit
  /// Celery's `soft_time_limit` will likely hit it again). Kept for the
  /// debug panel and for tests.
  Future<void> retryAfterTimeout() async {
    if (!state.hasTimedOut) return;
    await initialize();
  }

  /// Re-fetch the daily drop from the API (e.g. to get a fresh signed poster URL).
  Future<void> refresh() async {
    final myEpoch = _epoch; // PROD-2654 — discard if account changes mid-flight
    try {
      final drop = await _api.getDailyDrop();
      if (myEpoch != _epoch) return; // stale response → discard
      if (drop.hasRecommendation) {
        state = DailyDropState(drop: drop, isReady: true);
      }
    } catch (_) {
      // Silent failure — keep existing state
    }
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}

/// Global provider for the daily drop feature.
///
/// PROD-2045 — re-fetches when the resolved Discovery city changes
/// (picker pick or auto-scope resolution). The very first emission is
/// skipped because the section's `initState` triggers the initial init.
final dailyDropProvider = StateNotifierProvider<DailyDropNotifier, DailyDropState>((
  ref,
) {
  final api = ref.watch(dailyDropApiProvider);
  final notifier = DailyDropNotifier(api: api, ref: ref);
  String? lastCityId;
  bool primed = false;
  ref.listen(
    resolvedSearchLocationProvider.select(
      (value) => value.valueOrNull?.city?.id,
    ),
    (prev, newId) {
      if (!primed) {
        primed = true;
        lastCityId = newId;
        return;
      }
      if (lastCityId == newId) return;
      lastCityId = newId;
      notifier.initialize();
    },
  );
  // PROD-2654 — reset on logout / account switch so the daily drop is
  // partitioned by user. No `primed` guard: `ref.listen` on a synchronous
  // selector fires only on real changes (no initial emission to skip), so
  // a guard would swallow the first login/logout. `reset()` clears
  // synchronously on logout; `initialize()` re-fetches (epoch-guarded) on
  // login/switch.
  ref.listen<String?>(authStateProvider.select((s) => s.user?.id), (
    prev,
    next,
  ) {
    if (prev == next) return;
    if (next == null) {
      notifier.reset();
    } else {
      notifier.initialize();
    }
  });
  // Onboarding completion flips `onboarding_complete` on the SAME user id, so
  // the user-id listener above never fires for it — but the backend daily-drop
  // gate keys on that flag (it returns `cta_profiling` only while it's false).
  // Without a refetch, the pre-onboarding `cta_profiling` status stays cached
  // and the "Ainda não te conheço bem" profiling CTA lingers on Discovery
  // until an unrelated refresh. Re-fetch on the false→true transition so it
  // clears immediately. Covers the legacy V6 profiling submit too (same flag).
  ref.listen<bool>(
    authStateProvider.select((s) => s.user?.onboardingComplete ?? false),
    (prev, next) {
      if (next && prev == false) notifier.initialize();
    },
  );
  return notifier;
});
