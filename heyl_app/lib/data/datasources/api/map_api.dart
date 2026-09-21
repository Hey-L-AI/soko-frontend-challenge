import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/discovery_facets.dart';
import '../../models/map_pin.dart';
import '../../models/map_suggest.dart';
import '../../models/models.dart';
import 'api_client.dart';
import 'search_result_mappers.dart';

/// PROD-2736 — the maps v0 data endpoints: slim count-first pins
/// (`POST /map/pins`) + by-ID grid hydration (`POST /map/hydrate`).
///
/// [getMapPins] takes an optional **`scope`** (PROD-2737) — `yours` / `following`
/// / omit (= `all`, the global corpus). `yours`/`following` need an authenticated
/// (non-guest) user; a guest gets 422 `scope_requires_auth` (moot on the
/// admin-only v0 map). The response shape is identical across scopes, so
/// hydration by id is unaffected — `/map/hydrate` needs no scope. The map uses
/// the **two-layer `facet_filters`** vocabulary only (never the legacy flat
/// `facets`). Request bodies are strict (`extra: forbid`) — unknown fields /
/// facet ids → 422.
class MapApi {
  final ApiClient _apiClient;

  MapApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// `POST /map/pins` — slim pins for one camera settle. [entity] omitted =
  /// both. Dates filter **events only**. `radius_meters` is clamped to the
  /// API window (100–50 000 m) to avoid a 422 at the zoom edges.
  Future<MapPinsResponse> getMapPins({
    required double latitude,
    required double longitude,
    required double radiusMeters,
    String? entity, // 'venue' | 'event' | null = both
    String? scope, // 'yours' | 'following' | 'list' | null = all (default)
    // PROD-3565 — the list whose items are the corpus, when [scope] is 'list'.
    // Accepts the list UUID **or** its slug. The backend REJECTS this with 422
    // on any other scope (a silently-ignored list_id would let the client
    // believe its request was bounded when it wasn't), so callers must source
    // it from `MapQuery.listIdWire`, which is null off list mode by
    // construction — never from `activeListId` directly.
    String? listId,
    // PROD-2851/2849: opt into the backend's radius-skip for bounded scopes.
    // When true AND scope is yours/following, the 50 km distance gate is
    // skipped so ALL saved/followed items return (any zoom). No-op for `all`.
    bool ignoreRadius = false,
    List<FacetPair>? facetFilters,
    List<String>? lenses,
    String? query,
    String? startDate,
    String? endDate,
    // PROD-2906 (A6) — v2 opt-in: when [pinsVersion] >= 2 the server computes
    // `selection` (server-side grid selection), gated by the backend flag
    // `MAP_PINS_V2_SELECTION`. Sending it is SAFE anywhere — flag off ⇒
    // `selection` null ⇒ the FE falls back to `selectPins`. v2 REQUIRES the
    // full viewport rect + [zoom] (else the server 422s), so the caller only
    // passes pinsVersion:2 once it has settled bounds.
    int? pinsVersion,
    double? viewportSwLat,
    double? viewportSwLng,
    double? viewportNeLat,
    double? viewportNeLng,
    double? zoom,
    double? targetCellPx,
    // PROD-2971 — admin-only diagnostics. When [debug] is true the server
    // returns a top-level `debug` block (search area + retrieval + per-pin
    // scoring). ADMIN ONLY: a non-admin sending `debug=true` gets HTTP 422, so
    // the caller must gate on `role == admin` before setting this. [debugCellCounts]
    // opts into exact per-cell grid counts (costly, ~+50–100 ms); ignored unless
    // [debug] is true. Both omitted from the body when false → the normal
    // request path is byte-for-byte unchanged.
    bool debug = false,
    bool debugCellCounts = false,
    // PROD-2948 (FE-2) — ADMIN-ONLY personalization strength
    // ('low'|'medium'|'high'; null/'off' = omit). Sent to BE-5's axis_shadow
    // scorer; non-admins are clamped to off server-side, so this is inert unless
    // the caller is an admin AND the server axis flags are on. Independent of the
    // v2 selection block (rides on the relevance scorer, any pins_version).
    String? personalizationLevel,
    CancelToken? cancelToken,
  }) async {
    final body = <String, dynamic>{
      'latitude': latitude,
      'longitude': longitude,
      'radius_meters': radiusMeters.clamp(100.0, 50000.0),
    };
    if (entity != null) body['entity'] = entity;
    if (scope != null && scope.isNotEmpty) body['scope'] = scope;
    // Omitted unless present → every non-list request body stays byte-for-byte
    // unchanged (same convention as ignore_radius / debug / personalization).
    if (listId != null && listId.isNotEmpty) body['list_id'] = listId;
    // Omit when false → `all`-scope request bodies stay byte-for-byte unchanged.
    if (ignoreRadius) body['ignore_radius'] = true;
    if (facetFilters != null && facetFilters.isNotEmpty) {
      body['facet_filters'] = facetFilters.map((f) => f.toJson()).toList();
    }
    if (lenses != null && lenses.isNotEmpty) body['lenses'] = lenses;
    if (query != null && query.isNotEmpty) body['query'] = query;
    if (startDate != null && startDate.isNotEmpty) {
      body['start_date'] = startDate;
    }
    if (endDate != null && endDate.isNotEmpty) body['end_date'] = endDate;
    // PROD-2948: admin-only personalization strength. Omitted for null/off so the
    // default (and every release build) request body stays byte-for-byte unchanged.
    if (personalizationLevel != null && personalizationLevel.isNotEmpty) {
      body['personalization_level'] = personalizationLevel;
    }
    // v2 fields — only when opted in. The viewport rect + zoom are mandatory for
    // v2; `target_cell_px` is sent explicitly (the FE owns that one) so the
    // server never drifts from the FE's `kTargetCellPx` even if its defaults
    // change.
    //
    // PROD-3731: `selection_cap` used to ride along here under the same
    // justification, and that justification was false. The backend reads the
    // field on **no** code path — v1 or v2 (`git grep req.selection_cap` on
    // heyl-backend is empty; it is declared at `api_map.py:214` and consulted
    // nowhere). For v2 the applied cap comes from `MAP_PINS_SELECTION_BANDS` via
    // `resolve_selection_band(scope, zoom)` — for `scope=all`, 8 below z16 and
    // 20 above. Sending our own number described nothing, and PROD-3656 sized
    // its promotion budget against it (25 for `all`) while the server drew 8,
    // which is what made the map's pin set churn. See PROD-3701 for the backend
    // half. ⚠️ `selectionCapForSource()` is NOT dead — it is still the right cap
    // for the client-side `selectPins` fallback; only the request use was wrong.
    if (pinsVersion != null && pinsVersion >= 2) {
      body['pins_version'] = pinsVersion;
      if (viewportSwLat != null) body['viewport_sw_lat'] = viewportSwLat;
      if (viewportSwLng != null) body['viewport_sw_lng'] = viewportSwLng;
      if (viewportNeLat != null) body['viewport_ne_lat'] = viewportNeLat;
      if (viewportNeLng != null) body['viewport_ne_lng'] = viewportNeLng;
      if (zoom != null) body['zoom'] = zoom;
      if (targetCellPx != null) body['target_cell_px'] = targetCellPx;
    }
    // PROD-2971 — only ever set for an admin (caller-enforced). Omit when false
    // so non-debug bodies stay unchanged; `debug_cell_counts` rides along only
    // when debug is on.
    if (debug) {
      body['debug'] = true;
      if (debugCellCounts) body['debug_cell_counts'] = true;
    }

    final response = await _dio.post(
      ApiConstants.mapPins,
      data: body,
      cancelToken: cancelToken,
    );
    return MapPinsResponse.fromJson(response.data as Map<String, dynamic>);
  }

  /// `POST /map/hydrate` — full result cards for a window of pin ids. The
  /// cards are the identical shape to `/places/search` + `/events/search`
  /// results, so they map through [itemSuggestionFromPlaceResult] /
  /// [itemSuggestionFromEventResult]. Order is preserved by the backend; send
  /// a window (~20–30 ids), and the SAME [facetFilters] the pins used.
  ///
  /// ⚠️ [eventOccurrenceIds] are the **event pin ids** (= occurrence ids), not
  /// event ids. The backend silently drops stale/now-private ids, so the
  /// returned lists may be shorter than the ids sent — key by `id`.
  Future<({List<ItemSuggestion> venues, List<ItemSuggestion> events})>
  getMapHydrate({
    List<String> venueIds = const [],
    List<String> eventOccurrenceIds = const [],
    List<FacetPair>? facetFilters,
    List<String>? lenses,
    CancelToken? cancelToken,
  }) async {
    final body = <String, dynamic>{
      'venue_ids': venueIds,
      'event_occurrence_ids': eventOccurrenceIds,
    };
    if (facetFilters != null && facetFilters.isNotEmpty) {
      body['facet_filters'] = facetFilters.map((f) => f.toJson()).toList();
    }
    if (lenses != null && lenses.isNotEmpty) body['lenses'] = lenses;

    final response = await _dio.post(
      ApiConstants.mapHydrate,
      data: body,
      cancelToken: cancelToken,
    );
    final data = response.data as Map<String, dynamic>;

    List<ItemSuggestion> parse(
      String key,
      ItemSuggestion? Function(Map<String, dynamic>) mapper,
    ) => ((data[key] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(mapper)
        .whereType<ItemSuggestion>()
        .toList(growable: false);

    return (
      venues: parse('venues', itemSuggestionFromPlaceResult),
      events: parse('events', itemSuggestionFromEventResult),
    );
  }

  /// `POST /map/suggest` — name-match typed suggestions for the v2 search
  /// bar (PROD-3497; contract PROD-3494). [query] must be ≥3 chars after
  /// trimming (the ladder guarantees this — shorter would 422) and
  /// [latitude]/[longitude] are the map center (proximity bias, never a
  /// gate). Guest-allowed. Locations are NOT served here — the caller
  /// composes them via `GeoApi.searchAreas`.
  ///
  /// PROD-3662 — [scope]/[listId] bound the suggestions to the map's active
  /// "De quem?" corpus, using the SAME vocabulary as `/map/pins`, so both
  /// endpoints mean the same thing by a scope. Pass `MapQuery.scopeWire` /
  /// `MapQuery.listIdWire` and nothing else: those getters are gated on
  /// `isListMode` together, which is what keeps the pair inseparable.
  ///
  /// Both are omitted when null rather than sent as `null`, and that is
  /// load-bearing in two directions: an omitted `scope` is the server's `all`
  /// default (byte-identical to the pre-PROD-3562 response), while a `list_id`
  /// riding along on any other scope is a **422**, not a harmless extra field.
  ///
  /// PROD-3652 — [domain] restricts the response to ONE domain and serves a
  /// deeper page of it (up to 25 instead of 10); the other buckets come back
  /// empty and are not even retrieved, so a scoped call is *cheaper* than an
  /// unscoped one. Omit for the unscoped three-domain response.
  ///
  /// Orthogonal to [scope]: `domain` picks WHICH block, `scope` bounds the
  /// corpus every block draws from. They compose.
  ///
  /// ⚠️ `location` is deliberately NOT a value — locations are served by
  /// `/geo/areas` + `/geo/search`, which already have their own deep tier. The
  /// wire vocabulary is **plural** (`venues`/`events`/`lists`) while item
  /// `type` stays **singular** (`venue`/`event`/`list`); an unknown value is a
  /// 422, never a silently unfiltered response.
  ///
  /// ⚠️ **Version gate.** The backend request model is `extra="forbid"`, so any
  /// field a deployment doesn't know fails EVERY suggest call — all domains,
  /// every scope, on every keystroke. There is no backend-side mitigation; ship
  /// order (backend first) is the only lever, and it fires again for whatever
  /// field is added here next.
  ///
  /// Both fields on this endpoint are **discharged**: PROD-3562's `scope`/
  /// `list_id` reached production 2026-08-04, and `domain` was verified in
  /// production the same day. The probe, which needs no token and has no side
  /// effects (it is generated from the live request model, so it answers "does
  /// the deployed backend know this field?" directly):
  ///
  /// ```
  /// curl -s https://heyl-backend-production.onrender.com/openapi.json \
  ///   | jq '.components.schemas.MapSuggestRequest.properties | keys'
  /// ```
  Future<MapSuggestResponse> suggest({
    required String query,
    required double latitude,
    required double longitude,
    MapSuggestDomain? domain,
    String? scope,
    String? listId,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.post(
      ApiConstants.mapSuggest,
      data: <String, dynamic>{
        'query': query,
        'latitude': latitude,
        'longitude': longitude,
        if (domain != null) 'domain': domain.wire,
        if (scope != null) 'scope': scope,
        if (listId != null) 'list_id': listId,
      },
      cancelToken: cancelToken,
    );
    return MapSuggestResponse.fromJson(response.data as Map<String, dynamic>);
  }

  /// `GET /discovery/facets` — the two-layer facet catalog (parents +
  /// entity-specific children) for the Tema picker. Guest-safe.
  Future<DiscoveryFacets> getDiscoveryFacets({CancelToken? cancelToken}) async {
    final response = await _dio.get(
      ApiConstants.discoveryFacets,
      cancelToken: cancelToken,
    );
    return DiscoveryFacets.fromJson(response.data as Map<String, dynamic>);
  }
}
