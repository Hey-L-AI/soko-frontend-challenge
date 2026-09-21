// PROD-4005 — state for the server-driven Discovery feed.
//
// Shape mirrors `PagedShelfState`: the outer `AsyncValue.loading` covers the
// first fetch, while `isLoadingMore` is an internal flag that never tears the
// feed down to skeletons mid-scroll.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../data/models/feed_home.dart';
import '../../../../providers/providers.dart';
import '../../../../data/models/resolved_search_location.dart';
import '../../../../providers/resolved_search_location_provider.dart';
import '../../../entity_signals/providers/feed_going_seeds.dart';
import '../../../entity_signals/providers/feed_signal_seeds.dart';
import 'feed_filter_provider.dart';

/// The bounds `GET /feed/home` declares for the location payload (OpenAPI
/// 1.140.0). **Every one of these is a 422 when violated, and a 422 on this
/// endpoint is a blank feed — not a degraded one**, so each param is guarded
/// against its own bound before it reaches the wire.
const double kFeedRadiusKmMin = 0.5;
const double kFeedRadiusKmMax = 500.0;

/// `admin_boundary_id: {maxLength: 128}`.
const int kFeedBoundaryIdMaxLength = 128;

/// `latitude: {minimum: -90, maximum: 90}` / `longitude: {minimum: -180,
/// maximum: 180}`.
const double kFeedLatAbsMax = 90.0;
const double kFeedLonAbsMax = 180.0;

/// The coordinate pair, or `(null, null)` when it is not something the endpoint
/// would accept.
///
/// Nothing upstream validates coordinates: `SearchScope.fromJson` shape-checks
/// a persisted scope and passes `center_lat`/`center_lng` straight through as
/// doubles, on a payload its own doc says can "drift across app updates". That
/// was harmless while a city pick withheld its coordinates — now they travel on
/// every request, so a drifted or non-finite value would 422 a request that
/// used to compose fine off its perfectly good `city_id`.
///
/// **All-or-nothing on purpose.** The backend needs both to read either
/// (`resolve_search_location` only sets coords when latitude AND longitude are
/// present), so half a pair is a 422 risk buying nothing. Dropping both leaves
/// `city_id` to resolve the feed exactly as it did before this change.
({double? lat, double? lon}) feedCoordinatePair(double? lat, double? lon) {
  if (lat == null || lon == null) return (lat: null, lon: null);
  if (!lat.isFinite || !lon.isFinite) return (lat: null, lon: null);
  if (lat.abs() > kFeedLatAbsMax || lon.abs() > kFeedLonAbsMax) {
    return (lat: null, lon: null);
  }
  return (lat: lat, lon: lon);
}

/// The radius the feed request sends, in **kilometres**, or null when the scope
/// carries none.
///
/// Kilometres because the unified SearchLocation param group is km across all
/// five Discovery endpoints; metres everywhere else in this app because
/// `SearchScopeArea` and `GeoRangeOut` are metres. The conversion belongs here,
/// at the boundary, rather than in the widget layer.
///
/// **The product 3 km floor is NOT applied here — it lives in the picker**
/// (`kMinPickerRadiusMeters`), where the user can see the highlight circle stop
/// shrinking. Re-applying it at send time would inflate the radii the picker
/// never framed: a boundary-backed area carries the backend's own
/// `recommended_radius_m`, and hundreds of real freguesias sit below 3 km
/// (Arroios is 823 m). Since the radius does not yet shape the feed, flooring it
/// here would change nothing a user sees while overstating every small-area
/// pick in the sample the backend is collecting to design the follow-up.
///
/// What IS applied is the endpoint's own accepted window: out-of-range is a
/// 422, and a 422 here is a blank feed.
@visibleForTesting
double? feedSearchRadiusKm(ResolvedSearchLocation location) {
  final meters = location.radiusMeters;
  if (meters == null || meters <= 0) return null;
  return (meters / 1000).clamp(kFeedRadiusKmMin, kFeedRadiusKmMax);
}

/// One page of feed state.
@immutable
class FeedHomeState {
  /// Blocks in backend order, deduped by [FeedBlock.id].
  final List<FeedBlock> blocks;

  /// Cursor for the next page. `null` once the layout is exhausted.
  final String? nextCursor;

  /// Every block id this feed session has SEEN — including blocks that were
  /// skipped as unknown and never rendered.
  ///
  /// **Seen, not rendered.** That distinction is the whole point. A stale or
  /// corrupt cursor restarts the feed at page 1 rather than erroring, so
  /// without a ledger the client would append `hero-lead` twice, breaking the
  /// Flutter list key AND double-counting the PROD-4003 impression key.
  ///
  /// Counting *rendered* ids instead would have been a subtler bug: an older
  /// app receiving a page whose blocks are all types it doesn't know renders
  /// nothing, which would look identical to "this page added nothing" and stop
  /// paging — truncating a feed it could otherwise have shown. Unknown-skip and
  /// the paging guard would have combined into a defect neither has alone.
  final Set<String> seenBlockIds;

  /// Cursors already sent. A cursor coming back that we have already requested
  /// means the layout is cycling; stop rather than loop.
  final Set<String> requestedCursors;

  /// True while a `loadMore` fetch is in flight. The outer `AsyncValue` stays
  /// `AsyncData` throughout.
  final bool isLoadingMore;

  /// Set when paging stopped for a reason that is not a clean end-of-layout —
  /// a duplicate-only page or a cursor cycle. Diagnostic only: the user sees
  /// the feed end either way, which is the better degrade.
  final bool stoppedOnCursorAnomaly;

  /// Last `loadMore` failure. Auto-fire blocks while non-null; only
  /// `retryLoadMore` clears it.
  final Object? loadMoreError;

  /// True while a `loadSlate` fetch is in flight (PROD-4238).
  ///
  /// **Separate from [isLoadingMore] deliberately.** They drive two different
  /// affordances — the scroll spinner at the tail of the list, and the spinner
  /// *inside* the `feed_end` button — and sharing one flag would light both for
  /// either cause.
  final bool isLoadingSlate;

  /// Last `loadSlate` failure (PROD-4238).
  ///
  /// Unlike [loadMoreError] this needs no retry affordance of its own: the
  /// `feed_end` block is still on the page with a live button, so **the button
  /// is the retry**. Cleared on the next attempt.
  final Object? slateError;

  /// The `run_id` of the most recently fetched page (PROD-4257). The screen
  /// forwards it to the engagement tracker so item events join back to the
  /// served slate. Usually null on the composed home feed — best-effort until
  /// the backend logs a run on this path (Part D1).
  ///
  /// **Deliberately on the state, not pushed to the tracker from the notifier.**
  /// Reaching the tracker here would drag the whole engagement/API-client
  /// provider chain into the notifier's `build`, which every widget test that
  /// renders a feed block would then have to satisfy (see the note on
  /// [feedSlateLoadingProvider]).
  final String? runId;

  /// Which page's `run_id` served each block, keyed by [FeedBlock.id]
  /// (PROD-4303). [runId] alone is the LATEST page's — after a `loadMore` it
  /// would re-tag still-mounted run-A cards with run B (the
  /// latest-page-attribution gap) — so each merge path stamps the blocks it
  /// added with the run of the page they arrived on. Blocks from a run-less
  /// page (run logging off / composed feed) simply have no entry.
  ///
  /// A per-block wire `run_id` ([FeedBlock.runId]) wins over this map when the
  /// backend starts sending one — see `runIdForBlock` callers.
  final Map<String, String> blockRunIds;

  /// Which ranking filled this feed's discovery blocks (PROD-4373):
  /// `personalized` | `safe_bet` | null. The most recently fetched page's,
  /// like [runId] — which in practice is the whole scroll's: every page and
  /// slate of one provider lifetime slices the same pinned pool, and the
  /// safe-bet → personalized upgrade lands only on a fresh cursor-less build.
  /// Forwarded onto the card-click analytics so dashboards can split
  /// engagement by ranking kind without a `discovery_runs` join.
  final String? slateKind;

  const FeedHomeState({
    required this.blocks,
    required this.nextCursor,
    required this.seenBlockIds,
    required this.requestedCursors,
    this.isLoadingMore = false,
    this.stoppedOnCursorAnomaly = false,
    this.loadMoreError,
    this.isLoadingSlate = false,
    this.slateError,
    this.runId,
    this.blockRunIds = const {},
    this.slateKind,
  });

  const FeedHomeState.empty()
    : blocks = const [],
      nextCursor = null,
      seenBlockIds = const {},
      requestedCursors = const {},
      isLoadingMore = false,
      stoppedOnCursorAnomaly = false,
      loadMoreError = null,
      isLoadingSlate = false,
      slateError = null,
      runId = null,
      blockRunIds = const {},
      slateKind = null;

  /// Whether another page can be requested.
  bool get hasMore => nextCursor != null && !stoppedOnCursorAnomaly;

  /// The `run_id` of the page that served [blockId], or null when that page
  /// carried none. The blocks' fallback when the wire block has no `run_id`
  /// of its own.
  String? runIdForBlock(String blockId) => blockRunIds[blockId];

  FeedHomeState copyWith({
    List<FeedBlock>? blocks,
    String? nextCursor,
    bool clearNextCursor = false,
    Set<String>? seenBlockIds,
    Set<String>? requestedCursors,
    bool? isLoadingMore,
    bool? stoppedOnCursorAnomaly,
    Object? loadMoreError,
    bool clearLoadMoreError = false,
    bool? isLoadingSlate,
    Object? slateError,
    bool clearSlateError = false,
    String? runId,
    Map<String, String>? blockRunIds,
    String? slateKind,
  }) {
    return FeedHomeState(
      blocks: blocks ?? this.blocks,
      nextCursor: clearNextCursor ? null : (nextCursor ?? this.nextCursor),
      seenBlockIds: seenBlockIds ?? this.seenBlockIds,
      requestedCursors: requestedCursors ?? this.requestedCursors,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      stoppedOnCursorAnomaly:
          stoppedOnCursorAnomaly ?? this.stoppedOnCursorAnomaly,
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
      isLoadingSlate: isLoadingSlate ?? this.isLoadingSlate,
      slateError: clearSlateError ? null : (slateError ?? this.slateError),
      runId: runId ?? this.runId,
      blockRunIds: blockRunIds ?? this.blockRunIds,
      slateKind: slateKind ?? this.slateKind,
    );
  }
}

/// The feed for the currently selected filter.
///
/// Keyed on [feedFilterProvider], so changing filter rebuilds this notifier and
/// refetches from scratch (D4) — the feed is computed per filter. The page
/// chrome does not watch this provider, so a filter change leaves the chrome in
/// place and only the feed area shows a loading state (D16).
final feedHomeProvider =
    AsyncNotifierProvider.autoDispose<FeedHomeNotifier, FeedHomeState>(
      FeedHomeNotifier.new,
    );

/// Whether a slate fetch is in flight (PROD-4238).
///
/// A derived read rather than `feed_end` watching [feedHomeProvider] wholesale,
/// for the reason `feedFollowedZineIdsProvider` gives: it narrows the rebuild,
/// and it gives widget tests **one small thing to override** instead of a
/// notifier with an API and a location resolver behind it. Reaching through to
/// [feedHomeProvider] from a block widget makes every test that renders that
/// block instantiate the whole feed — which fires a request as a side effect of
/// drawing a card, and throws `UnimplementedError('Initialize in main.dart')`
/// in any test that never needed one.
///
/// ⚠️ **`autoDispose` is load-bearing, not decoration.** A keep-alive `Provider`
/// that watches an `autoDispose` one PINS it: the listener never goes away, so
/// [feedHomeProvider] could never dispose again once the first `feed_end` block
/// rendered — and the feed would then be reused stale on every re-entry instead
/// of refetching, silently defeating the `autoDispose` the whole notifier is
/// built around (`_fetchVersion`, `resetFirst`, the seed store's generation
/// token all assume a new instance per composition). Measured, not assumed:
/// keep-alive leaves the feed `disposed=0` after its last listener closes;
/// `autoDispose` gives `disposed=1`. `feed_home_provider_slate_test.dart` pins
/// it behaviourally.
final feedSlateLoadingProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(
    feedHomeProvider.select((s) => s.valueOrNull?.isLoadingSlate ?? false),
  ),
);

class FeedHomeNotifier extends AutoDisposeAsyncNotifier<FeedHomeState> {
  /// Set when the provider is disposed, so an in-flight `loadMore` does not
  /// write to `state` afterwards (which throws in Riverpod 2.x).
  ///
  /// ⚠️ **Cleared at the top of every [build], and it has to be.** Riverpod
  /// runs the previous build's `onDispose` callbacks before a REBUILD too, not
  /// only on a real teardown — while deliberately preserving this notifier
  /// instance across builds. Without the reset the flag is a one-way latch that
  /// trips on the user's first filter or location change, after which every
  /// `loadMore` raises `isLoadingMore`, returns early on the guard below, and
  /// leaves the spinner up forever with paging permanently dead.
  ///
  /// "Superseded" is NOT this flag's job — [_fetchVersion] answers that, and it
  /// is bumped by `build()` for exactly this reason. This one means "the
  /// provider is gone", which is precisely the state `build()` running again
  /// disproves.
  bool _disposed = false;

  /// Bumped per fetch. A response whose token is stale — because the filter or
  /// location changed and `build()` re-ran while the page was in the air — is
  /// dropped instead of being merged onto a snapshot that no longer exists.
  /// Same shape as `yours_shelf_provider`'s guard.
  int _fetchVersion = 0;

  @override
  Future<FeedHomeState> build() async {
    // The element is (re)mounted, so a previous build's teardown must not go
    // on speaking for it. See the field's own note.
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    // A new build supersedes anything in flight from the previous one. This
    // counter guards `loadMore` only; the seed store carries its own token
    // because it must order across notifier INSTANCES, which this cannot.
    _fetchVersion++;

    // Minted BEFORE the awaits so it records start order, not completion
    // order. See `FeedSignalSeeds.beginComposition`.
    final seedToken = ref
        .read(feedSignalSeedsProvider.notifier)
        .beginComposition();
    // Same start-order token discipline for the friends-going seeds — a slow
    // page-1 must lose to the composition that superseded it.
    final goingToken = ref
        .read(feedGoingSeedsProvider.notifier)
        .beginComposition();

    final filter = ref.watch(feedFilterProvider);

    final location = await ref.watch(resolvedSearchLocationProvider.future);

    final page = await _fetchPage(filter: filter, location: location);

    final seen = <String>{};
    final blocks = _dedupe(page.blocks, seen);

    // Token-guarded, and the token is owned by the seed store rather than this
    // notifier: `feedHomeProvider` is autoDispose, so an invalidation builds a
    // NEW instance whose counters start from zero — an instance-local version
    // cannot tell that a previous instance's response is stale.
    ref
        .read(feedSignalSeedsProvider.notifier)
        .applyPage(seedToken, page.blocks, page.signals, resetFirst: true);
    ref
        .read(feedGoingSeedsProvider.notifier)
        .applyPage(goingToken, page.going, resetFirst: true);

    return FeedHomeState(
      blocks: blocks,
      nextCursor: page.nextCursor,
      seenBlockIds: seen,
      requestedCursors: const {},
      runId: page.runId,
      // Built fresh, never carried over: `build()` runs per composition
      // (filter/location change, refresh), and stale ids from the previous
      // one must not survive into it.
      blockRunIds: _stampRunIds(const {}, blocks, page.runId),
      slateKind: page.slateKind,
    );
  }

  /// [base] plus an entry per block in [fresh], stamped with [runId] — the
  /// run of the page those blocks arrived on. A run-less page stamps nothing.
  static Map<String, String> _stampRunIds(
    Map<String, String> base,
    List<FeedBlock> fresh,
    String? runId,
  ) {
    if (runId == null || fresh.isEmpty) return base;
    return {...base, for (final block in fresh) block.id: runId};
  }

  /// One request, with the location arguments resolved the same way on every
  /// page.
  ///
  /// Page 1 originally inlined this and `loadMore` sent only `cityId`, so a
  /// coordinate-only location (no seeded city — `cityId == null`,
  /// `centerLat/centerLon` set) fetched page 1 fine and then sent NO location
  /// at all on page 2, which the contract answers with a 400. One helper, one
  /// place to get it right.
  ///
  /// **PROD-4291 — every signal now travels, not one of them.** This used to
  /// null the coordinates whenever a `city_id` resolved, so an Arroios pick
  /// reached the backend as "Lisboa" and the area the user actually chose was
  /// unrecoverable. The backend resolver has always kept `city_id` and coords
  /// as independent fields; the either/or was purely this client's decision.
  Future<FeedHomeOut> _fetchPage({
    required FeedFilter filter,
    required ResolvedSearchLocation location,
    String? cursor,
  }) {
    // Send EVERY signal we hold, and let the backend pick the right one per
    // job (PROD-4291). This used to be either/or — `city_id` when a seeded
    // city resolved, coordinates only when it did not — so an Arroios pick
    // arrived as "Lisboa" and the backend never learned which part of Lisboa
    // the user meant.
    //
    // Both are safe together: the shared resolver resolves `city_id` and the
    // coordinates INDEPENDENTLY, and the city-scoped feed still prefers a
    // resolved `city_id`, so a valid pick composes for exactly the city it
    // does today. Sending coords as well strictly *removes* a failure — a
    // `city_id` that no longer resolves used to leave no signal at all and
    // answer 400; now it falls through to the coordinates and snaps.
    //
    // Radius and boundary are only meaningful alongside a centre. A
    // country-only scope has neither, and sending a radius around nothing
    // would be a number the backend cannot honour.
    final coords = feedCoordinatePair(location.centerLat, location.centerLon);
    final hasCenter = coords.lat != null && coords.lon != null;

    return ref
        .read(feedApiProvider)
        .getHomeFeed(
          filter: filter,
          cityId: location.cityId,
          // Guarded as a pair: an out-of-range or non-finite coordinate would
          // 422 a request that `city_id` alone would have served.
          latitude: coords.lat,
          longitude: coords.lon,
          radiusKm: hasCenter ? feedSearchRadiusKm(location) : null,
          // Sent whenever the pick was boundary-backed, whatever its origin.
          // A point/POI pick carries `boundaryId: null` by construction so a
          // provider place-id can never land in this containment-reserved
          // field — preserve that. Deliberately NOT `containRequestParams`:
          // that also emits `location_mode`, which this endpoint rejects.
          adminBoundaryId: hasCenter
              ? _boundarySignal(location.boundaryId)
              : null,
          cursor: cursor,
        );
  }

  /// Normalises the boundary token the way the backend does: a blank or
  /// whitespace-only id means *no boundary*, not an empty one.
  ///
  /// An over-long id is **dropped, never truncated** — the value is an opaque
  /// token, so a truncated one is not a shorter version of the boundary, it is
  /// a different (and unresolvable) boundary. Sending it would 422 the whole
  /// request over a field the backend only records; dropping it costs one
  /// observability signal and keeps the feed rendering.
  static String? _boundarySignal(String? id) {
    final trimmed = id?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.length > kFeedBoundaryIdMaxLength) return null;
    return trimmed;
  }

  /// Fetches the next page. No-ops when already loading, exhausted, or holding
  /// an unretried error.
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (current.isLoadingMore || current.loadMoreError != null) return;

    final cursor = current.nextCursor;
    if (cursor == null || current.stoppedOnCursorAnomaly) return;

    // A cursor we have already sent means the layout is cycling. Stop rather
    // than request the same page forever.
    if (current.requestedCursors.contains(cursor)) {
      state = AsyncData(
        current.copyWith(clearNextCursor: true, stoppedOnCursorAnomaly: true),
      );
      return;
    }

    final fetchVersion = ++_fetchVersion;
    state = AsyncData(current.copyWith(isLoadingMore: true));

    try {
      final page = await _fetchPage(
        filter: ref.read(feedFilterProvider),
        location: await ref.read(resolvedSearchLocationProvider.future),
        cursor: cursor,
      );

      // The provider may have been disposed, or `build()` may have re-run for
      // a new filter/location, while this page was in the air. Either way the
      // `current` snapshot below is stale — merging onto it would resurrect a
      // feed the user has already left.
      if (_disposed || fetchVersion != _fetchVersion) return;

      final seen = {...current.seenBlockIds};
      final fresh = _dedupe(page.blocks, seen);

      // Merge, never replace: each cursor page carries only its own ids, and
      // the cards from earlier pages are still mounted. Seeded off `page` (not
      // `fresh`) so a block dropped as a duplicate still contributes the
      // sentiment for the items it carries.
      //
      // Uses the CURRENT token rather than minting one — this page belongs to
      // the composition already in place, and must be dropped if a newer one
      // took over while it was in the air.
      final seeds = ref.read(feedSignalSeedsProvider.notifier);
      seeds.applyPage(
        seeds.currentToken,
        page.blocks,
        page.signals,
        resetFirst: false,
      );
      final goingSeeds = ref.read(feedGoingSeedsProvider.notifier);
      goingSeeds.applyPage(
        goingSeeds.currentToken,
        page.going,
        resetFirst: false,
      );

      // Every id on this page was already in the ledger. Either the backend
      // restarted us on a stale cursor, or the layout is repeating. "The feed
      // ends here" beats silently re-showing what the user already scrolled
      // past, and it terminates rather than looping.
      //
      // Only blocks carrying a usable id count towards that judgement: a page
      // of malformed, id-less envelopes is not a repeat of anything, and
      // treating it as one would halt paging over content we simply could not
      // read.
      final idBearing = page.blocks.where((b) => b.id.isNotEmpty);
      final duplicateOnly = fresh.isEmpty && idBearing.isNotEmpty;

      state = AsyncData(
        current.copyWith(
          blocks: [...current.blocks, ...fresh],
          nextCursor: duplicateOnly ? null : page.nextCursor,
          clearNextCursor: duplicateOnly || page.nextCursor == null,
          seenBlockIds: seen,
          requestedCursors: {...current.requestedCursors, cursor},
          isLoadingMore: false,
          stoppedOnCursorAnomaly: duplicateOnly,
          runId: page.runId,
          // Only the NEW blocks get this page's run — earlier pages' blocks
          // keep the run that actually served them.
          blockRunIds: _stampRunIds(current.blockRunIds, fresh, page.runId),
          slateKind: page.slateKind,
        ),
      );
    } catch (e) {
      if (_disposed || fetchVersion != _fetchVersion) return;
      state = AsyncData(
        current.copyWith(isLoadingMore: false, loadMoreError: e),
      );
    }
  }

  /// Fetches the **next slate** and swaps it in for the terminal block that
  /// asked for it (PROD-4238).
  ///
  /// Deliberately not `loadMore`, and the difference is not stylistic:
  ///
  ///   * It does **not** consult [FeedHomeState.nextCursor], which is `null` at
  ///     every slate boundary — precisely the state this runs in. Reusing
  ///     `loadMore` would mean weakening the guard that stops the *scroll* from
  ///     advancing a slate, and that guard is the whole reason a slate crossing
  ///     is a tap.
  ///   * It **replaces** rather than appends. See below.
  ///
  /// [fromBlockId] is the id of the block whose button was tapped. Passed in
  /// rather than searched for: the widget knows which occurrence it is, and a
  /// search would have to guess between `feed-end` and `feed-end-sN` if a page
  /// ever carried two.
  Future<void> loadSlate({
    required String cursor,
    required String fromBlockId,
  }) async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (current.isLoadingSlate || current.isLoadingMore) return;

    // Already fetched this slate. A double-tap, not a cycling layout — so it is
    // a no-op and, unlike `loadMore`'s identical-looking guard, it must NOT set
    // `stoppedOnCursorAnomaly`. Every slate cursor is new by construction; the
    // cycling heuristic has nothing true to say about one, and letting it fire
    // here would kill paging inside a slate the reader has not seen yet.
    if (current.requestedCursors.contains(cursor)) return;

    final fetchVersion = ++_fetchVersion;
    state = AsyncData(
      current.copyWith(isLoadingSlate: true, clearSlateError: true),
    );

    try {
      final page = await _fetchPage(
        filter: ref.read(feedFilterProvider),
        location: await ref.read(resolvedSearchLocationProvider.future),
        cursor: cursor,
      );

      if (_disposed || fetchVersion != _fetchVersion) return;

      final seen = {...current.seenBlockIds};
      final fresh = _dedupe(page.blocks, seen);

      // Merges onto the composition already in place, so it takes the CURRENT
      // token and does not reset — the earlier slate's cards are still mounted
      // and still need their seeds.
      final seeds = ref.read(feedSignalSeedsProvider.notifier);
      seeds.applyPage(
        seeds.currentToken,
        page.blocks,
        page.signals,
        resetFirst: false,
      );

      // **No usable new blocks — keep the end card and fail visibly.**
      //
      // Two ways to land here, both backend misconfigurations rather than an
      // expected end: every id was already in the ledger (each slate gets its
      // OWN ids precisely so that cannot happen), or the page carried nothing
      // at all (the contract says even an empty slate terminates honestly, by
      // appending `feed_complete`). Either way, removing the terminal block
      // would strand the reader at a dead end with nothing to press — worse
      // than showing the failure and leaving them the button. The empty case
      // used to fall through to the success path below and do exactly that.
      //
      // ⚠️ **The cursor is deliberately NOT recorded here.** `loadSlate` reads
      // an already-requested cursor as a double-tap and returns early, so
      // recording it on failure would leave a button that still LOOKS live and
      // could never do anything again — destroying the retry this branch exists
      // to preserve. Only a success records the cursor.
      if (fresh.isEmpty) {
        state = AsyncData(
          current.copyWith(
            isLoadingSlate: false,
            slateError: StateError('slate $cursor returned no new blocks'),
            seenBlockIds: seen,
          ),
        );
        return;
      }

      // ⚠️ **REPLACE, never append.** Blocks are one flat list, so putting the
      // new slate after the old `feed_end` strands "Ainda não encontraste o que
      // procuras?" in the middle of the feed — a card that says the feed is
      // over, with six blocks under it. It looks fine in a test that counts
      // blocks and is obviously wrong on a device, which is why
      // `feed_home_provider_slate_test.dart` asserts the id is GONE rather than
      // asserting a length.
      final retained = current.blocks
          .where((b) => b.id != fromBlockId)
          .toList(growable: false);

      // Emitted for a fetch that SUCCEEDED and produced blocks — not for the
      // tap. A failed fetch leaves the button live and the reader taps again;
      // counting attempts would make one slate look like several.
      //
      // Before the state write, deliberately: a throw from analytics after the
      // write would be caught below and roll the feed back to `current`,
      // reverting a slate that had already landed. Ahead of the write there is
      // nothing to undo.
      //
      // `retained.length`, not `current.blocks.length` — the contract defines
      // this as the count with the replaced terminal card already excluded, and
      // a metric that disagrees with its own published definition is worse than
      // no metric at all.
      ref
          .read(unifiedAnalyticsProvider)
          .trackFeedSlateAdvance(
            blockId: fromBlockId,
            feedFilter: ref.read(feedFilterProvider).wire,
            blocksBefore: retained.length,
          );

      state = AsyncData(
        current.copyWith(
          blocks: [...retained, ...fresh],
          nextCursor: page.nextCursor,
          clearNextCursor: page.nextCursor == null,
          seenBlockIds: seen,
          requestedCursors: {...current.requestedCursors, cursor},
          isLoadingSlate: false,
          // ⚠️ `current` is the PRE-FETCH snapshot, so it still carries any
          // error from the attempt being retried. Without this, a successful
          // retry writes the old failure straight back and the reader keeps
          // seeing it. The `clearSlateError` at the top of `loadSlate` does not
          // cover it — that cleared the LIVE state, not this snapshot.
          clearSlateError: true,
          // A new slate is a fresh layout with its own paging. Whatever made
          // the previous one stop early says nothing about this one.
          stoppedOnCursorAnomaly: false,
          clearLoadMoreError: true,
          runId: page.runId,
          // Stamp the slate's blocks with its run; drop the replaced terminal
          // block's entry along with the block itself.
          blockRunIds: _stampRunIds(
            {
              for (final entry in current.blockRunIds.entries)
                if (entry.key != fromBlockId) entry.key: entry.value,
            },
            fresh,
            page.runId,
          ),
          slateKind: page.slateKind,
        ),
      );
    } catch (e) {
      if (_disposed || fetchVersion != _fetchVersion) return;
      state = AsyncData(current.copyWith(isLoadingSlate: false, slateError: e));
    }
  }

  /// Clears a `loadMore` failure and tries again.
  Future<void> retryLoadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.loadMoreError == null) return;
    state = AsyncData(current.copyWith(clearLoadMoreError: true));
    await loadMore();
  }

  /// Appends only blocks whose id is new, mutating [seen] as it goes.
  ///
  /// Unknown blocks are counted here — they are skipped by the *renderer*, not
  /// by the ledger.
  static List<FeedBlock> _dedupe(List<FeedBlock> incoming, Set<String> seen) {
    final out = <FeedBlock>[];
    for (final block in incoming) {
      if (block.id.isEmpty) continue;
      if (seen.add(block.id)) out.add(block);
    }
    return out;
  }
}
