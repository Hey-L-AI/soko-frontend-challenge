// PROD-4005 — page-chrome UI state for the server-driven feed.
//
// Session-scoped `StateProvider`s with no persistence, deliberately.

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/models/user_profile.dart';
import '../../../../core/services/location_service.dart';
import '../../../../providers/location_provider.dart';
import '../../../../providers/providers.dart';
import '../../../../providers/resolved_search_location_provider.dart';
import 'feed_home_provider.dart';
import 'feed_variant_provider.dart';

/// Whether the "Procura" + filter bar overlay is open.
///
/// D38: the bar OVERLAYS rather than pushing content, and closes after a
/// selection. Keeping "is it open" here rather than in the page's `State` lets
/// the pinned header's left button and the inline entry point drive the same
/// overlay.
final feedFilterBarOpenProvider = StateProvider<bool>((ref) => false);

/// PROD-4179 — whether the feed is in **Procura mode**: the filter row has
/// morphed into the search chrome and the page is a search surface.
///
/// It replaces the `/feed/search` route (D121), so this flag is now the whole
/// answer to "is the user searching". Session-scoped like its neighbours, and
/// deliberately NOT persisted — coming back to the app inside a half-finished
/// search is not a state anyone asked for.
///
/// Kept here rather than in the page's `State` for the same reason
/// [feedFilterBarOpenProvider] is: the row is mounted twice (inline and in the
/// pinned header) and both copies must read one answer.
final feedProcuraModeProvider = StateProvider<bool>((ref) => false);

/// A feed state the admin debug panel can force, for reviewing UI that is
/// otherwise hard or impossible to reach (PROD-4286 / PROD-4288).
///
/// **One enum rather than three booleans, deliberately.** These states are
/// mutually exclusive on screen — a feed cannot be both empty and errored — and
/// separate flags would let the panel express a combination the page then has
/// to invent a precedence rule for. Here the illegal states cannot be spelled.
enum FeedForcedState {
  /// Whatever the API actually returns.
  none,

  /// Inject the `unknown_area` block (PROD-4288). Its emitter, PROD-4290, is
  /// not built, so this is the only way to see it.
  unknownArea,

  /// Render the zero-block empty state, whatever the feed holds.
  empty,

  /// Render the request-failure state, without failing a request.
  error,

  /// PROD-4301 — pretend no location resolved.
  ///
  /// ⚠️ **This one forces the GATE, not the render**, unlike [empty] and
  /// [error]. Those are *response* states: a request happens either way, so
  /// swapping the widget in downstream shows exactly what ships. This is a
  /// *pre-request* decision — the feature IS "notice there is no location and
  /// never call `/feed/home`" — so a render-level force would prove the widget
  /// draws and nothing about the detection or the skipped request. See
  /// `feed_debug_blocks.dart`: "Rendering a different tree from the production
  /// one is how a debug affordance passes while the real feature is broken."
  ///
  /// Forced, the reviewer sees the real thing: no request is issued, the
  /// ask-state renders, and tapping its CTA resolves a location for real.
  noLocation,
}

/// Which feed state is being forced for review.
///
/// ⚠️ **Nothing in `lib/` writes this today, and that is on purpose.** The
/// PROD-4500 tab that wrote it was removed by PROD-4501 once the people feed
/// had been QA'd — the second time this has happened, after PROD-4005's tab
/// went in PROD-4008. The machinery survives both removals deliberately: it is
/// what makes the next tab cheap to build, and deleting it is what would force
/// the next person to rebuild it from scratch.
///
/// A scaffold with an expiry date. `unknownArea` goes when PROD-4290 reaches
/// staging; `empty` and `error` are worth keeping longer — both are states a
/// reviewer otherwise has to break the backend to see.
///
/// Session-scoped and not persisted, like its neighbours — and read behind
/// [feedDebugAccessProvider] at every use site, so a non-admin on a release
/// build cannot reach any of it whatever this holds.
final feedForcedStateProvider = StateProvider<FeedForcedState>(
  (ref) => FeedForcedState.none,
);

/// PROD-4301 — **is there a location we could actually send?**
///
/// False in exactly the cases `GET /feed/home` would answer **400** for: a
/// country-only scope, GPS auto-follow that resolved neither a boundary nor a
/// matching city name, no fix and no IP, and the cold-start state before
/// anything has resolved. The page renders the ask-state for those and does not
/// call the endpoint at all — the client already knows the answer, so asking
/// only to be told 400 buys a wasted round-trip and an error to swallow.
///
/// **Mirrors the backend's own rule**, so the two cannot disagree about what
/// counts as a signal: `resolve_search_location` treats a resolvable `city_id`
/// OR a valid coordinate pair as usable, and nothing else.
///
/// ⚠️ **Coordinates are tested with [feedCoordinatePair], not re-derived here.**
/// That is already the function deciding whether coordinates are *sendable*
/// (finite, in range, both present), so gate and payload cannot drift: a
/// coordinate this accepts is one `_fetchPage` will send, and one it rejects is
/// one that would have been dropped anyway — leaving nothing to send.
///
/// **Derived, never latched.** This answers "is there a resolvable location
/// *right now*", not "has the user picked one". A permission grant, a GPS fix
/// or a successful IP retry resolves a location with no pick at all, and the
/// feed must simply build when that happens.
/// PROD-4301 — has the device granted location permission?
///
/// A narrow derived provider rather than the widget reading `locationProvider`
/// directly, for the usual reason: the no-location state needs **one boolean**,
/// and a widget test that had to build a real `LocationNotifier` would need all
/// five of its platform dependencies to answer it.
///
/// `null` (nothing has checked yet) reads as **not granted**, so the affordance
/// appears rather than hiding behind an unknown. Requesting permission when it
/// is already granted is idempotent, so guessing wrong costs a harmless extra
/// button — guessing the other way costs the user their only route to GPS.
///
/// Safe as a keep-alive `Provider`: `locationProvider` is global, not
/// `autoDispose`, so watching it here pins nothing.
final feedGpsPermissionGrantedProvider = Provider<bool>((ref) {
  final status = ref.watch(locationProvider.select((s) => s.permissionStatus));
  return status == LocationPermissionStatus.granted;
});

final feedLocationGateProvider = FutureProvider<bool>((ref) async {
  if (ref.watch(feedForcedStateProvider) == FeedForcedState.noLocation &&
      ref.watch(feedDebugAccessProvider)) {
    return false;
  }
  final location = await ref.watch(resolvedSearchLocationProvider.future);
  if (location.cityId != null) return true;
  final coords = feedCoordinatePair(location.centerLat, location.centerLon);
  return coords.lat != null && coords.lon != null;
});

/// Whether this viewer may use the feed's debug affordances — today, the
/// forced feed states ([feedForcedStateProvider]).
///
/// PROD-4008 — this is NOT what decides which Discovery page renders. It was,
/// from PROD-4005 to PROD-4008: the mount site read `feedDebugAccessProvider
/// && feedV2EnabledProvider`, so no non-admin could reach the v2 feed whatever
/// the release flag said. That gate and the right-edge tab that drove it are
/// gone; `discoveryFeedVariantProvider` alone picks the page.
///
/// `isAdmin || kDebugMode`, mirroring `map_screen.dart`'s gate
/// (`if (isAdmin || kDebugMode) const MapDebugTab()`): admins need it against
/// production (a comparison you cannot run locally is not a comparison), and
/// local dev builds get it for convenience.
///
/// **On every build a real user can run, this is `isAdmin` and nothing else.**
/// `kDebugMode` is compiled `false` in release, and `render-build.sh` builds
/// staging *and* production with `flutter build web --release`; store binaries
/// are release too. `kDebugMode` is true only on a local dev server.
///
/// A provider rather than an inline check so tests can drive both sides. Under
/// `flutter test`, `kDebugMode` is always true, so an inline expression would
/// make "a non-admin does NOT get this" unassertable — and that is the half
/// worth proving.
final feedDebugAccessProvider = Provider<bool>((ref) {
  return feedDebugAccessFor(
    role: ref.watch(currentUserProvider)?.role,
    debugBuild: kDebugMode,
  );
});

/// The debug-access rule itself, with the build mode as a parameter.
///
/// PROD-4007 — extracted so the half that actually matters can be asserted.
/// Every existing test **overrides [feedDebugAccessProvider] away** (it has to:
/// `kDebugMode` is true under `flutter test`, so the real provider would grant
/// access to everyone), which proved the mount site *uses* the gate correctly
/// while nothing proved the gate was *defined* correctly — widening it to
/// `|| isStaging` would have kept the whole suite green.
///
/// The case worth pinning is `role: user, debugBuild: false` → `false`: a real
/// user on a release build. See `feed_debug_access_test.dart`.
bool feedDebugAccessFor({required UserRole? role, required bool debugBuild}) {
  return role == UserRole.admin || debugBuild;
}

/// Feeds [UnifiedAnalyticsService] the variant of the page actually rendered.
///
/// PROD-4008 — that is now [discoveryFeedVariantProvider] itself: it is the one
/// expression `DiscoveryVariantPage` renders and this stamps, so the page on
/// screen and the `feed_variant` on its events cannot disagree (D46). Under
/// PROD-4007 the rendered page was `feedDebugAccessProvider &&
/// feedV2EnabledProvider` and this read that composite instead.
/// `ref.read` inside the closure, evaluated per event — see [FeedVariantHolder]
/// for why a `ref.listen` push into a mutable field was wrong. The holder
/// instance is stable on purpose: `unifiedAnalyticsProvider` watches this, and
/// handing it a new instance per change would rebuild `UnifiedAnalyticsService`
/// and reset its once-per-session `discovery_shelf_viewed` dedup set.
final feedVariantHolderProvider = Provider<FeedVariantHolder>((ref) {
  return FeedVariantHolder(() => ref.read(discoveryFeedVariantProvider));
});
