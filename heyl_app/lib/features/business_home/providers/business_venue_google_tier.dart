import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/exceptions/api_exceptions.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../data/models/business_portal.dart';
import '../../../providers/api_provider.dart';

/// Where the "Find more" tier is in its lifecycle for one search context
/// (PROD-4270 S5). A context is (query, location, language); a change to any of
/// them resets to [idle] via [BusinessVenueGoogleTierNotifier.resetForContext].
enum GoogleTierPhase {
  /// Not yet run for this context — the "Find more" affordance is offered.
  idle,

  /// A Google search is in flight — the affordance is disabled and shows a
  /// spinner. Duplicate activation is blocked here.
  finding,

  /// A `complete` response landed — the attempt is spent for this context. Rows
  /// may be empty ("no additions"); either way "Find more" does not return.
  complete,

  /// A `partial` response landed (a thin Google payload). Its rows show, but the
  /// attempt is NOT spent — Retry stays available.
  partial,

  /// The search failed (provider unavailable or a generic error). Retry stays
  /// available; any rows from a prior success are kept.
  failed,

  /// Rate-limited (429). The affordance is disabled and explains the wait; it
  /// flips back to [idle] after `Retry-After` seconds so Retry becomes possible.
  cooldown,
}

/// Why a failed search failed, so the panel can distinguish "the provider is
/// down, try again" from a generic error (spec §4.4 — provider unavailable is
/// not the same as zero matches).
enum GoogleTierError { providerUnavailable, generic }

@immutable
class BusinessVenueGoogleTierState {
  const BusinessVenueGoogleTierState({
    this.phase = GoogleTierPhase.idle,
    this.rows = const [],
    this.errorKind,
    this.retryAfterSeconds,
    this.resolvingPlaceId,
  });

  final GoogleTierPhase phase;

  /// Google candidates deduped against the current local rows, in the order the
  /// backend returned them (spec: append in returned order, never sort).
  final List<PortalGoogleVenueCandidate> rows;

  /// Set only in [GoogleTierPhase.failed]; picks the failure copy.
  final GoogleTierError? errorKind;

  /// Set only in [GoogleTierPhase.cooldown]; seconds the caller must wait.
  final int? retryAfterSeconds;

  /// The `google_place_id` whose resolve is in flight, or null. Drives the
  /// row-level spinner and blocks a second concurrent resolve.
  final String? resolvingPlaceId;

  /// "Find more" is offered only from [idle].
  bool get canFindMore => phase == GoogleTierPhase.idle;

  /// A retry affordance replaces "Find more" after a non-spending outcome.
  /// NOT during [cooldown] — a rate-limited caller must wait out `Retry-After`
  /// (the affordance is disabled and explains the wait, [isCoolingDown]).
  bool get canRetry =>
      phase == GoogleTierPhase.partial || phase == GoogleTierPhase.failed;

  /// Rate-limited: the affordance is disabled and explains the wait until the
  /// cooldown releases back to [idle].
  bool get isCoolingDown => phase == GoogleTierPhase.cooldown;

  bool get isFinding => phase == GoogleTierPhase.finding;

  /// True once a complete response has spent the attempt for this context.
  bool get isSpent => phase == GoogleTierPhase.complete;

  bool get isResolving => resolvingPlaceId != null;

  BusinessVenueGoogleTierState copyWith({
    GoogleTierPhase? phase,
    List<PortalGoogleVenueCandidate>? rows,
    GoogleTierError? errorKind,
    bool clearError = false,
    int? retryAfterSeconds,
    bool clearRetryAfter = false,
    String? resolvingPlaceId,
    bool clearResolving = false,
  }) {
    return BusinessVenueGoogleTierState(
      phase: phase ?? this.phase,
      rows: rows ?? this.rows,
      errorKind: clearError ? null : (errorKind ?? this.errorKind),
      retryAfterSeconds: clearRetryAfter
          ? null
          : (retryAfterSeconds ?? this.retryAfterSeconds),
      resolvingPlaceId: clearResolving
          ? null
          : (resolvingPlaceId ?? this.resolvingPlaceId),
    );
  }
}

/// Fetch signature for the transient Google search — injected so the state
/// machine is testable without Dio (mirrors `map_suggest_provider`).
typedef GoogleVenueSearch =
    Future<PortalGoogleSearchResponse> Function(
      String query, {
      double? latitude,
      double? longitude,
      String? region,
      String? language,
      int? limit,
    });

/// Resolve-by-place-id signature, injected for the same reason.
typedef GoogleVenueResolve =
    Future<PortalVenueCandidate> Function(String placeId);

/// Analytics hook for a completed search attempt. Wired to real analytics by
/// the provider; kept injectable so the state machine stays assertable against
/// a bare notifier. Carries only aggregate, non-identifying signal (spec: no
/// raw queries / URLs / precise coordinates).
typedef GoogleTierOnOutcome =
    void Function({
      required GoogleTierPhase outcome,
      required int matchCount,
      required bool hadLocationBias,
      GoogleTierError? errorKind,
    });

/// The manual "Find more" Google tier for the Business Connect venue search
/// (PROD-4270 S5). Layered on top of the local (Meilisearch) autocomplete: the
/// owner taps "Find more" to run a transient Google name search whose
/// deduplicated candidates append to the local list, then resolves only the
/// selected place before the existing claim routing.
///
/// One notifier per debounced query (the provider is keyed by it, so a query
/// change gets a fresh instance). A [_generation] guard additionally drops
/// responses invalidated by an in-context change (area/language) via
/// [resetForContext], so a late response can never replace results, spend the
/// attempt, or drive navigation for a context the user has since left.
class BusinessVenueGoogleTierNotifier
    extends StateNotifier<BusinessVenueGoogleTierState> {
  BusinessVenueGoogleTierNotifier({
    required this.query,
    required GoogleVenueSearch search,
    required GoogleVenueResolve resolveByPlaceId,
    this.onOutcome,
  }) : _search = search,
       _resolveByPlaceId = resolveByPlaceId,
       super(const BusinessVenueGoogleTierState());

  /// The debounced query this tier searches (the provider's family key).
  final String query;

  final GoogleVenueSearch _search;
  final GoogleVenueResolve _resolveByPlaceId;
  final GoogleTierOnOutcome? onOutcome;

  /// Google SearchText returns at most 10; ask for the full page.
  static const int _limit = 10;

  int _generation = 0;
  Timer? _cooldownTimer;

  /// Run (or retry) the Google search for the current context. No-op while a
  /// search is in flight (duplicate activation) or once the attempt is already
  /// spent for this context. [localRows] are the current local results, used to
  /// dedupe the Google candidates.
  Future<void> findMore({
    required List<PortalVenueCandidate> localRows,
    double? latitude,
    double? longitude,
    String? region,
    String? language,
  }) async {
    // No-op while a search is in flight (duplicate activation), once the attempt
    // is spent, or while cooling down after a 429 (honor Retry-After).
    if (state.isFinding || state.isSpent || state.isCoolingDown) return;

    final generation = _generation;
    final hadLocationBias = latitude != null && longitude != null;
    state = state.copyWith(
      phase: GoogleTierPhase.finding,
      clearError: true,
      clearRetryAfter: true,
    );

    try {
      final response = await _search(
        query,
        latitude: latitude,
        longitude: longitude,
        region: region,
        language: language,
        limit: _limit,
      );
      // A context change (query/area/language) since this fired invalidates the
      // response entirely — it cannot append, spend the attempt, or navigate.
      if (!mounted || generation != _generation) return;

      final deduped = _dedupe(response.candidates, localRows);
      final isPartial = response.status == PortalGoogleSearchStatus.partial;
      state = state.copyWith(
        phase: isPartial ? GoogleTierPhase.partial : GoogleTierPhase.complete,
        rows: deduped,
      );
      onOutcome?.call(
        outcome: state.phase,
        matchCount: deduped.length,
        hadLocationBias: hadLocationBias,
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      _applyFailure(error, generation, hadLocationBias);
    }
  }

  /// Reset the tier because the search context changed (area or language). Bumps
  /// the generation so any in-flight response is dropped, cancels any cooldown,
  /// and returns to [idle]. Query changes need no call here — the provider is
  /// keyed by query, so they get a fresh notifier.
  void resetForContext() {
    _generation++;
    _cooldownTimer?.cancel();
    // Nothing to reset only when the tier is already pristine — idle, no rows,
    // and no resolve in flight. An in-flight resolve counts as live state: its
    // row belongs to the old context, so clear the spinner (the resolve itself
    // still completes for its caller; the place-id-tied finally won't stomp a
    // newer resolve).
    if (state.phase == GoogleTierPhase.idle &&
        state.rows.isEmpty &&
        state.resolvingPlaceId == null) {
      return;
    }
    state = const BusinessVenueGoogleTierState();
  }

  /// Resolve the selected Google place to a claimable canonical venue. Returns
  /// null (without calling the API) when a resolve is already in flight —
  /// duplicate-resolve prevention. The row-level spinner is driven by
  /// [BusinessVenueGoogleTierState.resolvingPlaceId]. Rethrows on failure so the
  /// caller can surface an error and re-enable the row (the spinner is cleared
  /// either way).
  Future<PortalVenueCandidate?> resolveCandidate(String placeId) async {
    if (state.isResolving) return null;
    state = state.copyWith(resolvingPlaceId: placeId);
    try {
      return await _resolveByPlaceId(placeId);
    } finally {
      // Only clear the spinner if it's still ours — a resetForContext (or a
      // later resolve) may have moved on while this call was in flight, and we
      // must not stomp the newer resolvingPlaceId.
      if (mounted && state.resolvingPlaceId == placeId) {
        state = state.copyWith(clearResolving: true);
      }
    }
  }

  /// Dedupe Google candidates against the current local rows and against each
  /// other. Identity is the canonical `venue_id` when present, else the
  /// `google_place_id`; a match keeps the existing local row (the Google row is
  /// dropped). Names are never used to match. Returned order is preserved.
  List<PortalGoogleVenueCandidate> _dedupe(
    List<PortalGoogleVenueCandidate> candidates,
    List<PortalVenueCandidate> localRows,
  ) {
    final localVenueIds = <String>{
      for (final row in localRows)
        if (row.venueId.isNotEmpty) row.venueId,
    };
    final localPlaceIds = <String>{
      for (final row in localRows)
        if ((row.googlePlaceId ?? '').isNotEmpty) row.googlePlaceId!,
    };

    final seen = <String>{};
    final out = <PortalGoogleVenueCandidate>[];
    for (final candidate in candidates) {
      final venueId = candidate.venueId;
      final placeId = candidate.googlePlaceId;
      final hasVenueId = venueId != null && venueId.isNotEmpty;

      // A row with neither a canonical id nor a place id can't be deduped or
      // resolved — drop it rather than let malformed rows collapse to one key.
      if (!hasVenueId && placeId.isEmpty) continue;

      if (hasVenueId && localVenueIds.contains(venueId)) continue;
      if (placeId.isNotEmpty && localPlaceIds.contains(placeId)) continue;

      final identity = hasVenueId ? 'v:$venueId' : 'g:$placeId';
      if (!seen.add(identity)) continue;
      out.add(candidate);
    }
    return out;
  }

  void _applyFailure(Object error, int generation, bool hadLocationBias) {
    final inner = _unwrap(error);
    if (inner is RateLimitException) {
      final seconds = inner.retryAfterSeconds;
      state = state.copyWith(
        phase: GoogleTierPhase.cooldown,
        retryAfterSeconds: seconds,
      );
      _scheduleCooldownRelease(seconds, generation);
      onOutcome?.call(
        outcome: GoogleTierPhase.cooldown,
        matchCount: 0,
        hadLocationBias: hadLocationBias,
      );
      return;
    }
    // A 503 from the search means the Google provider is unavailable/timed out
    // (distinct from a 200 with zero matches). Everything else is generic.
    final kind = (inner is ApiException && inner.statusCode == 503)
        ? GoogleTierError.providerUnavailable
        : GoogleTierError.generic;
    state = state.copyWith(phase: GoogleTierPhase.failed, errorKind: kind);
    onOutcome?.call(
      outcome: GoogleTierPhase.failed,
      matchCount: 0,
      hadLocationBias: hadLocationBias,
      errorKind: kind,
    );
  }

  void _scheduleCooldownRelease(int seconds, int generation) {
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted || generation != _generation) return;
      if (state.phase != GoogleTierPhase.cooldown) return;
      state = state.copyWith(
        phase: GoogleTierPhase.idle,
        clearError: true,
        clearRetryAfter: true,
      );
    });
  }

  /// The error interceptor wraps typed exceptions in `DioException.error`; tests
  /// throw the typed exception directly. Unwrap either shape without importing
  /// Dio here (mirrors `ContentBlockedException.tryFrom`).
  Object _unwrap(Object error) {
    try {
      final inner = (error as dynamic).error;
      if (inner is Object) return inner;
    } catch (_) {
      // Not a DioException-shaped object — use the error itself.
    }
    return error;
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }
}

/// One Google "Find more" tier per debounced query. Keyed by the same query the
/// local [businessVenueSearchProvider] uses, so a query change disposes the old
/// tier and starts a fresh one (idle, attempt un-spent).
final businessVenueGoogleTierProvider = StateNotifierProvider.autoDispose
    .family<
      BusinessVenueGoogleTierNotifier,
      BusinessVenueGoogleTierState,
      String
    >((ref, query) {
      final api = ref.watch(venueClaimApiProvider);
      final analytics = ref.watch(unifiedAnalyticsProvider);
      return BusinessVenueGoogleTierNotifier(
        query: query,
        search: api.searchBusinessVenuesGoogle,
        resolveByPlaceId: api.resolveBusinessVenueByPlaceId,
        onOutcome:
            ({
              required outcome,
              required matchCount,
              required hadLocationBias,
              errorKind,
            }) {
              analytics.trackBusinessVenueFindMore(
                outcome: switch (outcome) {
                  GoogleTierPhase.complete => 'complete',
                  GoogleTierPhase.partial => 'partial',
                  GoogleTierPhase.cooldown => 'rate_limited',
                  _ => 'failed',
                },
                matchCount: matchCount,
                locationSource: hadLocationBias ? 'gps' : 'none',
                errorCategory: switch (outcome) {
                  GoogleTierPhase.cooldown => 'rate_limited',
                  GoogleTierPhase.failed =>
                    errorKind == GoogleTierError.providerUnavailable
                        ? 'provider_unavailable'
                        : 'generic',
                  _ => null,
                },
              );
            },
      );
    });
