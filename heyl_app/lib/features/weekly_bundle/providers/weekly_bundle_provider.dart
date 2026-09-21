import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/utils/backoff_poller.dart';
import '../../../data/datasources/api/weekly_bundle_api.dart';
import '../../../data/models/weekly_bundle.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../data/models/resolved_search_location.dart';
import '../../../providers/resolved_search_location_provider.dart';

/// State for the Weekly Bundle feature.
class WeeklyBundleState {
  final WeeklyBundle? bundle;
  final bool isGenerating;
  final bool isReady;
  final bool hasError;
  final String? errorMessage;
  final bool hasBeenSeen;

  /// PROD-2036 / PROD-2045 — BE reports the resolved city is outside the
  /// supported launch markets (`status == unsupported_city`). The FE
  /// skips polling and renders the explanatory CTA card.
  final bool isUnsupportedCity;

  const WeeklyBundleState({
    this.bundle,
    this.isGenerating = false,
    this.isReady = false,
    this.hasError = false,
    this.errorMessage,
    this.hasBeenSeen = false,
    this.isUnsupportedCity = false,
  });

  WeeklyBundleState copyWith({
    WeeklyBundle? bundle,
    bool? isGenerating,
    bool? isReady,
    bool? hasError,
    String? errorMessage,
    bool? hasBeenSeen,
    bool? isUnsupportedCity,
  }) {
    return WeeklyBundleState(
      bundle: bundle ?? this.bundle,
      isGenerating: isGenerating ?? this.isGenerating,
      isReady: isReady ?? this.isReady,
      hasError: hasError ?? this.hasError,
      errorMessage: errorMessage ?? this.errorMessage,
      hasBeenSeen: hasBeenSeen ?? this.hasBeenSeen,
      isUnsupportedCity: isUnsupportedCity ?? this.isUnsupportedCity,
    );
  }
}

/// Notifier that manages the weekly bundle lifecycle.
/// PROD-4531 — one location resolution: the REQUEST args and the analytics
/// facets, side by side. The weekly mirror of `_DropLocation`.
///
/// ⚠️ **Two shapes in one record, deliberately.** [cityId] / [lat] / [lon] are
/// what the bundle call sends and stay **mutually exclusive**, because that
/// exclusion is the `/feed/highlighted` contract the backend reads — widening
/// it would change what every request asks for. [originName] / [centerLat] /
/// [centerLon] are what `unsupported_city_impression` reports and are **never
/// exclusive**: a row wants everything that was known.
///
/// That difference is the whole of PROD-4531 §4. The event inherited the
/// request's exclusion, so every reader whose city resolved — the common case —
/// produced an expansion-pressure row carrying no coordinates at all.
typedef _BundleLocation = ({
  String? cityId,
  double? lat,
  double? lon,
  String? source,
  String? originName,
  double? centerLat,
  double? centerLon,
});

class WeeklyBundleNotifier extends StateNotifier<WeeklyBundleState> {
  final WeeklyBundleApi _api;
  final Ref _ref;
  final BackoffPoller _poller = BackoffPoller();
  bool _unsupportedCityImpressionLogged = false;

  /// PROD-2654 — generation guard. Bumped on every [initialize] / [reset];
  /// each async fetch captures it at the start and discards its `state =`
  /// write if a newer reset/init has since bumped it. Stops a stale bundle
  /// for account A from landing after a switch to account B.
  int _epoch = 0;

  WeeklyBundleNotifier({required WeeklyBundleApi api, required Ref ref})
    : _api = api,
      _ref = ref,
      super(const WeeklyBundleState());

  /// Resolves the structured location signals sent on every bundle call
  /// (PROD-2045), plus the facets the impression reports (PROD-4531). Mirrors
  /// [DailyDropNotifier]'s resolver — see [_BundleLocation] for why the record
  /// carries two shapes.
  Future<_BundleLocation> _resolveLocationArgs() async {
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
    } catch (_) {}
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
  /// a new facet reaches both call sites at once instead of being added to one.
  void _logUnsupportedCityImpressionOnce(_BundleLocation location) {
    if (_unsupportedCityImpressionLogged) return;
    _unsupportedCityImpressionLogged = true;
    _ref
        .read(unifiedAnalyticsProvider)
        .trackUnsupportedCityImpression(
          surface: 'weekly',
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
  /// PROD-2036 / PROD-2045 — `status: "unsupported_city"` hides the
  /// section; no polling fires.
  Future<void> initialize() async {
    final myEpoch = ++_epoch; // PROD-2654 — supersede any in-flight fetch
    _stopPolling();
    state = const WeeklyBundleState();
    try {
      final loc = await _resolveLocationArgs();
      if (myEpoch != _epoch) return; // account/city changed → abandon
      final bundle = await _api.getWeeklyBundle(
        cityId: loc.cityId,
        latitude: loc.lat,
        longitude: loc.lon,
        locationSource: loc.source,
      );
      if (myEpoch != _epoch) return; // stale response → discard

      if (bundle.isUnsupportedCity) {
        state = const WeeklyBundleState(isUnsupportedCity: true);
        _logUnsupportedCityImpressionOnce(loc);
        return;
      }

      if (bundle.hasBundle) {
        if (bundle.isReady) {
          state = WeeklyBundleState(bundle: bundle, isReady: true);
          return;
        }
        // Bundle exists but not ready — poll
        state = WeeklyBundleState(bundle: bundle, isGenerating: true);
        _startPolling(loc);
        return;
      }

      // PROD-1949: no bundle for this week. Do NOT request on-demand
      // generation — the weekly cron is the only generator. Reuse the
      // hasError branch so the section collapses (no error message is
      // surfaced to the user; see WeeklyBundleSection._buildBody).
      state = const WeeklyBundleState(hasError: true);
    } catch (e) {
      if (myEpoch != _epoch) return; // stale failure → discard
      state = WeeklyBundleState(hasError: true, errorMessage: e.toString());
    }
  }

  /// Poll GET /weekly-bundle via [BackoffPoller] (1s/2s/3s backoff, then
  /// 5s steady, capped at 2 min).
  void _startPolling(_BundleLocation loc) {
    final pollEpoch = _epoch; // PROD-2654 — tie poll writes to this generation
    _poller.start(
      poll: () async {
        final bundle = await _api.getWeeklyBundle(
          cityId: loc.cityId,
          latitude: loc.lat,
          longitude: loc.lon,
          locationSource: loc.source,
        );
        if (pollEpoch != _epoch) return true; // superseded → stop, drop result
        if (bundle.isUnsupportedCity) {
          state = const WeeklyBundleState(isUnsupportedCity: true);
          _logUnsupportedCityImpressionOnce(loc);
          return true;
        }
        if (bundle.hasBundle && bundle.isReady) {
          state = WeeklyBundleState(bundle: bundle, isReady: true);
          return true;
        }
        if (bundle.hasBundle && bundle.status == 'failed') {
          state = WeeklyBundleState(bundle: bundle, isReady: true);
          return true;
        }
        if (bundle.hasBundle) {
          state = state.copyWith(bundle: bundle);
        }
        return false;
      },
      onTimeout: () {
        state = state.copyWith(isGenerating: false, hasError: true);
      },
    );
  }

  void _stopPolling() => _poller.stop();

  /// PROD-2654 — clear all per-account state (used on logout / account
  /// switch). Bumps the epoch so any in-flight fetch is discarded, stops the
  /// poller, and resets to pristine. Runs synchronously.
  void reset() {
    _epoch++;
    _stopPolling();
    _unsupportedCityImpressionLogged = false;
    state = const WeeklyBundleState();
  }

  Future<void> refresh() async {
    final myEpoch = _epoch; // PROD-2654 — discard if account changes mid-flight
    try {
      final bundle = await _api.getWeeklyBundle();
      if (myEpoch != _epoch) return; // stale response → discard
      if (bundle.hasBundle) {
        state = WeeklyBundleState(bundle: bundle, isReady: true);
      }
    } catch (_) {}
  }

  void markSeen() {
    if (!state.hasBeenSeen) {
      state = state.copyWith(hasBeenSeen: true);
    }
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}

/// Global provider for the weekly bundle feature.
///
/// PROD-2045 — re-fetches when the resolved Discovery city changes. The
/// first emission is skipped because the section's `initState` triggers
/// the initial init.
final weeklyBundleProvider =
    StateNotifierProvider<WeeklyBundleNotifier, WeeklyBundleState>((ref) {
      final api = ref.watch(weeklyBundleApiProvider);
      final notifier = WeeklyBundleNotifier(api: api, ref: ref);
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
      // PROD-2654 — reset on logout / account switch (see daily_drop_provider
      // for the no-`primed` rationale). `reset()` clears synchronously on
      // logout; `initialize()` re-fetches (epoch-guarded) on login/switch.
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
      return notifier;
    });
