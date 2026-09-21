import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/experiment_service.dart';
import '../../../data/models/map_pin.dart';
import '../../../data/models/user_profile.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../models/map_query.dart';
import '../utils/map_feature_gates.dart';
import '../utils/map_grid_selection.dart' show kTargetCellPx;
import '../utils/map_pins_cache.dart';
import 'map_personalization_provider.dart';
import 'map_query_provider.dart';
import 'map_search_provider.dart';
import 'map_ui_state_provider.dart';

/// Result + loading state for the map's `/map/pins` fetch.
///
/// [data] is the **last good** response — it deliberately survives loading and
/// cancellation so the map never blanks while a new area loads (the user can
/// keep panning over stable pins until the new results arrive).
class MapPinsState {
  final MapPinsResponse? data;
  final bool isLoading;

  /// PROD-3657 — a **cached** pool being shown while a fetch is in flight, or
  /// null.
  ///
  /// [data] is the last-good response for whatever area was last fetched, which
  /// after a pan is the area the user has *left*. Re-slicing it to the new
  /// viewport paints almost nothing — the blank frame this ticket removes. When
  /// the cache holds a pool that covers the new viewport, it rides here and the
  /// map draws it immediately.
  ///
  /// Deliberately a separate field rather than a swap of [data]:
  ///
  ///  • it feeds the LIVE selection only, so the grid and the "Ver N
  ///    resultados" count don't reset (and re-fire `/map/hydrate`) twice per
  ///    settle — once for the pre-paint, once for the response;
  ///  • it can never outlive the response. Every successful fetch publishes a
  ///    state with no pre-paint, so "the response always wins" holds by
  ///    construction rather than by discipline.
  ///
  /// It carries no `selection` (see `map_pins_cache.dart`), so the map selects
  /// client-side for the camera the user is actually looking at.
  final MapPinsResponse? prepaint;

  /// PROD-3565 — the active list could not be fetched: `/map/pins` answered
  /// **404** for a `scope=list` request.
  ///
  /// The backend returns 404 for *every* authorization failure — gone, never
  /// existed, or no longer visible to this caller (unshared, deleted,
  /// moderated) — deliberately, so list ids can't be probed. A list can pass
  /// that gate in `/map/suggest` and fail it by the time the user taps.
  ///
  /// This is a **signal, not a treatment**: it exists so PROD-3566 can back out
  /// of list mode and tell the user. Without it the generic error path would
  /// keep the *previous* scope's pins on screen while the query still claims a
  /// list is active — the map silently lying about what it shows.
  final bool listUnavailable;

  const MapPinsState({
    this.data,
    this.isLoading = false,
    this.listUnavailable = false,
    this.prepaint,
  });

  /// The pool the MAP should draw: the pre-paint when there is one, else the
  /// last-good response. The grid and the count deliberately read [data]
  /// directly instead — see [prepaint].
  MapPinsResponse? get displayData => prepaint ?? data;

  /// Copy keeping [data] — used to flip loading.
  ///
  /// Clears [listUnavailable] (a new attempt is underway, so the previous
  /// failure is no longer the current truth) and **clears [prepaint]**: the
  /// pre-paint's whole lifetime is the in-flight window. A cancelled or failed
  /// fetch must hand the map back to the last-good response rather than leave
  /// cached pins driving it with nothing behind them — otherwise a transport
  /// failure parks the map on a cached pool indefinitely, which is worse than
  /// the stale frame this feature replaces (codex review).
  MapPinsState _loading(bool loading) =>
      MapPinsState(data: data, isLoading: loading);

  /// Copy dropping only [prepaint] — used when the pool cache is emptied with
  /// no new attempt underway to justify resetting anything else.
  MapPinsState _withoutPrepaint() => MapPinsState(
    data: data,
    isLoading: isLoading,
    listUnavailable: listUnavailable,
  );

  /// PROD-3665 — copy for an identity change. Keeps [data] only when the
  /// identity that just left provably owned nothing private (see
  /// [_mayKeepPools]).
  ///
  /// [prepaint] always goes — it IS cached data, and the cache is emptied at
  /// the same boundary. So does [listUnavailable]: a 404 on `scope=list` is the
  /// backend's answer to *this caller's* authorization (PROD-3565), so the
  /// verdict cannot survive a change of caller. The refetch that follows
  /// re-derives it.
  MapPinsState _atAuthBoundary({required bool keepData}) =>
      MapPinsState(data: keepData ? data : null, isLoading: isLoading);
}

/// PROD-3665 — who a `/map/pins` request or response belongs to.
///
/// Two fields, not one, because **`user == null` does not mean "guest"**:
/// `AuthState.isAuthenticated` is documented as staying true while the profile
/// is null ("Profile may be null temporarily if network is unavailable" —
/// `auth_provider.dart`). Keyed on the user id alone, a signed-in session whose
/// `me` has not landed and a guest read as the same identity — and a sign-out
/// between them would not even fire the listener, so the previous account's
/// `yours` pins would survive it outright (codex review).
typedef MapIdentity = ({String? userId, bool isAuthenticated});

/// Composed from the two public auth leaves rather than read off
/// `authStateProvider`: a test that overrides both is fully covered, and this
/// notifier still never drags in the whole auth stack — the reason PROD-3657
/// rode `currentUserProvider` rather than `currentUserIdProvider`.
final _mapIdentityProvider = Provider<MapIdentity>(
  (ref) => (
    userId: ref.watch(currentUserProvider)?.id,
    isAuthenticated: ref.watch(isAuthenticatedProvider),
  ),
);

/// PROD-3665 — may the pins fetched under [prev] stay on screen now that [next]
/// holds? Two cases say yes, and only two:
///
///  • **[prev] was not a real account** — a guest, or the sliver before the
///    bootstrap guest mint. It owns nothing private, so nothing on screen can
///    belong to an account. This is the guest → user upgrade, which is a real
///    and common flow here (a guest token is minted at bootstrap for
///    unauthenticated map use, and `requireAuth` from the scope chips lands
///    straight back on the map), and it must never blank.
///  • **[prev] was a real session whose profile had not arrived yet, and [next]
///    is that same session with one.** It cannot be a *different* account:
///    signing out always mints a guest token in between, and that transition is
///    caught by the case above.
///
/// Everything else — sign-out, account switch — drops. Zé's call for this
/// ticket: drop for **every** scope, not only `yours`/`following`/`list`, and
/// take the one blank round trip on `all` rather than carry two rules.
bool _mayKeepPools(MapIdentity? prev, MapIdentity next) {
  if (prev == null) return false;
  if (!prev.isAuthenticated) return true;
  return prev.userId == null && next.isAuthenticated && next.userId != null;
}

/// PROD-2736 — owns the `/map/pins` fetch lifecycle (count-first), with
/// request cancellation that keeps the map interactive and stable.
///
/// - Refetches on every [MapQuery] change (settle / filter edit), cancelling
///   the prior request first.
/// - Keeps the last-good pins across loads + cancellation (no blanking).
/// - [cancelInFlight] abandons the request the moment the user starts panning
///   — the old area's results are no longer wanted; pins stay until the next
///   settle resolves.
class MapPinsNotifier extends StateNotifier<MapPinsState> {
  MapPinsNotifier(this._ref) : super(const MapPinsState()) {
    _ref.listen<MapQuery>(
      mapQueryProvider,
      (_, next) => _fetch(next),
      fireImmediately: true,
    );
    // PROD-2906: refetch when the v2 flag resolves/flips mid-session so the
    // current view upgrades to (or falls back from) server-side selection
    // without waiting for the next camera settle.
    _ref.listen<bool>(
      experimentServiceProvider.select((s) => s.enableMapPinsV2),
      (prev, next) {
        if (prev != next) _fetch(_ref.read(mapQueryProvider));
      },
    );
    // PROD-2971: an admin toggling map debug mode (or the per-cell-counts
    // sub-toggle) refetches immediately so the current area gains/loses the
    // `debug` block without waiting for the next camera settle.
    _ref.listen<bool>(mapDebugEnabledProvider, (prev, next) {
      if (prev != next) _fetch(_ref.read(mapQueryProvider));
    });
    _ref.listen<bool>(mapDebugCellCountsProvider, (prev, next) {
      if (prev != next && _ref.read(mapDebugEnabledProvider)) {
        _fetch(_ref.read(mapQueryProvider));
      }
    });
    // PROD-2948: refetch when the admin flips the personalization level so the
    // current view re-ranks immediately (same pattern as the v2 flag above).
    _ref.listen<MapPersonalizationLevel>(mapPersonalizationLevelProvider, (
      prev,
      next,
    ) {
      if (prev != next) _fetch(_ref.read(mapQueryProvider));
    });
    // PROD-3662: run the query the focused search mode deferred, once, on the
    // way out. See [_deferredWhileFocused].
    //
    // ⚠️ Scheduled on a microtask, NOT run inline, and that is load-bearing:
    // every executor path leaves focused mode BEFORE it writes the query it is
    // executing (`_commit()` then `setKeyword()`, synchronously — see
    // `MapSearchExecutorImpl.executeKeyword`). Firing here inline would send
    // the pre-execution query and then immediately cancel it for the real one:
    // two requests where the deferral exists to guarantee one. Deferring by a
    // microtask lets that synchronous write land first, and its own `_fetch`
    // clears the latch — so this wakes up with nothing owed. (Codex review.)
    _ref.listen<bool>(mapSearchProvider.select((s) => s.focused), (prev, next) {
      if (prev == true && next == false && _deferredWhileFocused) {
        Future<void>.microtask(() {
          if (!mounted || !_deferredWhileFocused) return;
          _fetch(_ref.read(mapQueryProvider));
        });
      }
    });
    // PROD-3657: signing in or out changes what `yours`/`following` return —
    // and what `all` ranks — WITHOUT changing `MapQuery.filterSignature`, which
    // only knows the scope's name. The signature can't express identity, so the
    // cache is dropped wholesale at the boundary rather than keyed across it.
    //
    // Rides [_mapIdentityProvider], which composes the two public auth leaves
    // rather than resolving the whole auth stack — see its docstring. A record
    // compares structurally, so a profile edit that leaves the id alone doesn't
    // trip this.
    //
    // PROD-3665 extends the same boundary from the cache to `state.data`.
    _ref.listen<MapIdentity>(_mapIdentityProvider, (prev, next) {
      if (prev == next) return;
      cache.clear();
      if (!mounted) return;
      // A pre-paint IS cached data, so it always goes: dropping the stored
      // entries while one is on screen would clear the cupboard and leave the
      // leak visible (codex review). Whether the last-good response may stay is
      // the one judgement here — see [_mayKeepPools].
      state = state._atAuthBoundary(keepData: _mayKeepPools(prev, next));
      // …and refetch. `MapQuery` does not change at a sign-in or a sign-out, so
      // without this nothing refills the map until the next camera settle —
      // which never comes if the user is standing still. Same shape as the
      // v2-flag / debug / personalization listeners above.
      //
      // It also cancels the in-flight request, which is what makes the
      // landing-site identity checks in `_fetch` a focused-mode-only path
      // rather than the common one.
      _fetch(_ref.read(mapQueryProvider));
    });
    // PROD-3657 kill-switch. Flipping it off must take effect on the CURRENT
    // view, not at the next settle: empty the cupboard and hand the map back to
    // the last-good response. Same shape as the auth listener above and for the
    // same reason — a pre-paint left on screen with the cache cleared behind it
    // is the one state neither branch is supposed to produce.
    _ref.listen<bool>(experimentServiceProvider.select(mapPinsCacheEnabled), (
      prev,
      next,
    ) {
      if (next) return;
      cache.clear();
      if (mounted && state.prepaint != null) state = state._withoutPrepaint();
    });
  }

  final Ref _ref;
  CancelToken? _token;

  /// PROD-3833 — the query whose failure we have already retried, so the retry
  /// in [_maybeRetryAfterFailure] can never become a loop against an endpoint
  /// that is simply down. Compared by identity: a new camera, filter or scope
  /// produces a new [MapQuery] instance and therefore earns its own attempt.
  MapQuery? _retriedFor;

  /// Short enough that the user reads it as "loading", long enough not to land
  /// inside the same blip that failed. Sits comfortably inside the ~950 ms the
  /// opening ease keeps the pins hidden for, so a rescued open still reveals
  /// real pins rather than an empty set.
  static const Duration _kRetryDelay = Duration(milliseconds: 400);

  /// PROD-3662 — a query change landed while the focused search mode was up,
  /// so its fetch was skipped and owes one on exit.
  bool _deferredWhileFocused = false;

  /// PROD-3657 — pools already fetched in this session, so panning or zooming
  /// back over covered ground re-paints without waiting for a round trip.
  /// Visible for tests (asserting bounds/TTL through the notifier).
  final MapPinsCache cache = MapPinsCache();
  Future<void> _fetch(MapQuery q) async {
    // PROD-3662 — while the focused search mode is up, a query change does NOT
    // fetch. Two independent reasons, either sufficient:
    //
    // - **Nobody can see it.** The map is behind an opaque scrim and the
    //   dropdown; a request whose only visible effect is hidden is waste.
    // - **Zé's rule for the scope banner's ×** (Decision #53e): clearing the
    //   corpus must not cost a `/map/pins` call while the search is open. The
    //   parts the user CAN see still update instantly — the banner goes, the
    //   "De quem?" chip flips, and the suggest lane refetches unbounded — it is
    //   only the map underneath that waits.
    //
    // The deferred fetch is usually **free rather than merely late**: every
    // exit path either executes something (which writes the query again and
    // fetches once, unfocused) or simply closes, where this one call restores
    // the map to whatever the user left it meaning.
    if (_ref.read(mapSearchProvider).focused) {
      _deferredWhileFocused = true;
      return;
    }
    // Any real fetch discharges the debt, wherever it came from — which is what
    // makes the microtask above a no-op when an execution already refetched.
    _deferredWhileFocused = false;
    _token?.cancel();

    // Not ready (no centre) → keep last pins, stop loading. There is no zoom
    // floor: every scope fetches at any zoom (the fetch is radius-bounded ≤50km
    // + 300-capped, and the selection caps the display, so a wide view is fine).
    if (!q.hasCenter) {
      if (mounted) state = state._loading(false);
      return;
    }

    final token = _token = CancelToken();
    // PROD-3657 — pre-paint from the cache while the request is in flight.
    //
    // ⚠️ This runs AFTER the request has been decided on and BEFORE it is
    // awaited, and it never returns early: the cache pre-paints, it never gates
    // a fetch. That is what makes the worst case "what the user sees today"
    // rather than "stale pins nobody refreshes".
    //
    // The pre-paint is per-fetch: a miss CLEARS the previous one rather than
    // keeping it. An entry chosen for an earlier camera has no claim on this
    // one, and falling back to the last-good response is exactly today's
    // behaviour.
    final cacheOn = mapPinsCacheEnabled(_ref.read(experimentServiceProvider));
    final cached = (mounted && cacheOn)
        ? cache.bestFor(q, DateTime.now())
        : null;
    if (mounted) {
      state = MapPinsState(data: state.data, isLoading: true, prepaint: cached);
    }

    // PROD-3657 / PROD-3665 — whose data this request will return. A response
    // issued under one identity must never become another's: `yours`/`following`
    // mean something different across a sign-in, `all` is ranked differently,
    // and `MapQuery.filterSignature` (the cache key) knows only the scope's
    // NAME. The listener above empties the cache and the pools at the boundary;
    // this is what stops a request that was already in flight from re-filling
    // either afterwards (codex review).
    final identityAtFetch = _ref.read(_mapIdentityProvider);

    // Dates are events-only; a venues-only query sends none (the chosen date
    // stays in MapQuery and re-applies once events are included again).
    final range = q.dateApplies ? q.dateRange(DateTime.now()) : null;
    final keyword = q.keyword.trim();

    // PROD-2906 (A6) — opt into server-side selection (pins_version=2) when the
    // FE flag is on AND we have a settled viewport rect (v2 requires the rect +
    // zoom, else the server 422s). Before the first settle (no bounds) we send
    // v1 and let the client-side selectPins run over the seeded box; the first
    // camera settle upgrades to v2. Sending v2 is safe — the server flag gates
    // whether `selection` comes back; null ⇒ the FE falls back to selectPins.
    final wantV2 = _ref.read(experimentServiceProvider).enableMapPinsV2;
    final useV2 = wantV2 && q.hasBounds;

    // PROD-2971 — admin-only diagnostics. Gate on admin BEFORE sending `debug`:
    // the backend 422s a non-admin `debug=true`, so a non-admin must never send
    // it. Master switch = [mapDebugEnabledProvider]; per-cell counts ride along
    // only when both are on.
    final isAdmin = _ref.read(currentUserProvider)?.role == UserRole.admin;
    final debugOn = isAdmin && _ref.read(mapDebugEnabledProvider);
    final debugCellCounts = debugOn && _ref.read(mapDebugCellCountsProvider);
    // PROD-2948 (FE-2) — admin-only personalization strength. Omitted for `off`
    // so the default request stays byte-identical; only the local kDebugMode
    // debug control can set it, and the backend clamps non-admins to off anyway.
    final level = _ref.read(mapPersonalizationLevelProvider);
    final personalizationLevel = level == MapPersonalizationLevel.off
        ? null
        : level.wire;
    try {
      final resp = await _ref
          .read(mapApiProvider)
          .getMapPins(
            latitude: q.centerLat!,
            longitude: q.centerLng!,
            radiusMeters: q.radiusMeters,
            entity: q.entityWire,
            scope: q.scopeWire,
            // PROD-3565 — null off list mode by construction (see listIdWire),
            // which is what keeps the backend's "list_id on any other scope is
            // a 422" contract unreachable from here.
            listId: q.listIdWire,
            // PROD-2851: for bounded scopes (yours/following/list) skip the
            // backend's 50 km distance gate so ALL saved/followed/listed items
            // show at any zoom (scopeWire is null only for `all`, where this is
            // a backend no-op). PROD-3565 rides this unchanged — a curated list
            // may span cities and should show whole.
            ignoreRadius: q.scopeWire != null,
            facetFilters: q.facetFilters.toList(),
            query: keyword.isEmpty ? null : keyword,
            startDate: range != null ? _ymd(range.start) : null,
            endDate: range != null ? _ymd(range.end) : null,
            pinsVersion: useV2 ? 2 : null,
            viewportSwLat: useV2 ? q.swLat : null,
            viewportSwLng: useV2 ? q.swLng : null,
            viewportNeLat: useV2 ? q.neLat : null,
            viewportNeLng: useV2 ? q.neLng : null,
            zoom: useV2 ? q.zoom : null,
            targetCellPx: useV2 ? kTargetCellPx : null,
            // PROD-3731: `selection_cap` is no longer sent. The server reads it
            // on no code path; for v2 the applied cap comes from
            // `MAP_PINS_SELECTION_BANDS` (8 below z16 for `all`, 20 above), so
            // the value we used to send described nothing. `selectionCapForSource`
            // survives for the client-side `selectPins` fallback.
            debug: debugOn,
            debugCellCounts: debugCellCounts,
            personalizationLevel: personalizationLevel,
            cancelToken: token,
          );
      if (!mounted || token.isCancelled) return;
      // PROD-3665 — the identity moved while this was in flight. The response
      // describes `identityAtFetch`'s world: on `yours`/`following`/`list` it is
      // literally the other account's saved, followed or curated items, and on
      // `all` it is ranked for them. It becomes neither `data` nor a cache
      // entry — one return covers both, which is why the `cache.put` below no
      // longer repeats the check.
      //
      // Usually unreachable: the listener above refetches, and that cancels
      // this token. It IS reachable while the focused search mode is up, where
      // `_fetch` records the debt and returns BEFORE cancelling — so the guard
      // lives here, at the landing site, rather than resting on the cancel.
      if (_ref.read(_mapIdentityProvider) != identityAtFetch) {
        // Only touch the spinner if this is still the current request.
        if (identical(_token, token)) state = state._loading(false);
        return;
      }
      // PROD-3657: store the pool, then publish a state with **no pre-paint**.
      // "The response always wins" is therefore structural: there is no path
      // that lands a response and leaves cached pins on the map.
      // `cacheOn` is re-read rather than reused: the flag can flip during the
      // round trip, and the listener that empties the cache has already run by
      // then — seeding it from a response issued while it was on would refill
      // what the flip just cleared.
      if (mapPinsCacheEnabled(_ref.read(experimentServiceProvider))) {
        cache.put(q, resp, DateTime.now());
      }
      state = MapPinsState(data: resp, isLoading: false);
    } catch (e) {
      if (!mounted) return;
      // PROD-3665 — a failure is a verdict about `identityAtFetch`'s world too,
      // and the list-404 branch below acts on one. The backend 404s **every**
      // authorization failure on `scope=list` (PROD-3565), so letting a stale
      // one through would make PROD-3566 back out of list mode on the strength
      // of the previous account's permissions — a list the person now signed in
      // can see perfectly well (codex review).
      if (_ref.read(_mapIdentityProvider) != identityAtFetch) {
        if (identical(_token, token)) state = state._loading(false);
        return;
      }
      // PROD-3565 — a 404 on a list-scoped request is not a transport blip: the
      // list is gone or no longer visible to this caller, and list mode can
      // never succeed again until the scope changes. Surface it so PROD-3566
      // can back out; everything else keeps the old "stay quiet" behaviour.
      //
      // Guarded on `q.isListMode` because 404 means something else entirely on
      // the other scopes, and on `!token.isCancelled` so a superseded request
      // can't strand the flag after the user has already moved on.
      final isListNotFound =
          q.isListMode &&
          !token.isCancelled &&
          e is DioException &&
          e.response?.statusCode == 404;
      if (isListNotFound) {
        // PROD-3657: no pre-paint here, deliberately. The list is gone or no
        // longer visible to this caller, so painting its cached pins would be
        // the map claiming to show a corpus the user can't have.
        state = MapPinsState(
          data: state.data,
          isLoading: false,
          listUnavailable: true,
        );
        return;
      }
      // Cancelled (superseded / move-start) or a transport error: keep the
      // last-good pins, just stop the spinner.
      state = state._loading(false);
      _maybeRetryAfterFailure(q, token);
    }
  }

  /// PROD-3833 — retry ONCE when a fetch failed and there is nothing on screen.
  ///
  /// Before this ticket a failed opening fetch was quietly rescued by the
  /// churn: the camera settle that followed always committed (the first settle
  /// to carry bounds forces `moved`), which re-fetched. Seeding the viewport
  /// removes that settle — deliberately — so the rescue has to become explicit
  /// or a failed first request leaves the map blank with nothing scheduled to
  /// fix it. Zé's condition for this ticket was exactly that: don't re-request
  /// on the settle **unless the first one failed**.
  ///
  /// Deliberately NOT coupled to the settle. The seeded request can still be in
  /// flight when the settle arrives and fail afterwards, by which point the
  /// settle is long gone — the hole codex found in both settle-coupled designs.
  /// Hanging the retry off the failure itself has no such window.
  ///
  /// Bounded to one attempt per query instance (`identical`, so a new camera or
  /// filter change earns a fresh one) and skipped when:
  ///  • the request was **cancelled** — something newer is already running;
  ///  • it is **superseded** — a later fetch owns the token;
  ///  • we still have **last-good pins** — the user is looking at something, so
  ///    a silent extra request buys nothing and doubles the load on an endpoint
  ///    already burning 22 % of its time on cancelled calls.
  void _maybeRetryAfterFailure(MapQuery q, CancelToken token) {
    if (token.isCancelled || !identical(_token, token)) return;
    if (state.data != null) return;
    if (identical(_retriedFor, q)) return;
    _retriedFor = q;
    Future<void>.delayed(_kRetryDelay, () {
      if (!mounted) return;
      // Re-read rather than reuse `q`: anything that moved on in the meantime
      // (a pan, a filter, a sign-in) has its own fetch, and re-issuing the old
      // query would fight it.
      final current = _ref.read(mapQueryProvider);
      if (!identical(current, q)) return;
      _fetch(current);
    });
  }

  /// Abandon the in-flight request (the user started panning). Keeps the
  /// current pins; the next settle fetches the new area.
  void cancelInFlight() {
    final token = _token;
    if (token == null || token.isCancelled) return;
    token.cancel();
    if (mounted) state = state._loading(false);
  }

  @override
  void dispose() {
    _token?.cancel();
    super.dispose();
  }
}

final mapPinsProvider =
    StateNotifierProvider.autoDispose<MapPinsNotifier, MapPinsState>(
      (ref) => MapPinsNotifier(ref),
    );

// The map's markers (individual pins + overflow bubbles) are derived from the
// custom grid selection — see `mapMarkersProvider` in `map_selection_provider.dart`
// (PROD-2807). This file owns only the `/map/pins` fetch lifecycle.

String _two(int n) => n.toString().padLeft(2, '0');
String _ymd(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
