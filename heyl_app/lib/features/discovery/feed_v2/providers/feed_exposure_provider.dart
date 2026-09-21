// PROD-4423 — what `feed_exposed` reports for the Discovery page on screen,
// or `null` while there is nothing honest to report yet.
//
// ⚠️ **This provider must never read `discoveryFeedVariantProvider`, and the
// `bool` family key is how that is enforced rather than merely asked for.**
// Since PROD-4419 reading that provider is the act that *decides* the variant:
// it fixes the session the instant it is created, so a read before
// `feedVariantGateProvider` opens commits the user to the cached `false` — the
// "v2 arrives one cold start late" bug, back again, with green tests and
// plausible-looking analytics. The first draft of this file computed the
// variant itself and was safe only because `DiscoveryVariantPage` happened to
// be its sole consumer; the day a widget test, a debug panel or a future header
// watched it, the bug returned silently. Taking the already-resolved variant as
// a parameter removes the capability instead of documenting the rule.
//
// The caller therefore reads the gate, then the variant, then this — in that
// order. See `discovery_variant_page.dart`.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/models/feed_home.dart';
import '../../../../data/models/resolved_search_location.dart';
import '../../../../providers/providers.dart';
import '../../../../providers/resolved_search_location_provider.dart';
import '../widgets/feed_block_dispatcher.dart';
import 'feed_chrome_providers.dart';
import 'feed_filter_provider.dart';
import 'feed_home_provider.dart';

/// PROD-4531 — **what the reader actually saw**, as one closed set.
///
/// `block_count` alone cannot answer this: it reads `0` for an empty feed, an
/// errored feed and the no-location notice alike, and — worse — the
/// out-of-coverage answer arrives as a *block*, so it reads as a rendered feed
/// with `block_count >= 1` and is invisible.
///
/// **This describes the PAINTED outcome, not the wire.** `block_count` already
/// carries the wire count, so a wire-truth `state` would duplicate it; pairing
/// the two is what keeps the causes separable (D1): `empty` + `block_count == 0`
/// is the backend saying "no results", `empty` + `block_count >= 1` is blocks
/// arriving that this build renders none of.
enum FeedExposureState {
  /// Cards. The ordinary case.
  feed('feed'),

  /// The slate carried a [FeedBlockUnknownArea] — the backend served the
  /// out-of-coverage answer instead of a feed.
  unknownArea('unknown_area'),

  /// The request succeeded and nothing renders, so `FeedEmptyState` paints.
  ///
  /// ⚠️ **Not strictly terminal.** When the renderable list is empty *and* a
  /// cursor came back, the screen paints `FeedLoadingState` and calls
  /// `loadMore()` — and `feed_exposed` fires at that instant. The event is
  /// deduped per `variant|filter` per app process, so that first value sticks
  /// even if the next page brings cards. A small share of `empty` rows are
  /// therefore sessions that went on to get content. Accepted deliberately
  /// (D1): withholding the event until paging settles would drop every reader
  /// who leaves during the auto-advance, which is the same bias the v2
  /// fetch-abandonment gap already has.
  empty('empty'),

  /// The request failed.
  error('error'),

  /// No usable location, so the feed was never requested at all.
  noLocation('no_location'),

  /// PROD-4520 — the slate carried a [FeedBlockSignInGate]. One renderable
  /// block, so without this value it would report [feed] (D2): it renders *as*
  /// a feed but is a state shown *instead of* feed content.
  signInGate('sign_in_gate');

  const FeedExposureState(this.wire);

  /// The value on the wire. Written down here rather than derived from [name]
  /// so `unknownArea` cannot silently start reporting camelCase.
  final String wire;
}

/// The payload of one `feed_exposed`, minus the variant (which `_dispatch`
/// stamps) and `is_cold_start` (which the analytics service derives).
///
/// Value equality so an unchanged payload does not rebuild the page: this
/// provider recomputes on every `feedHomeProvider` movement, including
/// `isLoadingMore` flips and `loadMore` appends, and the identical payload that
/// results must not propagate.
@immutable
class FeedExposure {
  const FeedExposure({
    required this.filter,
    required this.blockCount,
    required this.state,
    this.locationSource,
    this.cityId,
    this.lat,
    this.lon,
    this.suggestionCount,
  });

  /// `events` | `venues` | `zines` | `people` — the wire value, so it matches
  /// what `feed_slate_advance` already sends.
  final String filter;

  /// Blocks in the rendered slate. `0` on an empty feed, an errored feed, and
  /// the no-location notice state.
  ///
  /// PROD-4531 did **not** change this. `unknown_area` still counts its block
  /// here; [state] is what the dashboard reads to tell the cases apart.
  final int blockCount;

  /// PROD-4531 — what the reader saw. See [FeedExposureState].
  final FeedExposureState state;

  /// PROD-4531 — where the feed request was aimed, on the rows where that is
  /// the interesting question.
  ///
  /// **Null on [FeedExposureState.feed], deliberately**: a working feed's
  /// location is not what anyone is asking about, and leaving four properties
  /// off the overwhelmingly common row keeps the event small.
  ///
  /// [ResolvedLocationOrigin] snake-cased — `area`, `city`, `auto`, `gps`,
  /// `default_location`. ⚠️ This is **not** "GPS fix / IP / picker / cached":
  /// the app does not distinguish those. `auto` collapses an IP-detected city
  /// and a live-fix-derived city into one value, and there is no cached
  /// concept at all. Separating them is a change to `cityAutoScopeProvider`,
  /// not to this event.
  final String? locationSource;

  /// The city the request used, when one resolved.
  ///
  /// ⚠️ **Essentially always null on [FeedExposureState.noLocation]** — the
  /// gate returns false precisely when there is no `city_id` *and* no usable
  /// coordinate pair, so that row can carry no location at all. The "where are
  /// the readers with no coverage" question is answered by `unknown_area`,
  /// `empty` and `error`, not by `no_location`.
  final String? cityId;

  /// The centre of the request. Rounded to 2 decimals — about 1 km — on the
  /// way out, in `UnifiedAnalyticsService`. **Never send these unrounded.**
  final double? lat;
  final double? lon;

  /// How many alternatives the backend offered with an
  /// [FeedExposureState.unknownArea] block. Null on every other state.
  final int? suggestionCount;

  @override
  bool operator ==(Object other) =>
      other is FeedExposure &&
      other.filter == filter &&
      other.blockCount == blockCount &&
      other.state == state &&
      other.locationSource == locationSource &&
      other.cityId == cityId &&
      other.lat == lat &&
      other.lon == lon &&
      other.suggestionCount == suggestionCount;

  @override
  int get hashCode => Object.hash(
    filter,
    blockCount,
    state,
    locationSource,
    cityId,
    lat,
    lon,
    suggestionCount,
  );
}

/// The location facets a non-`feed` exposure reports, read off the resolved
/// Search Center the request used (or would have used).
///
/// Returns nulls rather than throwing when nothing has resolved: an exposure
/// must never be withheld because its *annotation* is unavailable.
({String? source, String? cityId, double? lat, double? lon}) _locationFacets(
  ResolvedSearchLocation? location,
) {
  if (location == null) {
    return (source: null, cityId: null, lat: null, lon: null);
  }
  // ⚠️ **Through [feedCoordinatePair], never straight off the model** — the same
  // guard `feedLocationGateProvider` and `_fetchPage` use, one layer along.
  // Nothing upstream validates coordinates: a persisted scope passes
  // `center_lat`/`center_lng` through as raw doubles, on a payload its own doc
  // says can drift across app updates.
  //
  // Two things break without it. A non-finite value reaches `jsonEncode` as
  // `NaN` and throws, taking the whole dispatch with it — `coarseCoordinate`
  // propagates NaN rather than rejecting it. And an out-of-range or
  // half-present pair would be reported as the location the feed used when the
  // feed explicitly refused it — on a `no_location` row exactly backwards,
  // since a rejected pair is one of the few ways to reach that state at all.
  // Guarded, the row says what is true: nothing usable resolved.
  final coords = feedCoordinatePair(location.centerLat, location.centerLon);
  return (
    source: location.origin.wire,
    cityId: location.cityId,
    lat: coords.lat,
    lon: coords.lon,
  );
}

/// What to report for the page on screen, or `null` while the feed has not
/// resolved yet.
///
/// Keyed on **the variant the caller already resolved** — never re-derived
/// here; see the file header.
///
/// `autoDispose` is load-bearing, not decoration: a keep-alive `Provider`
/// watching an `autoDispose` one PINS it, so a keep-alive version of this would
/// stop [feedHomeProvider] ever disposing and the feed would be reused stale on
/// every re-entry. Same trap `feedSlateLoadingProvider` documents in
/// `feed_home_provider.dart`.
final feedExposureProvider = Provider.autoDispose.family<FeedExposure?, bool>((
  ref,
  isV2,
) {
  final filter = ref.watch(feedFilterProvider).wire;

  // Legacy Discovery has no slate and no filter bar. It is shown the moment
  // it mounts, so there is nothing to wait for; `0` blocks is the only
  // honest count, and the filter can only ever hold its default.
  //
  // PROD-4531 — `state: feed` for the same reason: v1 has one state and it is
  // the feed. There is no wait to report either; `wait_ms` is measured at the
  // call site and comes out ~0 here, which is the honest number for a page
  // that is shown the moment it mounts.
  if (!isV2) {
    return FeedExposure(
      filter: filter,
      blockCount: 0,
      state: FeedExposureState.feed,
    );
  }

  // **Gated before `feedHomeProvider`, and the order is the feature.** With
  // no usable location the contract answers 400, so `DiscoveryFeedV2Screen`
  // deliberately does not subscribe — and `ref.watch` here would fire the
  // exact request it withholds. `loading` is "not known yet", not "no
  // location": reporting 0 blocks then would beat the real feed to the
  // dedup key and permanently under-report the slate.
  // ⚠️ **This is the second subscription to `feedHomeProvider` in `lib/`, and
  // it is easy to miss.** The screen's own comment used to call its `watch` the
  // only one; it is not, and this provider is the other one. Any future "the
  // feed must not be requested when X" rule has to be applied in both places or
  // it is not a rule.
  //
  // PROD-4520 — a guest on *Pessoas* is no longer one of those cases. The
  // request now happens for them like any other filter and the backend answers
  // with a `sign_in_gate` block, so this counts as an ordinary exposure with
  // whatever the page contained.
  final gate = ref.watch(feedLocationGateProvider);
  if (gate.isLoading) return null;
  if (gate.valueOrNull != true) {
    // The notice state renders and the feed is never requested. The user
    // did reach v2, so this counts as exposure — suppressing it would hide
    // precisely the cohort with the worst experience from the funnel.
    //
    // PROD-4531 — the location facets are read anyway, and will be almost
    // entirely null: the gate returns false precisely when there is neither a
    // `city_id` nor a usable coordinate pair. `location_source` is the one
    // that still says something (which cascade produced the nothing).
    final here = _locationFacets(
      ref.watch(resolvedSearchLocationProvider).valueOrNull,
    );
    return FeedExposure(
      filter: filter,
      blockCount: 0,
      state: FeedExposureState.noLocation,
      locationSource: here.source,
      cityId: here.cityId,
      lat: here.lat,
      lon: here.lon,
    );
  }

  final feed = ref.watch(feedHomeProvider);

  // Exposure means the feed was actually SHOWN. A reader who leaves during
  // the first fetch reports nothing, deliberately — they saw no feed.
  // A filter switch rebuilds this keyed notifier and passes back through
  // `loading`, which is what makes the next filter a new exposure.
  if (feed.isLoading) return null;

  final blocks = feed.valueOrNull?.blocks ?? const <FeedBlock>[];

  // PROD-4531 — **what the reader saw**, decided off the list the screen
  // actually draws rather than off the wire. `renderableFeedBlocks` is the same
  // filter `_dataSlivers` applies, so `empty` here means `FeedEmptyState` paints
  // there. `error` matches for the same reason: the screen's `feed.when` takes
  // the error branch whenever `hasError`, stale value or not, so this does too.
  //
  // ⚠️ **One deliberate exception: the forced debug states.** `_dataSlivers`
  // injects `debugUnknownAreaBlock()` when `feedForcedStateProvider` says so,
  // and `build` swaps the empty and error states in above `feed.when`. None of
  // that is mirrored here, because `state` must describe what the BACKEND
  // produced — a forced state that also forged the analytics would make the
  // event unable to answer the one question it was added for. Nothing in `lib/`
  // writes that provider today (PROD-4501), so the divergence is currently
  // unreachable; it stays correct if a future tab writes it again.
  //
  // ⚠️ It needs `isAuthenticated`, which is a NEW dependency of this provider.
  // Riverpod overrides are per-provider, not per-value, so a test that
  // overrides only the feed now also needs this one — see the note in
  // `feed_exposure_test.dart`.
  final renderable = renderableFeedBlocks(
    blocks,
    isAuthenticated: ref.watch(isAuthenticatedProvider),
  );

  // A plain loop rather than `firstOrNull`: that is a `package:collection`
  // extension, and this file has no other reason to depend on it.
  FeedBlockUnknownArea? unknownArea;
  for (final block in renderable) {
    if (block is FeedBlockUnknownArea) {
      unknownArea = block;
      break;
    }
  }

  final state = switch (renderable) {
    _ when feed.hasError => FeedExposureState.error,
    // D1 — zero renderable blocks after a successful request is `empty`, full
    // stop. No separate value for the still-paging case: "we just want whatever
    // gets us to the state of displaying `FeedEmptyState`".
    [] => FeedExposureState.empty,
    _ when unknownArea != null => FeedExposureState.unknownArea,
    _ when renderable.any((b) => b is FeedBlockSignInGate) =>
      FeedExposureState.signInGate,
    _ => FeedExposureState.feed,
  };

  // The ordinary row stays as small as it was — see [FeedExposure.locationSource].
  if (state == FeedExposureState.feed) {
    return FeedExposure(
      filter: filter,
      blockCount: blocks.length,
      state: state,
    );
  }

  final here = _locationFacets(
    ref.watch(resolvedSearchLocationProvider).valueOrNull,
  );
  return FeedExposure(
    filter: filter,
    blockCount: blocks.length,
    state: state,
    locationSource: here.source,
    cityId: here.cityId,
    lat: here.lat,
    lon: here.lon,
    // ⚠️ **Gated on the STATE, not on the block being present.** On an error
    // that follows a successful slate, Riverpod surfaces the previous value
    // through `valueOrNull` while `hasError` is true — so `unknownArea` can be
    // non-null on a row whose `state` is `error`, and reading the length off it
    // would attribute the previous slate's suggestions to a failed request and
    // break the contract's own "only when `state = unknown_area`". Found by
    // codex review.
    suggestionCount: state == FeedExposureState.unknownArea
        ? unknownArea?.suggestions.length
        : null,
  );
});
