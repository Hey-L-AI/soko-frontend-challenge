import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../data/models/map_pin.dart';
import '../../../data/models/models.dart';
import '../../../providers/auth_provider.dart';
import '../models/map_active_search.dart';
import '../utils/map_boundary_scope.dart';
import '../utils/map_highlight_geometry.dart' show LatLngBounds;
import 'map_execution_command_provider.dart';
import 'map_query_provider.dart';
import 'map_search_provider.dart';
import 'map_ui_state_provider.dart';

/// PROD-3498 — the zoom a venue/event selection flies to (Decision #18,
/// "fly ~z17 + promote the pin"). Street level: close enough that the promoted
/// pin is unmistakably *the* result, without the near-empty view past ~18.
const double kMapSearchFlyZoom = 17.0;

/// Zoom used when a location resolves to a point, or to a box too small to
/// frame — neighbourhood scale, matching where the location picker settles.
const double kMapLocationPointZoom = 14.0;

/// PROD-3568 — whose Zine was opened, as far as the opening path can tell.
///
/// Deliberately three-valued, and deliberately reported alongside
/// [MapListOpenSource]: the two entry points cannot determine this to the same
/// standard, so the two properties are only meaningful together.
///
/// - **History** resolves the whole list anyway (a `getList` 404 IS the
///   Decision #21 staleness probe), so it compares owner ids and is EXACT.
/// - **The dropdown** skips that round-trip on purpose (PROD-3566 — `/map/pins`
///   accepts a slug, so nothing needs resolving before the camera moves), and
///   since PROD-3647 it does not need to: `/map/suggest` returns `is_own`,
///   decided server-side by the same strict `owner_id` match. So both paths now
///   mean EXACTLY the same thing and `ownership` is comparable across `source`.
///
/// A **collaborative** list is [other] on both paths. That is the whole point,
/// not an oversight — a wider definition on the suggest side would restore the
/// divergence the two rules exist to remove. Do not "fix" it.
///
/// [unknown] is retained but is no longer produced by the dropdown. It survives
/// for PostHog history (data before 2026-08-07 carries it) and for the one live
/// hole left: an authenticated viewer whose own id is missing on the history
/// path.
enum MapListOwnership {
  own('own'),
  other('other'),
  unknown('unknown');

  const MapListOwnership(this.wire);

  /// Analytics property value.
  final String wire;
}

/// PROD-3568 — which surface opened the Zine. See [MapListOwnership] for why
/// this is not decoration: it is what makes `ownership` readable.
enum MapListOpenSource {
  suggest('suggest'),
  history('history');

  const MapListOpenSource(this.wire);

  /// Analytics property value.
  final String wire;
}

/// PROD-3568 — the history path's EXACT ownership verdict, available because
/// that path resolves the whole list anyway (Decision #21's staleness probe).
/// A signed-out viewer has no id, which the executor separately normalizes to
/// [MapListOwnership.other] — a guest owns nothing.
MapListOwnership mapListOwnershipFromIds({
  required String? viewerId,
  required String ownerId,
}) {
  if (viewerId == null || viewerId.isEmpty) return MapListOwnership.unknown;
  return viewerId == ownerId ? MapListOwnership.own : MapListOwnership.other;
}

/// Per-type map execution seam for the v2 search bar.
///
/// PROD-3499 (past-searches UI) resolves a tapped history row to a fresh
/// entity and dispatches it here; PROD-3497's typed dropdown dispatches its
/// selections the same way. [MapSearchExecutorImpl] is the real implementation
/// (PROD-3498): camera moves, pin promotion, the keyword `/map/pins` query,
/// the active-search bar chrome, and exiting focused mode on execution.
///
/// Contract notes:
/// - The executor owns all post-execution UX, including exiting focused mode;
///   callers only resolve, record recency, and dispatch.
/// - That ordering is load-bearing: `mapCameraFrozenProvider` watches
///   `mapSearchProvider.focused`, so nothing the camera does commits until the
///   mode is closed.
abstract class MapSearchExecutor {
  /// Keyword content-search over the current viewport/scope/filters
  /// (camera does not move).
  Future<void> executeKeyword(String queryText);

  /// Fly (~z17) + promote/highlight the pin only — detail sheet opens on a
  /// second tap (Decision #18). Null coords → sheet without a camera move.
  ///
  /// Takes loose fields rather than a resolved entity so the typed dropdown
  /// can execute straight from its `/map/suggest` item without a round-trip
  /// before the camera moves; a history tap resolves anyway (a 404 IS the
  /// staleness signal, Decision #21) and passes the resolved values down.
  Future<void> executeVenue({
    required String venueId,
    required String label,
    double? latitude,
    double? longitude,
    String? imageUrl,
  });

  /// Same as venue at the event's coords (Decision #18). See [executeVenue]
  /// for why this takes loose fields.
  ///
  /// [occurrenceId] is the `/map/pins` pin id, which only the typed dropdown
  /// has: history stores the canonical event id per the PROD-3495 contract,
  /// and no detail response carries an occurrence id. Absent it, the
  /// executor resolves the second tap from its own active-search state.
  Future<void> executeEvent({
    required String eventId,
    required String label,
    String? occurrenceId,
    double? latitude,
    double? longitude,
    String? imageUrl,
  });

  /// Camera only — boundary fits bounds, point centers+zooms; app-wide
  /// location scope stays with the existing leave-map prompt flow
  /// (Decision #19).
  Future<void> executeLocation(ResolvedArea area);

  /// List-on-map mode with filters reset (Decision #20 / #46): ONE list
  /// becomes the map's corpus, and the camera frames it.
  ///
  /// PROD-3566 — takes **loose fields**, like [executeVenue]/[executeEvent],
  /// and for the same reason: `/map/pins` accepts the list's UUID *or* its
  /// slug, and `/map/suggest` already hands the dropdown both id and name, so
  /// nothing has to be resolved before the map can move. A history tap still
  /// resolves — there a `getList` 404 **is** the staleness signal (Decision
  /// #21) — and passes the resolved values down.
  ///
  /// The bar is deliberately left at its **placeholder**: per Decision #46 a
  /// list is a corpus scope shown in "De quem?" (PROD-3567's chrome), never an
  /// active search in the bar. So this clears the previous search's chrome
  /// rather than replacing it.
  ///
  /// PROD-3568 — this method also emits `map_list_opened`, so it takes what the
  /// caller knows about the list's owner and derives the rest itself.
  ///
  /// [source] is **required** so a future producer fails to compile rather than
  /// silently reporting the wrong surface. [ownerId] and [isOwn] are the raw
  /// facts, not a verdict, and each path supplies the one it has: history
  /// resolved the list so it passes [ownerId] (exact); the dropdown passes
  /// `/map/suggest`'s [isOwn] (PROD-3647 — exact too, decided server-side).
  /// Passing neither reports `other`, the same as a guest: a caller that knows
  /// nothing must not be able to claim a list is the viewer's.
  ///
  /// Deliberately NOT a pre-computed ownership: deriving it needs the auth
  /// state, and reading a provider at the history call site would put that read
  /// inside the re-executor's `try`, where a throw is swallowed as
  /// [MapPastSearchTapOutcome.transientError] — a measurement turning a working
  /// list open into a "no longer available" toast. Analytics must not be able
  /// to fail execution.
  Future<void> executeList({
    required String listId,
    required String name,
    required MapListOpenSource source,
    String? ownerId,
    bool? isOwn,
  });
}

/// PROD-3498 — the real executor.
class MapSearchExecutorImpl implements MapSearchExecutor {
  MapSearchExecutorImpl(this._ref);

  final Ref _ref;

  /// Monotonic command id. Two identical selections in a row must both move
  /// the camera, so the screen keys off this rather than the command's value
  /// (`docs/learnings/mapbox-imperative-tokens-fit-vs-center.md`).
  int _token = 0;

  /// Decision #30 — one active search at a time: a new selection **replaces**
  /// the previous, so every execution starts by undoing the last one's map
  /// effects. Committing the active search also leaves focused mode, which is
  /// what unfreezes the camera for the command that follows.
  void _commit(MapActiveSearch active) {
    _ref.read(mapSearchProvider.notifier).setActive(active);
    _ref.read(mapPromotedPinProvider.notifier).state = null;
    // PROD-3566 — any other execution supersedes a pending list fit, or a list
    // response landing afterwards would frame the whole list over the venue
    // the user just flew to. Trigger bookkeeping alone can't catch this: the
    // `setKeyword('')` below NO-OPS when the list entry already emptied the
    // keyword, so `_lastTrigger` would still read 'list'. Clearing it here
    // covers every execution type at once, which is why it lives in `_commit`.
    _ref.read(mapPendingListFitProvider.notifier).state = null;
    if (active.type != MapSearchTargetType.keyword) {
      // PROD-3500 — this clear is a SIDE EFFECT of picking an entity, not a
      // keyword search. Without the explicit trigger the refetch it causes
      // would report `map_area_searched{trigger:'keyword'}`, inflating the
      // keyword slice with venue/event/location picks (only when a keyword
      // happened to be active — `setKeyword` no-ops otherwise, which is why
      // this reads as intermittent).
      _ref.read(mapQueryProvider.notifier).setKeyword('', trigger: 'selection');
    }
  }

  void _emit(MapExecutionCommand Function(int token) build) {
    _ref.read(mapExecutionCommandProvider.notifier).state = build(++_token);
  }

  void _promote(MapPin pin) {
    _ref.read(mapPromotedPinProvider.notifier).state = pin;
  }

  @override
  Future<void> executeKeyword(String queryText) async {
    final query = queryText.trim();
    if (query.isEmpty) return;
    _commit(MapActiveSearch(type: MapSearchTargetType.keyword, label: query));
    // The whole effect: the query gains a keyword and the pins refetch over
    // the camera the user is already looking at (Decision #29). Query writes
    // are never camera-frozen, so this lands immediately.
    _ref.read(mapQueryProvider.notifier).setKeyword(query);
    // PROD-3500 (H2) — the v1 field's `map_filter_change` keyword source,
    // re-attached here rather than at any producer: this method is the one
    // place every keyword search passes through (general row, Enter,
    // past-search re-execution), so the count stays whole no matter how the
    // producers change. `setKeyword` above also tags the resulting
    // `map_area_searched` as trigger 'keyword'.
    _trackKeywordFilterChange();
  }

  void _trackKeywordFilterChange() {
    unawaited(
      _ref
          .read(unifiedAnalyticsProvider)
          .trackMapFilterChange(filter: 'keyword'),
    );
  }

  @override
  Future<void> executeVenue({
    required String venueId,
    required String label,
    double? latitude,
    double? longitude,
    String? imageUrl,
  }) async {
    _commit(
      MapActiveSearch(
        type: MapSearchTargetType.venue,
        label: label,
        targetId: venueId,
      ),
    );
    if (latitude == null || longitude == null) {
      _emit((t) => MapOpenVenueSheetCommand(token: t, venueId: venueId));
      return;
    }
    _promote(
      MapPin(
        id: venueId,
        entity: 'venue',
        lat: latitude,
        lng: longitude,
        name: label,
      ),
    );
    _emit(
      (t) => MapEaseToCommand(
        token: t,
        lat: latitude,
        lng: longitude,
        zoom: kMapSearchFlyZoom,
      ),
    );
  }

  @override
  Future<void> executeEvent({
    required String eventId,
    required String label,
    String? occurrenceId,
    double? latitude,
    double? longitude,
    String? imageUrl,
  }) async {
    _commit(
      MapActiveSearch(
        type: MapSearchTargetType.event,
        label: label,
        targetId: eventId,
        eventId: eventId,
      ),
    );
    if (latitude == null || longitude == null) {
      _emit((t) => MapOpenEventSheetCommand(token: t, eventId: eventId));
      return;
    }
    // Event pins are keyed by OCCURRENCE id everywhere else on this page
    // (`map_pin.dart`), so prefer it — the promoted pin then coincides with a
    // real one instead of doubling it. The canonical-id fallback still draws
    // the right pin; the second tap resolves through the active search's
    // [MapActiveSearch.eventId] (see `map_screen.dart`'s `_onPinTap`).
    _promote(
      MapPin(
        id: occurrenceId ?? eventId,
        entity: 'event',
        lat: latitude,
        lng: longitude,
        name: label,
      ),
    );
    _emit(
      (t) => MapEaseToCommand(
        token: t,
        lat: latitude,
        lng: longitude,
        zoom: kMapSearchFlyZoom,
      ),
    );
  }

  @override
  Future<void> executeLocation(ResolvedArea area) async {
    final boundary = area.boundary;
    _commit(
      MapActiveSearch(
        type: MapSearchTargetType.location,
        label: boundaryPlaceLabel(boundary),
        targetId: boundary.id,
      ),
    );
    final bbox = boundary.bbox;
    if (area.kind == AreaKind.point || isDegenerateBbox(bbox)) {
      _emit(
        (t) => MapEaseToCommand(
          token: t,
          lat: boundary.centroidLat,
          lng: boundary.centroidLon,
          zoom: kMapLocationPointZoom,
        ),
      );
      return;
    }
    _emit(
      (t) => MapFitBoxCommand(
        token: t,
        box: LatLngBounds(
          south: bbox.south,
          west: bbox.west,
          north: bbox.north,
          east: bbox.east,
        ),
      ),
    );
  }

  @override
  Future<void> executeList({
    required String listId,
    required String name,
    required MapListOpenSource source,
    String? ownerId,
    bool? isOwn,
  }) async {
    // Not `_commit`: that SETS an active search, and Decision #46 keeps the
    // list out of the bar entirely. `clearActive()` is the right primitive —
    // one state write that drops the previous search's chrome AND leaves
    // focused mode, which is the ordering `mapCameraFrozenProvider` depends on
    // (nothing the camera does commits while the bar still has focus).
    _ref.read(mapSearchProvider.notifier).clearActive();
    _ref.read(mapPromotedPinProvider.notifier).state = null;

    // The corpus change. `setList` resets type/date/facets/keyword to their
    // DEFAULTS in one write (Decisions #20/#28), so exactly one refetch.
    _ref.read(mapQueryProvider.notifier).setList(id: listId, name: name);

    // Fit-to-pins can't happen here: the list's footprint isn't known until
    // `/map/pins` answers. Claim it instead, and let the map perform the fit
    // when that response lands — see `mapPendingListFitProvider`.
    _ref.read(mapPendingListFitProvider.notifier).state = listId;

    _trackListOpened(
      listId: listId,
      source: source,
      ownerId: ownerId,
      isOwn: isOwn,
    );
  }

  /// PROD-3568 — fired HERE rather than at the two call sites, for exactly the
  /// reason [_trackKeywordFilterChange] gives: this method is the one place
  /// every list opening passes through, so the count stays whole no matter how
  /// the producers change.
  ///
  /// This counts an OPEN being dispatched, not one that succeeded. The outcome
  /// is already measured next door: `setList` stamps the query's trigger as
  /// `'list'`, so the pins response fires `map_area_searched{trigger:'list'}`
  /// carrying `result_count`. A `map_list_opened` with no matching
  /// `map_area_searched{trigger:'list'}` is therefore a list that 404'd and
  /// backed out — no third event needed to see it.
  void _trackListOpened({
    required String listId,
    required MapListOpenSource source,
    String? ownerId,
    bool? isOwn,
  }) {
    final auth = _ref.read(authStateProvider);
    final ownership = !auth.isAuthenticated
        // A guest owns nothing. Settled before either read because a guest has
        // no identity to compare against, so the history path would return
        // `unknown` for a case we actually know the answer to.
        ? MapListOwnership.other
        : ownerId != null
        ? mapListOwnershipFromIds(viewerId: auth.user?.id, ownerId: ownerId)
        // PROD-3647 — the server already decided this, so read it, do NOT
        // re-derive it. A missing `is_own` is `other`, deliberately: there is
        // no handle-comparison fallback any more, because that fallback WAS
        // the bug (a viewer with no handle set reported `unknown` for every
        // Zine they opened) and it would have stayed silently live against any
        // backend older than OpenAPI 1.71.0.
        : isOwn == true
        ? MapListOwnership.own
        : MapListOwnership.other;
    unawaited(
      _ref
          .read(unifiedAnalyticsProvider)
          .trackMapListOpened(
            listId: listId,
            ownership: ownership.wire,
            authState: auth.isAuthenticated ? 'logged_in' : 'logged_out',
            source: source.wire,
          ),
    );
  }
}

/// D9 — the bar's clear-X with a search active: drop the chrome and restore
/// the default pins for the current viewport/scope. The camera deliberately
/// stays where it is.
///
/// Deliberately a free function rather than a sixth [MapSearchExecutor]
/// method: it is the bar undoing its own state, not a per-type execution, and
/// the interface is shared with PROD-3499 (whose placeholder would gain a
/// meaningless override).
///
/// PROD-3567 — this is also the **single** clear path for leaving list mode
/// ("De quem?" picking another scope, or "Reset all filters"). Those callers
/// write the query themselves — the list exit is one atomic write, so the map
/// refetches once — and then call this for the parts only the bar owns: its
/// chrome and the promoted pin. The [setKeyword] below no-ops for them (their
/// write already emptied it), which is exactly why routing through here costs
/// nothing and keeps the two surfaces from disagreeing about state.
///
/// [trigger] says **who caused the clear**, and does two things:
/// - tags the refetch the keyword-clear would cause, so it isn't misattributed
///   to `'keyword'` (PROD-3500 — see [MapQueryNotifier.setKeyword]);
/// - decides whether this fires its own `map_filter_change`. The bar's X owns
///   that event; a caller clearing as a *side effect* of another action owns
///   its own event instead, and a second one here would inflate the keyword
///   slice with source/reset picks.
void clearMapActiveSearch(WidgetRef ref, {String trigger = 'keyword'}) {
  ref.read(mapSearchProvider.notifier).clearActive();
  ref.read(mapPromotedPinProvider.notifier).state = null;
  ref.read(mapQueryProvider.notifier).setKeyword('', trigger: trigger);
  if (trigger != 'keyword') return;
  // PROD-3500 (H2) — the v1 field fired `map_filter_change` on its clear too,
  // and this is that clear. Fires for any active search, matching v1: the
  // keyword is what gets dropped either way.
  unawaited(
    ref.read(unifiedAnalyticsProvider).trackMapFilterChange(filter: 'keyword'),
  );
}

final mapSearchExecutorProvider = Provider<MapSearchExecutor>(
  MapSearchExecutorImpl.new,
);
