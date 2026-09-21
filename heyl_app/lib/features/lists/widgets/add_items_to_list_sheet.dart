import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../core/utils/google_maps_url.dart';
import '../../../data/datasources/api/resolve_url_failure.dart';
import '../../../data/datasources/api/search_api.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/city_auto_scope_provider.dart';
import '../../../providers/city_scope_provider.dart';
import '../../../providers/detected_country_provider.dart';
import '../../../providers/providers.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/clickable.dart';
import '../models/search_scope.dart';
import '../providers/unified_list_provider.dart';
import 'location_scope_picker_sheet.dart';
import 'search_result_card.dart';

/// Minimum query length before firing API search requests.
const _minQueryLength = 2;

/// Debounce duration for search input.
const _debounceDuration = Duration(milliseconds: 600);

/// Soko/Ink at 0x14 alpha (~8 %). Used for the inactive tab-pill border.
/// Hex form is `#44131D14`.
const _kSokoInkAt8 = Color(0x1444131D);

/// Opens the "Add items to list" bottom sheet.
///
/// Returns `true` when the user taps the Instagram-share footer button so
/// the caller can chain the IG share sheet (preserves the handoff from
/// the previous full-page route). Returns `null` on any other dismissal
/// (swipe-down, scrim tap, back gesture).
///
/// The sheet keeps the underlying list page mounted while adding items
/// — replaces the legacy `/lists/:listId/add-items` full-page route that
/// pushed a new GoRouter location and forced the list view (with its
/// Mapbox cover map and PROD-1955 zine pager) to dispose + remount on
/// each round trip. See the investigation branch
/// `investigate/PROD-zine-add-item-freeze` for the freeze it resolves.
/// Snapshot of the sheet's user-facing state, used to restore the sheet
/// after a detail-page round-trip (PROD-2008).
///
/// Captured immediately before the sheet pops to push the detail, then
/// consumed once by the next `initState` and cleared. Anything not in
/// this snapshot (errors, in-flight flags, auto-scope, debounce timer)
/// is recomputed on reopen — only state that would surprise the user if
/// lost is preserved.
class _AddToListSheetSnapshot {
  final String query;
  final int activeTab;
  final List<ItemSuggestion> placeResults;
  final List<ItemSuggestion> eventResults;
  final SearchScope? scope;
  final bool userTouchedScope;
  final bool isUrlMode;
  final String? lastResolvedUrl;

  const _AddToListSheetSnapshot({
    required this.query,
    required this.activeTab,
    required this.placeResults,
    required this.eventResults,
    required this.scope,
    required this.userTouchedScope,
    required this.isUrlMode,
    required this.lastResolvedUrl,
  });
}

/// Sheet state captured before a detail-page navigation. Hydrated by the
/// next sheet's `initState` and cleared either there or when the
/// `showAddItemsToListSheet` loop exits.
final _addToListSheetSnapshotProvider = StateProvider<_AddToListSheetSnapshot?>(
  (ref) => null,
);

/// One-shot signal from the sheet to its caller: "I just popped because
/// the user tapped an item — push this path, then re-open me." Null when
/// the sheet popped for any other reason (dismiss, X, item added).
final _addToListSheetPendingDetailProvider = StateProvider<String?>(
  (ref) => null,
);

Future<bool?> showAddItemsToListSheet(
  BuildContext context, {
  required WidgetRef ref,
  required String listId,
  required String listName,
}) async {
  // PROD-2008: open-sheet / open-detail / reopen-sheet loop.
  //
  // The sheet is mounted via `showBottomSheetWithHiddenNav` with
  // `useRootNavigator: true`, but its overlay layer stays above any
  // route subsequently pushed on the same Navigator — even with
  // `Navigator.push(rootNavigator: true)`. So we can't render the detail
  // above the sheet. Instead: the sheet snapshots its search state into
  // [_addToListSheetSnapshotProvider], signals the detail path via
  // [_addToListSheetPendingDetailProvider], and pops itself. This loop
  // then `context.push`es the detail (which lands on the correct
  // Navigator now that the sheet is gone) and, when the detail pops,
  // re-opens the sheet — whose `initState` hydrates from the snapshot
  // so the user sees the same query, tab, and results.

  // Defensive: ensure we start clean so a leftover from a previous flow
  // (e.g. an exception that bypassed the exit-clear below) doesn't
  // hydrate the first sheet with stale state from another list.
  ref.read(_addToListSheetSnapshotProvider.notifier).state = null;
  ref.read(_addToListSheetPendingDetailProvider.notifier).state = null;

  // PROD-2125: an earlier revision pre-set a `transitionAnimationController`
  // to `value: 1.0` on reopen to skip the 250 ms slide-up animation. That hack
  // left the route's animation status wedged (`forward()` becomes a no-op at
  // value=1.0, never firing the listeners the BottomSheet drag/dismiss
  // machinery wires up) so taps could pass through the barrier and a partial
  // drag-dismiss could stick the sheet halfway open. The slide-up on reopen
  // is a small UX cost; correctness wins.
  bool? finalResult;
  while (true) {
    final result = await showBottomSheetWithHiddenNav<bool>(
      context: context,
      ref: ref,
      builder: (sheetContext) =>
          AddItemsToListSheet(listId: listId, listName: listName),
    );

    final pendingDetail = ref.read(_addToListSheetPendingDetailProvider);
    if (pendingDetail != null) {
      ref.read(_addToListSheetPendingDetailProvider.notifier).state = null;
      if (context.mounted) {
        await context.push(pendingDetail);
      }
      // Loop: reopen the sheet; the new state hydrates from the snapshot.
      continue;
    }

    finalResult = result;
    break;
  }

  // Defensive: clear any leftover snapshot when the flow exits. Normally
  // consumed (and nulled) by the reopened sheet's `initState`, but if
  // that path was never taken the snapshot would otherwise leak into a
  // future fresh open of the sheet (possibly for a different list).
  ref.read(_addToListSheetSnapshotProvider.notifier).state = null;

  return finalResult;
}

/// Bottom-sheet variant of the search-and-add flow. All search, scope,
/// URL-mode, and add-to-list logic is preserved verbatim from the
/// previous `AddItemsToListPage`; only the outer chrome (DSSheetShell
/// replaces the full-screen `ColoredBox > SizedBox > Column`) and the
/// dismissal mechanic (`Navigator.pop` instead of `context.pop`) differ.
class AddItemsToListSheet extends ConsumerStatefulWidget {
  final String listId;
  final String listName;

  const AddItemsToListSheet({
    super.key,
    required this.listId,
    required this.listName,
  });

  @override
  ConsumerState<AddItemsToListSheet> createState() =>
      _AddItemsToListSheetState();
}

class _AddItemsToListSheetState extends ConsumerState<AddItemsToListSheet> {
  final _searchController = TextEditingController();
  Timer? _debounceTimer;

  /// 0 = Places (default — Sítios pill renders active on entry), 1 = Events.
  /// PROD-1852 follow-up: there is no "no tab selected" state — Sítios is the
  /// default scope so the pill should already read as active when the sheet
  /// opens or after the search is cleared.
  int _activeTab = 0;

  // ── Search state (per-tab so each resolves independently) ──────────
  bool _isSearchingPlaces = false;
  bool _isSearchingEvents = false;
  String? _placesError;
  String? _eventsError;
  List<ItemSuggestion> _placeResults = [];
  List<ItemSuggestion> _eventResults = [];
  int _searchGeneration = 0;

  CancelToken? _cancelToken;
  String _lastQuery = '';

  // PROD-2116: user's intent per item. Lives for the entire sheet
  // session; cleared only on dispose. Once a row has been touched, the
  // row builder reads its `isAdded` from this map exclusively (never
  // falls back to `listsApi.isInList`) — that's what keeps the row's
  // tint stable across the cache-lag window between `addToListsOptimistic`'s
  // synchronous `onSuccess` and the background HTTP completing.
  final Map<String, bool> _pendingTargets = {};

  // PROD-2116: our best-known server state per item. Seeded on first
  // touch from `listsApi.isInList(...)` and updated on every successful
  // commit. `_commitToggle` compares the user's `_pendingTargets[id]`
  // against this — never against `listsApi.isInList` — because the
  // per-list cache lags behind an ADD's background HTTP and would
  // misclassify a subsequent REMOVE tap as a no-op.
  final Map<String, bool> _referenceState = {};

  // PROD-2116: per-item debounce. Each tap cancels the existing timer
  // and starts a fresh one. The trailing-edge fire calls `_commitToggle`.
  final Map<String, Timer> _toggleDebounceTimers = {};

  // PROD-2116: items with an in-flight commit. Re-taps still update
  // `_pendingTargets`; the commit's completion handler re-checks the
  // target so we never lose the user's final intent.
  final Set<String> _commitInFlight = {};

  /// Idle window before the trailing-edge commit. Tight enough that a
  /// single deliberate tap shows its toast quickly (this is the lag
  /// the user feels after a tap), wide enough to coalesce a rapid mash
  /// burst into one API call.
  static const _kToggleDebounce = Duration(milliseconds: 250);

  // PROD-2008: guard against rapid taps stacking duplicate detail routes
  // while the imperative push is in flight.
  bool _isNavigatingToDetail = false;

  // URL-mode state (paste a Google Maps URL → resolve via backend).
  bool _isUrlMode = false;
  bool _urlLoading = false;
  ResolveUrlFailure? _urlError;
  String? _lastResolvedUrl;
  int _urlResolveGeneration = 0;

  // Location scope (PROD-1326 v2).
  SearchScope? _scope;
  SearchScope? _autoScope;
  bool _autoScopeInFlight = false;

  /// True once the user has changed the scope via the sheet's local picker.
  /// Late-arriving home-page scope updates won't overwrite a deliberate pick
  /// (PROD-2004 — the home-page city selection is the seed, not a leash).
  bool _userTouchedScope = false;

  // ── Lifecycle ──────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    // PROD-2116: no longer pre-populating a local `_addedItems` set —
    // the row builder reads `listsApi.isInList(...)` directly, which
    // already reflects pre-existing items on the list (both from a
    // fresh open and after the PROD-2008 detail round-trip).
    //
    // PROD-2008: if we're reopening after a detail-page round-trip,
    // hydrate query/tab/results/scope from the snapshot so the user
    // lands back exactly where they left off.
    //
    // Two pitfalls we step around:
    //   (a) Setting `_searchController.text` fires `_onSearchChanged`,
    //       which calls `setState()`. During initState that throws
    //       "setState() called during build". Seeding `_lastQuery`
    //       first makes the listener's equality guard short-circuit
    //       before any setState happens.
    //   (b) Writing to a StateProvider during initState can notify
    //       listeners mid-mount and trigger the same crash. We
    //       deliberately do NOT clear the snapshot here — it's
    //       harmlessly overwritten by the next `_openItemDetail` tap,
    //       and the `showAddItemsToListSheet` loop clears it on exit.
    final snapshot = ref.read(_addToListSheetSnapshotProvider);
    if (snapshot != null) {
      _lastQuery = snapshot.query.trim();
      _searchController.text = snapshot.query;
      _activeTab = snapshot.activeTab;
      _placeResults = List.of(snapshot.placeResults);
      _eventResults = List.of(snapshot.eventResults);
      _scope = snapshot.scope;
      _userTouchedScope = snapshot.userTouchedScope;
      _isUrlMode = snapshot.isUrlMode;
      _lastResolvedUrl = snapshot.lastResolvedUrl;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _adoptHomeScope();
      _recomputeAutoScope();
    });
  }

  // ── Home-page scope adoption (PROD-2004) ───────────────────────────

  /// Seed `_scope` from the home-page city picker before falling back to
  /// the GPS/IP `_autoScope`. Priority:
  ///   1. `cityScopeProvider` — explicit pick on the action-bar pill.
  ///   2. `cityAutoScopeProvider` — profile/IP-derived auto scope (async).
  ///
  /// Normalizes `isAuto:false` on the seed so `_geoParamsForCurrentScope`
  /// uses the city's own centroid for the radius search instead of the
  /// device's `lastLocation` — otherwise a Porto pick on the home page
  /// would still produce a Lisbon-centred radius for a user whose GPS is
  /// in Lisbon.
  ///
  /// Skips when the user has already picked a scope inside the sheet
  /// (`_userTouchedScope`) so a late SharedPreferences restore doesn't
  /// stomp a deliberate local override.
  void _adoptHomeScope() {
    if (_userTouchedScope) return;
    final next = computeHomeScope(
      cityScope: ref.read(cityScopeProvider),
      cityAutoScope: ref.read(cityAutoScopeProvider).valueOrNull,
      gpsAutoScope: _autoScope,
    );
    if (next == _scope) return;
    setState(() => _scope = next);
    if (_searchController.text.trim().length >= _minQueryLength) {
      _performSearch();
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel('Widget disposed');
    _searchController.dispose();
    _debounceTimer?.cancel();
    // PROD-2116: cancel pending toggle debounces and commit any
    // in-flight intent fire-and-forget so a tap immediately before
    // dismissal still reaches the server.
    for (final timer in _toggleDebounceTimers.values) {
      timer.cancel();
    }
    _toggleDebounceTimers.clear();
    _commitPendingOnDispose();
    super.dispose();
  }

  // ── Auto-scope (GPS-first / IP-fallback) ───────────────────────────

  Future<void> _recomputeAutoScope() async {
    if (_autoScopeInFlight) return;
    _autoScopeInFlight = true;
    try {
      final locState = ref.read(locationProvider);
      final resolvedCity = locState.resolvedCityName;
      final gps = locState.lastLocation;
      final resolvedIso =
          locState.resolvedCountryCode ??
          ref.read(detectedCountryCodeProvider).valueOrNull?.toUpperCase();
      if (resolvedIso == null) return;

      final current = _autoScope;
      final alreadyMatches = switch (current) {
        SearchScopeCountryCity(:final iso2, :final city) =>
          iso2 == resolvedIso &&
              city.name == resolvedCity &&
              gps != null &&
              city.latitude == gps.lat &&
              city.longitude == gps.lon,
        SearchScopeCountry(:final iso2) =>
          iso2 == resolvedIso && (resolvedCity == null || gps == null),
        SearchScopeArea() => false,
        null => false,
      };
      if (alreadyMatches) return;

      final locale = Localizations.localeOf(context).toLanguageTag();
      final List<GeoCountry> countries;
      try {
        countries = await ref
            .read(geoApiProvider)
            .listCountries(locale: locale);
      } catch (_) {
        return;
      }
      if (!mounted) return;
      final country = countries.firstWhereOrNull((c) => c.iso2 == resolvedIso);
      if (country == null) return;

      final SearchScope next;
      if (resolvedCity != null && gps != null) {
        final syntheticCity = GeoCity(
          id: 'auto:${country.iso2}',
          name: resolvedCity,
          displayName: resolvedCity,
          latitude: gps.lat,
          longitude: gps.lon,
          source: 'local',
        );
        next = SearchScopeCountryCity(
          iso2: country.iso2,
          countryName: country.name,
          flagEmoji: country.flagEmoji,
          city: syntheticCity,
          isAuto: true,
        );
      } else {
        next = SearchScopeCountry(
          iso2: country.iso2,
          countryName: country.name,
          flagEmoji: country.flagEmoji,
          isAuto: true,
        );
      }

      if (next == _autoScope && _scope == _autoScope) return;

      final wasOnAuto = _scope == null || _scope == _autoScope;
      setState(() {
        _autoScope = next;
        if (wasOnAuto) _scope = next;
      });
      if (wasOnAuto &&
          _searchController.text.trim().length >= _minQueryLength) {
        _performSearch();
      }
    } finally {
      _autoScopeInFlight = false;
    }
  }

  // ── Search helpers ─────────────────────────────────────────────────

  void _cancelAndResetToken() {
    _cancelToken?.cancel('New search started');
    _cancelToken = CancelToken();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    if (query == _lastQuery) return;
    _lastQuery = query;

    _debounceTimer?.cancel();
    _cancelAndResetToken();
    ++_searchGeneration;

    final url = GoogleMapsUrl.extract(query);
    if (url != null) {
      _enterUrlMode(url);
      return;
    }

    if (_isUrlMode) {
      setState(() {
        _isUrlMode = false;
        _urlLoading = false;
        _urlError = null;
        _lastResolvedUrl = null;
        _placeResults = [];
      });
    }

    if (query.length < _minQueryLength) {
      setState(() {
        _placeResults = [];
        _eventResults = [];
        _isSearchingPlaces = false;
        _isSearchingEvents = false;
        _placesError = null;
        _eventsError = null;
      });
      return;
    }

    _debounceTimer = Timer(_debounceDuration, () {
      _performSearch();
    });
  }

  void _enterUrlMode(String url) {
    if (_activeTab != 0) setState(() => _activeTab = 0);
    setState(() {
      _isUrlMode = true;
      _placeResults = [];
      _eventResults = [];
      _isSearchingPlaces = false;
      _isSearchingEvents = false;
      _placesError = null;
      _eventsError = null;
    });

    if (_lastResolvedUrl == url && (_urlLoading || _placeResults.isNotEmpty)) {
      return;
    }
    _resolveUrl(url);
  }

  Future<void> _resolveUrl(String url) async {
    final generation = ++_urlResolveGeneration;
    setState(() {
      _urlLoading = true;
      _urlError = null;
      _lastResolvedUrl = url;
      _placeResults = [];
    });

    try {
      final result = await ref.read(venuesApiProvider).resolveVenueFromUrl(url);
      if (generation != _urlResolveGeneration || !mounted) return;
      switch (result) {
        case ResolveUrlPlace(:final suggestion):
          setState(() {
            _urlLoading = false;
            _placeResults = [suggestion];
          });
        case ResolveUrlListImport(:final job):
          // The pasted URL was a shared Google Maps *list* — the backend
          // started a background import that creates a NEW list (PROD-3903).
          // Hand the job to the import poller (NotificationHost then shows
          // progress → the finished list) and close this sheet.
          ref.read(importListProvider.notifier).adopt(job.jobId, url: url);
          setState(() => _urlLoading = false);
          showSoko(
            ref,
            message: Lt.of(context).searchUrlListImportStarted,
            variant: SokoVariant.info,
          );
          Navigator.of(context).pop();
      }
    } on ResolveUrlFailure catch (e) {
      if (generation != _urlResolveGeneration || !mounted) return;
      setState(() {
        _urlLoading = false;
        _urlError = e;
      });
    } catch (_) {
      if (generation != _urlResolveGeneration || !mounted) return;
      setState(() {
        _urlLoading = false;
        _urlError = const ResolveUrlUnknown();
      });
    }
  }

  void _retryResolveUrl() {
    final url = _lastResolvedUrl;
    if (url == null) return;
    _resolveUrl(url);
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.length < _minQueryLength) {
      setState(() {
        _placeResults = [];
        _eventResults = [];
        _isSearchingPlaces = false;
        _isSearchingEvents = false;
        _placesError = null;
        _eventsError = null;
      });
      return;
    }

    final generation = ++_searchGeneration;
    final searchApi = ref.read(searchApiProvider);
    final geo = _geoParamsForCurrentScope();

    _cancelAndResetToken();
    final token = _cancelToken!;

    final runPlaces = _scope != null;

    setState(() {
      _isSearchingPlaces = runPlaces;
      _isSearchingEvents = true;
      _placesError = null;
      _eventsError = null;
      _placeResults = [];
      _eventResults = [];
    });

    if (runPlaces) {
      _searchPlaces(searchApi, query, geo, generation, token);
    }
    _searchEvents(searchApi, query, geo, generation, token);
  }

  GeoParams _geoParamsForCurrentScope() {
    final locState = ref.read(locationProvider);
    final autoLoc =
        _scope is SearchScopeCountryCity &&
            (_scope as SearchScopeCountryCity).isAuto
        ? locState.lastLocation
        : null;
    // PROD-4065: pass the live device fix so a null / country-only scope still
    // forwards coordinates, biasing the backend search to the user's location.
    return geoParamsFromScope(
      _scope,
      autoLoc,
      deviceFix: locState.lastLocation,
      resolvedCountry: locState.resolvedCountryCode,
    );
  }

  Future<void> _searchPlaces(
    SearchApi api,
    String query,
    GeoParams geo,
    int generation,
    CancelToken token,
  ) async {
    try {
      final results = await api.searchPlaces(
        query: query,
        latitude: geo.latitude,
        longitude: geo.longitude,
        radiusMeters: geo.radiusMeters ?? 5000.0,
        mode: 'fast',
        country: geo.country,
        cancelToken: token,
      );
      if (generation != _searchGeneration || !mounted) return;
      setState(() {
        _placeResults = results;
        _isSearchingPlaces = false;
      });
      ref
          .read(unifiedAnalyticsProvider)
          .trackListSearch(
            query: query,
            tab: 'places',
            resultCount: results.length,
            listId:
                ref.read(unifiedListProvider(widget.listId)).list?.id ??
                widget.listId,
            scopeType: _scopeTypeLabel(),
            countryCode: _scopeCountryCode(),
            cityId: _scopeCityId(),
            citySource: _scopeCitySource(),
          );
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) return;
      if (generation != _searchGeneration || !mounted) return;
      setState(() {
        _isSearchingPlaces = false;
        _placesError = e.toString();
      });
    }
  }

  Future<void> _searchEvents(
    SearchApi api,
    String query,
    GeoParams geo,
    int generation,
    CancelToken token,
  ) async {
    try {
      final results = await api.searchEvents(
        query: query,
        mode: 'fast',
        latitude: geo.latitude,
        longitude: geo.longitude,
        radiusMeters: geo.radiusMeters,
        country: geo.country,
        cancelToken: token,
      );
      if (generation != _searchGeneration || !mounted) return;
      setState(() {
        _eventResults = results;
        _isSearchingEvents = false;
      });
      ref
          .read(unifiedAnalyticsProvider)
          .trackListSearch(
            query: query,
            tab: 'events',
            resultCount: results.length,
            listId:
                ref.read(unifiedListProvider(widget.listId)).list?.id ??
                widget.listId,
          );
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) return;
      if (generation != _searchGeneration || !mounted) return;
      setState(() {
        _isSearchingEvents = false;
        _eventsError = e.toString();
      });
    }
  }

  Future<void> _openScopePicker() async {
    final picked = await showLocationScopePicker(
      context,
      ref,
      currentScope: _scope,
    );
    if (!mounted) return;
    if (picked == null || picked == _scope) return;
    setState(() {
      _scope = picked;
      // Any deliberate in-sheet pick locks out late home-scope adoption
      // (see [_adoptHomeScope]).
      _userTouchedScope = true;
    });
    _trackScopeChange();
    _performSearch();
  }

  // ── Scope helpers for analytics ────────────────────────────────────

  String _scopeTypeLabel() => switch (_scope) {
    null => 'unset',
    SearchScopeCountry() => 'country',
    SearchScopeCountryCity() => 'country_city',
    SearchScopeArea() => 'area',
  };

  String? _scopeCountryCode() => switch (_scope) {
    null => null,
    SearchScopeCountry(:final iso2) => iso2,
    SearchScopeCountryCity(:final iso2) => iso2,
    SearchScopeArea() => null,
  };

  String? _scopeCityId() => switch (_scope) {
    SearchScopeCountryCity(:final city, :final isAuto) =>
      isAuto ? null : city.id,
    _ => null,
  };

  String? _scopeCitySource() => switch (_scope) {
    SearchScopeCountryCity(:final city, :final isAuto) =>
      isAuto ? null : city.source,
    _ => null,
  };

  void _trackScopeChange() {
    ref
        .read(unifiedAnalyticsProvider)
        .trackListSearchScopeChange(
          listId:
              ref.read(unifiedListProvider(widget.listId)).list?.id ??
              widget.listId,
          scopeType: _scopeTypeLabel(),
          countryCode: _scopeCountryCode(),
          cityId: _scopeCityId(),
          citySource: _scopeCitySource(),
        );
  }

  void _clearSearch() {
    _debounceTimer?.cancel();
    _cancelAndResetToken();
    ++_searchGeneration;
    ++_urlResolveGeneration;
    _lastQuery = '';
    _searchController.clear();
    setState(() {
      _placeResults = [];
      _eventResults = [];
      _isSearchingPlaces = false;
      _isSearchingEvents = false;
      _placesError = null;
      _eventsError = null;
      _isUrlMode = false;
      _urlLoading = false;
      _urlError = null;
      _lastResolvedUrl = null;
      // PROD-1852 follow-up: clearing the search returns to the default
      // Sítios-active state, not a neutral "no tab selected" form.
      _activeTab = 0;
    });
  }

  /// PROD-2116: single tap handler for add and remove. Mirrors the
  /// purely-local feel of `ChatItemsPickerSheet._toggle`:
  ///   * `_pendingTargets[id]` flips instantly; the row rebuilds with
  ///     the new state on the same frame.
  ///   * A toast fires immediately so the user gets instant
  ///     confirmation. `notificationsProvider` already has
  ///     replace-on-show semantics, so rapid taps just swap the
  ///     visible toast in place — no queue, no spam.
  ///   * A per-item debounce schedules `_commitToggle` after a short
  ///     idle window — rapid taps reset the timer, the API call
  ///     only fires once at the trailing edge.
  void _onToggle(ItemSuggestion item) {
    final l10n = Lt.of(context);

    // On first touch, snapshot what we believe the server has. Future
    // commits compare against this rather than `listsApi.isInList(...)`
    // so the per-list cache lag (between an ADD's optimistic update
    // and its background HTTP completing) can't misclassify a follow-up
    // tap as a no-op.
    _referenceState.putIfAbsent(
      item.id,
      () => ref
          .read(listsApiProvider)
          .isInList(
            widget.listId,
            eventId: item.eventId,
            venueId: item.venueId,
            googlePlaceId: item.googlePlaceId,
          ),
    );

    final current = _pendingTargets[item.id] ?? _referenceState[item.id]!;
    final newTarget = !current;
    setState(() {
      _pendingTargets[item.id] = newTarget;
    });

    // Instant feedback. The notification system replaces any
    // currently-visible toast, so mashing the toggle just cycles the
    // single on-screen toast between "added" and "removed" — never
    // queues. The trailing-edge commit (below) won't show a duplicate
    // success toast; it only surfaces toasts on failure.
    showSoko(
      ref,
      message: newTarget
          ? l10n.searchAddedToListNamed(item.name, widget.listName)
          : l10n.searchRemovedFromListNamed(item.name, widget.listName),
      variant: SokoVariant.success,
    );

    _toggleDebounceTimers[item.id]?.cancel();
    _toggleDebounceTimers[item.id] = Timer(_kToggleDebounce, () {
      _toggleDebounceTimers.remove(item.id);
      _commitToggle(item, l10n);
    });
  }

  /// Trailing-edge commit. Compares the user's final target against
  /// our local reference snapshot — NOT `listsApi.isInList(...)`,
  /// which can lag behind an in-flight ADD's background HTTP and
  /// silently turn a REMOVE into a no-op.
  ///
  /// * match → no-op (no API call)
  /// * differs (add) → `addToListsOptimistic`
  /// * differs (remove) → `removeFromLists`
  ///
  /// Success toasts are NOT shown here — `_onToggle` already showed
  /// one synchronously on tap (the user wants instant confirmation).
  /// We only surface toasts on failure, where they replace the
  /// success toast to inform the user of the rollback.
  ///
  /// `_pendingTargets[id]` is NOT cleared on a successful commit —
  /// clearing it would let the row fall back to `listsApi.isInList`,
  /// which hasn't been updated yet, causing the tint to flicker off
  /// for the ~100–500 ms the background HTTP takes to land.
  Future<void> _commitToggle(ItemSuggestion item, Lt l10n) async {
    if (_commitInFlight.contains(item.id)) {
      _toggleDebounceTimers[item.id] = Timer(_kToggleDebounce, () {
        _toggleDebounceTimers.remove(item.id);
        _commitToggle(item, l10n);
      });
      return;
    }

    final target = _pendingTargets[item.id];
    if (target == null) return;
    final reference = _referenceState[item.id] ?? false;

    if (target == reference) {
      // User ended back where they started (e.g. add → remove → add → remove).
      // No API call. `_pendingTargets[id]` stays put — it already
      // agrees with `reference`, so the row still renders the correct
      // state. The last on-tap toast also matches their net intent.
      return;
    }

    _commitInFlight.add(item.id);

    if (target) {
      // ADD path. `addToListsOptimistic` calls `onSuccess` synchronously
      // after applying the optimistic update, so we don't need to await
      // anything here.
      ref
          .read(listsProvider.notifier)
          .addToListsOptimistic(
            [widget.listId],
            item,
            source: ListSource.listSearch,
            onSuccess: () {
              if (!mounted) {
                _commitInFlight.remove(item.id);
                return;
              }
              setState(() {
                _commitInFlight.remove(item.id);
                _referenceState[item.id] = true;
              });
              // Intentionally no toast — `_onToggle` already showed
              // the success toast on tap.
            },
            onError: (errorMessage, canRetry, retry) {
              if (!mounted) {
                _commitInFlight.remove(item.id);
                return;
              }
              setState(() {
                _commitInFlight.remove(item.id);
                // Rollback: the add failed, restore the row to the
                // pre-tap reference state.
                _pendingTargets[item.id] = _referenceState[item.id] ?? false;
              });
              showSoko(
                ref,
                message: errorMessage,
                variant: SokoVariant.error,
                duration: const Duration(seconds: 5),
                action: canRetry && retry != null
                    ? SokoAction(label: l10n.addToListRetry, onTap: retry)
                    : null,
              );
            },
          );
    } else {
      // REMOVE path. The row already flipped to "not added" on tap via
      // `_pendingTargets`.
      final ok = await ref.read(listsProvider.notifier).removeFromLists([
        widget.listId,
      ], item);

      if (!mounted) {
        _commitInFlight.remove(item.id);
        return;
      }

      if (ok) {
        setState(() {
          _commitInFlight.remove(item.id);
          _referenceState[item.id] = false;
        });
        // Intentionally no toast — `_onToggle` already showed the
        // success toast on tap.
      } else {
        setState(() {
          _commitInFlight.remove(item.id);
          // Rollback to the pre-tap reference state.
          _pendingTargets[item.id] = _referenceState[item.id] ?? true;
        });
        showSoko(ref, message: l10n.addToListError, variant: SokoVariant.error);
      }
    }
  }

  /// Fire any still-pending toggles before the sheet tears down so the
  /// user's last tap isn't dropped on dismissal. We can't `await` here
  /// (dispose is synchronous) and we can't `setState` either (the state
  /// is going away) — the providers update global state regardless, and
  /// any toast would land on a sheet that's already gone.
  void _commitPendingOnDispose() {
    if (_pendingTargets.isEmpty) return;
    final listsApi = ref.read(listsApiProvider);
    final listsNotifier = ref.read(listsProvider.notifier);
    final byId = <String, ItemSuggestion>{
      for (final item in _placeResults) item.id: item,
      for (final item in _eventResults) item.id: item,
    };
    for (final entry in _pendingTargets.entries) {
      final item = byId[entry.key];
      if (item == null) continue;
      final reference =
          _referenceState[entry.key] ??
          listsApi.isInList(
            widget.listId,
            eventId: item.eventId,
            venueId: item.venueId,
            googlePlaceId: item.googlePlaceId,
          );
      if (entry.value == reference) continue;
      if (entry.value) {
        listsNotifier.addToListsOptimistic(
          [widget.listId],
          item,
          source: ListSource.listSearch,
          onSuccess: () {},
          onError: (_, __, ___) {},
        );
      } else {
        // Fire-and-forget DELETE; the global state reflects success/
        // failure by reloading owned items, and the next sheet open
        // picks up the result via `listsApi.isInList`.
        unawaited(listsNotifier.removeFromLists([widget.listId], item));
      }
    }
    _pendingTargets.clear();
    _referenceState.clear();
  }

  /// PROD-2008: open the event/venue detail by popping the sheet,
  /// pushing the detail via go_router, and letting
  /// [showAddItemsToListSheet]'s loop reopen the sheet on return.
  ///
  /// We can't render the detail above the live sheet — the sheet's
  /// overlay layer sits above any route pushed on the same Navigator,
  /// even via `rootNavigator: true`. So the only way to put the detail
  /// on top is to pop the sheet first. The search state (query, tab,
  /// scope, results, already-added items) is snapshotted into
  /// [_addToListSheetSnapshotProvider] so the reopened sheet picks up
  /// where this one left off.
  ///
  /// The [_isNavigatingToDetail] guard prevents rapid taps from
  /// snapshotting + popping more than once.
  void _openItemDetail(ItemSuggestion item) {
    if (_isNavigatingToDetail) return;
    final id = item.type == 'event' ? item.eventId : item.venueId;
    if (id == null || id.isEmpty) return;

    // No setState — the sheet is about to be popped, so a rebuild is
    // wasted work. The flag stays `true` until disposal, which is
    // exactly the behavior we want for the guard.
    _isNavigatingToDetail = true;

    // PROD-2116: flush any still-debouncing toggle taps before the
    // sheet pops so the user's most recent intent is committed to the
    // global lists state. The reopened sheet will then read it back
    // via `listsApi.isInList(...)`, and no per-item state needs to
    // travel through the snapshot.
    for (final timer in _toggleDebounceTimers.values) {
      timer.cancel();
    }
    _toggleDebounceTimers.clear();
    _commitPendingOnDispose();

    ref
        .read(_addToListSheetSnapshotProvider.notifier)
        .state = _AddToListSheetSnapshot(
      query: _searchController.text,
      activeTab: _activeTab,
      placeResults: List.unmodifiable(_placeResults),
      eventResults: List.unmodifiable(_eventResults),
      scope: _scope,
      userTouchedScope: _userTouchedScope,
      isUrlMode: _isUrlMode,
      lastResolvedUrl: _lastResolvedUrl,
    );

    final path = item.type == 'event' ? '/events/$id' : '/venues/$id';
    ref.read(_addToListSheetPendingDetailProvider.notifier).state = path;

    // Pop with `false` — no items were added by this tap. The caller
    // loop in `showAddItemsToListSheet` will reopen the sheet after the
    // detail returns, restoring the snapshot above.
    Navigator.of(context).pop(false);
  }

  /// "Adicionar a [list name]" — the lead-in stays plain and only the
  /// list-name substring carries the underline (Frame 320). The
  /// localised template is `searchAddToList("{listName}")`; we recover
  /// the list-name slice via `indexOf` so the same code works for the
  /// EN ("Add to {listName}") and PT ("Adicionar a {listName}") word
  /// orders.
  Widget _buildHeadline(Lt l10n) {
    final fullText = l10n.searchAddToList(widget.listName);
    final nameStart = fullText.indexOf(widget.listName);
    final nameEnd = nameStart + widget.listName.length;

    const baseStyle = TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w500,
      color: AppColors.sokoInk,
    );
    const underline = TextStyle(
      decoration: TextDecoration.underline,
      decorationColor: AppColors.sokoInk,
    );

    final spans = <TextSpan>[
      if (nameStart > 0) TextSpan(text: fullText.substring(0, nameStart)),
      TextSpan(text: fullText.substring(nameStart, nameEnd), style: underline),
      if (nameEnd < fullText.length)
        TextSpan(text: fullText.substring(nameEnd)),
    ];

    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    // React to late-arriving GPS/IP resolution.
    ref.listen<LocationState>(locationProvider, (prev, next) {
      final countryChanged =
          prev?.resolvedCountryCode != next.resolvedCountryCode;
      final cityChanged = prev?.resolvedCityName != next.resolvedCityName;
      if (countryChanged || cityChanged) {
        _recomputeAutoScope();
      }
    });

    // React to late-arriving home-page scope (PROD-2004). `cityScopeProvider`
    // restores async from SharedPreferences (publishes null until the read
    // lands), and `cityAutoScopeProvider` is a FutureProvider that resolves
    // user_profile/IP geocoding asynchronously.
    ref.listen<SearchScope?>(cityScopeProvider, (_, __) => _adoptHomeScope());
    ref.listen<AsyncValue<SearchScope?>>(
      cityAutoScopeProvider,
      (_, __) => _adoptHomeScope(),
    );

    return DSSheetShell(
      // Headline ("Adicionar a [list name]") rides in the header slot so it
      // sits flush below the drag handle. Matches the previous full-page
      // headline (Frame 320) — 15 px lateral, 4 px above / 16 px below.
      header: Padding(
        padding: const EdgeInsets.fromLTRB(15, 4, 15, 16),
        child: _buildHeadline(l10n),
      ),
      // Tap-outside-input dismisses the keyboard, same as the old page.
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Search row (input + location button) ───────────
            // Frame 9300 — search row + tab row stacked with a 6-px gap,
            // both rows fixed at 40 px tall.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                height: 40,
                child: Row(
                  children: [
                    Expanded(child: _buildSearchInput(l10n)),
                    const SizedBox(width: 8),
                    _buildLocationButton(l10n),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),

            // ── Tab pills ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: _TabPill(
                      icon: LucideIcons.map_pin,
                      label: l10n.searchTabPlaces,
                      isActive: _activeTab == 0,
                      activeColor: AppColors.sokoBlue,
                      onTap: _isUrlMode
                          ? null
                          : () => setState(() => _activeTab = 0),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _TabPill(
                      icon: LucideIcons.calendar,
                      label: l10n.searchTabEvents,
                      isActive: _activeTab == 1,
                      activeColor: AppColors.sokoGreen,
                      onTap: _isUrlMode
                          ? null
                          : () => setState(() => _activeTab = 1),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ── Results ────────────────────────────────────────
            Expanded(child: _buildActiveTabContent(l10n)),
          ],
        ),
      ),
      // ── Instagram footer ───────────────────────────────────────────
      // Frame 9295 — pinned to the sheet bottom so it stays visible while
      // results scroll. DSSheetShell wraps the whole tree in SafeArea so
      // the device home-indicator inset is already accounted for.
      footer: _buildInstagramFooter(l10n),
    );
  }

  // ── Search input ───────────────────────────────────────────────────

  /// Frame 9299 search field — radius 6, fill Soko/Ink @ 8 %
  /// (`#44131D` at 8 % alpha) so the input reads as a clear chip on
  /// the page surface. Icon/Zoom (Lucide search) prefix with a 6-px
  /// gap to the text; a clear button reveals as a suffix while the
  /// field is populated.
  ///
  /// Built as a single `TextField` with `prefixIcon`/`suffixIcon` rather
  /// than a manual `Row` so Flutter's `InputDecorator` lays the icons
  /// out on the text baseline — a manual Row-based layout centers the
  /// icon and the text independently, which leaves the lowercase
  /// letters sitting visually below the magnifying glass.
  Widget _buildSearchInput(Lt l10n) {
    final hasText = _searchController.text.isNotEmpty;
    // Pin all five border states to `BorderSide.none` so the global
    // `inputDecorationTheme`'s `enabledBorder`/`focusedBorder` (a 12-px
    // outlined chip used on auth/form pages) doesn't leak through — the
    // border field alone won't override state-specific borders.
    final borderless = OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide.none,
    );

    return TextField(
      controller: _searchController,
      autofocus: true,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w300,
        color: AppColors.sokoInk,
      ),
      decoration: InputDecoration(
        hintText: l10n.searchPlaceholder,
        hintStyle: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w300,
          color: AppColors.sokoInk.withValues(alpha: 0.35),
        ),
        filled: true,
        fillColor: AppColors.sokoInk8,
        border: borderless,
        enabledBorder: borderless,
        focusedBorder: borderless,
        disabledBorder: borderless,
        errorBorder: borderless,
        focusedErrorBorder: borderless,
        isDense: true,
        // Vertical 11 + ~18 px text line ≈ 40 px overall — matches the
        // adjacent `Lisboa, PT` `BtSqIco` chip so both controls in the
        // search row share the same height.
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
        prefixIcon: const Padding(
          padding: EdgeInsets.only(left: 12, right: 6),
          child: Icon(LucideIcons.search, color: AppColors.sokoInk, size: 14),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        suffixIcon: hasText
            ? Padding(
                padding: const EdgeInsets.only(left: 6, right: 12),
                child: Clickable(
                  onTap: _clearSearch,
                  child: Icon(
                    Icons.clear_rounded,
                    color: AppColors.sokoInk.withValues(alpha: 0.4),
                    size: 18,
                  ),
                ),
              )
            : null,
        suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
      ),
    );
  }

  // ── Location button (BtSqIco Icon/Pin) ────────────────────────────

  /// Design-system pin button — Frame 9299 location spec.
  ///
  /// PROD-2013: switched from the `normal` variant (Soko/Ink @ 6 % fill)
  /// to `selected` (Soko/Pink bg) so the city picker reads as the
  /// branded primary affordance of the sheet, matching the spec.
  ///
  /// Label falls back to a generic "Local" hint when no scope is set
  /// yet, so the button always has copy beside the icon.
  Widget _buildLocationButton(Lt l10n) {
    final label = _scopeShortLabel() ?? l10n.searchScopeLocal;
    return BtSqIco(
      icon: LucideIcons.map_pin,
      label: label,
      variant: BtSqIcoVariant.selected,
      onTap: _openScopePicker,
    );
  }

  /// Short display label for the location button (e.g. "Lisboa, PT").
  String? _scopeShortLabel() => switch (_scope) {
    null => null,
    SearchScopeCountry(:final countryName) => countryName,
    SearchScopeCountryCity(:final city, :final iso2) => '${city.name}, $iso2',
    SearchScopeArea(:final displayName) => displayName,
  };

  // ── Active tab content ─────────────────────────────────────────────

  Widget _buildActiveTabContent(Lt l10n) {
    if (_activeTab == 0) {
      // Places tab.
      if (!_isUrlMode &&
          _scope == null &&
          _searchController.text.trim().length >= _minQueryLength) {
        return _buildScopeBlocker(l10n);
      }
      return _buildResultsList(
        results: _placeResults,
        isSearching: _isUrlMode ? _urlLoading : _isSearchingPlaces,
        searchError: _isUrlMode
            ? (_urlError != null ? _urlErrorCopy(l10n, _urlError!) : null)
            : _placesError,
        emptyMessage: l10n.searchNoResults,
        loadingMessage: _isUrlMode ? l10n.searchUrlLoading : null,
        onRetry: _isUrlMode ? _retryResolveUrl : _performSearch,
        l10n: l10n,
      );
    }

    // Events tab.
    if (_isUrlMode) {
      return _buildUrlModeEventsPlaceholder(l10n);
    }
    return _buildResultsList(
      results: _eventResults,
      isSearching: _isSearchingEvents,
      searchError: _eventsError,
      emptyMessage: l10n.searchNoResults,
      onRetry: _performSearch,
      l10n: l10n,
    );
  }

  Widget _buildResultsList({
    required List<ItemSuggestion> results,
    required bool isSearching,
    required String? searchError,
    required String emptyMessage,
    required Lt l10n,
    String? loadingMessage,
    VoidCallback? onRetry,
  }) {
    // Pre-query empty state — Figma frame 6353:28356 shows a blank
    // content area between tabs and the Instagram footer (no centred
    // icon / hint). Only the Sítios scope-blocker survives as the
    // exception, which is handled by [_buildActiveTabContent].
    if (!_isUrlMode && _searchController.text.trim().length < _minQueryLength) {
      return const SizedBox.shrink();
    }

    if (isSearching) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.sokoInk,
              ),
            ),
            if (loadingMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                loadingMessage,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w300,
                  color: AppColors.sokoInk.withValues(alpha: 0.5),
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (searchError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 40,
              color: AppColors.sokoRed,
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                searchError,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w300,
                  color: AppColors.sokoInk.withValues(alpha: 0.5),
                ),
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: Text(l10n.searchUrlRetry)),
            ],
          ],
        ),
      );
    }

    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 40,
              color: AppColors.sokoInk.withValues(alpha: 0.15),
            ),
            const SizedBox(height: 10),
            Text(
              emptyMessage,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w300,
                color: AppColors.sokoInk.withValues(alpha: 0.35),
              ),
            ),
          ],
        ),
      );
    }

    // Subscribe to listsProvider so when another surface commits an
    // optimistic add for one of these results, this list rebuilds and
    // the card flips to its added state via `api.isInList` below.
    ref.watch(listsProvider);
    final listsApi = ref.read(listsApiProvider);

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: results.length,
      itemBuilder: (context, index) {
        final item = results[index];
        // PROD-2116: `_pendingTargets` carries the user's latest tap
        // intent and wins over the cache. The map is cleared once the
        // debounced commit reconciles, so the row's "added" state
        // remains correct without a transient mismatch during the
        // debounce window or while a remove DELETE is in flight.
        final isAdded =
            _pendingTargets[item.id] ??
            listsApi.isInList(
              widget.listId,
              eventId: item.eventId,
              venueId: item.venueId,
              googlePlaceId: item.googlePlaceId,
            );
        return SearchResultCard(
          item: item,
          onTap: () => _openItemDetail(item),
          // No more "adding" intermediate UI — the row flips instantly
          // on tap via `_pendingTargets` and the in-flight commit is
          // invisible to the user.
          isAdding: false,
          isAdded: isAdded,
          onAdd: () => _onToggle(item),
          onRemove: () => _onToggle(item),
        );
      },
    );
  }

  String _urlErrorCopy(Lt l10n, ResolveUrlFailure failure) {
    switch (failure) {
      case ResolveUrlInvalid():
        return l10n.searchUrlErrorInvalid;
      case ResolveUrlNotFound():
        return l10n.searchUrlErrorNotFound;
      case ResolveUrlUnrecognized():
        return l10n.searchUrlErrorUnrecognized;
      case ResolveUrlRateLimited():
        return l10n.searchUrlErrorRateLimited;
      case ResolveUrlNetworkError():
        return l10n.searchUrlErrorNetwork;
      case ResolveUrlUnknown():
        return l10n.searchUrlErrorNetwork;
    }
  }

  Widget _buildUrlModeEventsPlaceholder(Lt l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          l10n.searchUrlEventsDisabled,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w300,
            color: AppColors.sokoInk.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }

  Widget _buildScopeBlocker(Lt l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.location_searching,
              size: 40,
              color: AppColors.sokoInk.withValues(alpha: 0.15),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.searchScopeMustPickCountryTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.searchScopeMustPickCountryBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w300,
                color: AppColors.sokoInk.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 14),
            // Design-system CTA (Figma `Bt_Sq_Ico` / 4108:2975). Uses
            // the `normal` (Soko/Ink @ 6 % fill) variant — this is a
            // neutral secondary action, not the sheet's primary
            // affordance (the search field is).
            BtSqIco(
              icon: Icons.public,
              label: l10n.searchScopePickCountryCta,
              variant: BtSqIcoVariant.normal,
              onTap: _openScopePicker,
            ),
          ],
        ),
      ),
    );
  }

  // ── Instagram footer (Frame 9295) ──────────────────────────────────

  /// Frame 9295 footer block — a 13 px hint above a BtSqIco CTA. No
  /// top border (the Figma frame floats in the page, not separated by
  /// a rule). Vertical gap between hint and CTA is 10 px.
  Widget _buildInstagramFooter(Lt l10n) {
    return Padding(
      // Canonical 14 px bottom gap (matches every other DS sheet
      // footer); 15 px sides preserved per the existing Frame 9295
      // typography spec.
      padding: const EdgeInsets.fromLTRB(15, 12, 15, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.searchInstagramShareHint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w300,
              color: AppColors.sokoInk.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 10),
          BtSqIco(
            icon: LucideIcons.instagram,
            label: l10n.searchInstagramShareCta,
            variant: BtSqIcoVariant.normal,
            // Pop the sheet route with `true`; the caller (e.g.
            // `list_page_screen._handleAdd`) checks for `result == true`
            // and chains the Instagram share sheet from there.
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
  }
}

// ── Tab pill button ────────────────────────────────────────────────────

/// Frame 9299 tab card — square 6-radius rectangle, height 40, padding
/// 10 v / 14 h, gap 8. Inactive: transparent fill + 1 px solid
/// #44131D14 (Soko/Ink @ 8 %). Active: keep colored fill (Soko/Blue for
/// Sítios, Soko/Green for Eventos) so the picked tab still pops.
class _TabPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final VoidCallback? onTap;

  const _TabPill({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.activeColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isActive ? activeColor : Colors.transparent;
    final borderColor = isActive ? Colors.transparent : _kSokoInkAt8;
    final textColor = AppColors.sokoInk;

    return Clickable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: borderColor, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          // Frame 9300 — icon + label flush to the left edge of the
          // card (no centering). The card still claims half the row
          // width via the parent's Expanded.
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Icon(icon, size: 14, color: textColor),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w300,
                letterSpacing: -0.14,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Geo params helper (copied from legacy sheet) ───────────────────────

/// Geo bundle forwarded by `_searchPlaces` / `_searchEvents` to `SearchApi`.
/// Public (no underscore) so [geoParamsFromScope] can be unit-tested without
/// `@visibleForTesting` complications across the test-import boundary.
class GeoParams {
  final double? latitude;
  final double? longitude;
  final double? radiusMeters;
  final String? country;
  const GeoParams({
    this.latitude,
    this.longitude,
    this.radiusMeters,
    this.country,
  });
}

/// Pure mapping from a [SearchScope] (+ optional GPS-auto location) to the
/// [GeoParams] shape that `_searchEvents` / `_searchPlaces` forward to
/// `SearchApi`. Extracted so the scope→geo logic can be unit-tested without
/// mounting the sheet or wiring a [WidgetRef].
///
/// `autoLocation` is only consulted for the `SearchScopeCountryCity(isAuto:
/// true)` branch — callers pass `null` for every other case.
///
/// PROD-4065: `deviceFix`/`resolvedCountry` are a coordinate fallback applied
/// ONLY to the two coord-less cases (no scope, and a country-only scope). Those
/// cases otherwise forward no coordinates, so the backend fast picker — which
/// intentionally ignores the country filter — degrades to a global name match
/// (an MX user searching "canica" gets Portugal venues). Attaching the live
/// device fix biases retrieval to where the user actually is. The city/area
/// branches already carry coordinates and are left untouched.
@visibleForTesting
GeoParams geoParamsFromScope(
  SearchScope? scope,
  LocationSnapshot? autoLocation, {
  LocationSnapshot? deviceFix,
  String? resolvedCountry,
}) {
  switch (scope) {
    case null:
      if (deviceFix != null) {
        return GeoParams(
          latitude: deviceFix.lat,
          longitude: deviceFix.lon,
          country: resolvedCountry,
        );
      }
      return const GeoParams();
    case SearchScopeCountry(:final iso2):
      if (deviceFix != null) {
        return GeoParams(
          country: iso2,
          latitude: deviceFix.lat,
          longitude: deviceFix.lon,
        );
      }
      return GeoParams(country: iso2);
    case SearchScopeCountryCity(:final iso2, :final city, :final isAuto):
      if (isAuto) {
        return GeoParams(
          country: iso2,
          latitude: autoLocation?.lat,
          longitude: autoLocation?.lon,
          radiusMeters: 20000.0,
        );
      }
      return GeoParams(
        country: iso2,
        latitude: city.latitude,
        longitude: city.longitude,
        radiusMeters: 20000.0,
      );
    case SearchScopeArea(
      :final centerLat,
      :final centerLng,
      :final radiusMeters,
    ):
      // Map-picker area scope: center + shape-aware radius, no country.
      return GeoParams(
        latitude: centerLat,
        longitude: centerLng,
        radiusMeters: radiusMeters,
      );
  }
}

// ── Home-scope helper (PROD-2004) ──────────────────────────────────────

/// Pure scope-selection used by [_AddItemsToListSheetState._adoptHomeScope].
/// Extracted so the priority + normalization logic is unit-testable without
/// mounting the (heavily provider-dependent) sheet widget.
///
/// Priority:
///   1. [cityScope] — explicit pick on the home action-bar pill.
///   2. [cityAutoScope] — profile/IP-derived auto scope.
///   3. [gpsAutoScope] — GPS/IP-resolved scope from `locationProvider`.
///
/// When (1) or (2) is non-null, the returned scope is normalized to
/// `isAuto: false`. This matters because
/// [_AddItemsToListSheetState._geoParamsForCurrentScope] takes a special
/// branch for `isAuto: true` city scopes that reads the device's last GPS
/// fix instead of the city centroid — exactly what would reintroduce the
/// PROD-2004 bug for a profile-derived Porto on a user whose GPS is in
/// Lisbon.
@visibleForTesting
SearchScope? computeHomeScope({
  required SearchScope? cityScope,
  required SearchScope? cityAutoScope,
  required SearchScope? gpsAutoScope,
}) {
  final home = cityScope ?? cityAutoScope;
  if (home == null) return gpsAutoScope;
  return switch (home) {
    SearchScopeCountry s => s.copyWith(isAuto: false),
    SearchScopeCountryCity s => s.copyWith(isAuto: false),
    // Map-picker area scopes are always explicit picks; pass through.
    SearchScopeArea s => s,
  };
}
