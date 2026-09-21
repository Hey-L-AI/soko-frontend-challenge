import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/api_provider.dart';
import '../../../providers/city_auto_scope_provider.dart';
import '../../../providers/detected_country_provider.dart';
import '../../daily_drop/providers/daily_drop_provider.dart';
import '../../weekly_bundle/providers/weekly_bundle_provider.dart';
import '../feed_v2/providers/feed_home_provider.dart';
import 'city_guides_shelf_provider.dart';
import 'editor_picks_shelf_provider.dart';
import 'happening_shelf_provider.dart';
import 'highlighted_shelf_provider.dart';
import 'history_grid_provider.dart';
import 'most_followed_shelf_provider.dart';
import 'near_you_places_shelf_provider.dart';
import 'recommended_shelf_provider.dart';
import 'spaces_shelf_provider.dart';

/// Refresh every provider that powers the Discovery **route** — the legacy
/// page's sections (Daily Drop, Weekly Bundle, History Grid, and the shelves)
/// and the v2 feed, which renders under that same route.
///
/// Three refresh strategies depending on the provider type:
///   * **FutureProvider.autoDispose** (history grid + the six shelves that
///     return immutable lists): use `ref.invalidate(...)` — invalidating
///     causes the still-watching widget to trigger a fresh fetch.
///   * **StateNotifierProvider** (Daily Drop, Weekly Bundle, Happening,
///     NearYou places, Spaces): use the notifier's own `refresh()` method
///     via `ref.read(provider.notifier).refresh()`. Invalidating a
///     StateNotifierProvider discards the notifier and creates a new one
///     in its initial (skeleton/loading) state — the new notifier's
///     factory wires `ref.listen(discoveryCityProvider, ...)` but
///     intentionally skips the first emission (the section widget's
///     `initState` is supposed to do the initial load). Since the widget
///     stays mounted across the refresh, `initState` doesn't re-run and
///     the section gets stuck on its skeleton forever. This was the
///     symptom of PROD-2065 on Daily Drop + Weekly Bundle (and probably
///     contributed to the "location lost" report — invalidating a
///     StateNotifier also tears down its `ref.listen` subscriptions
///     mid-refresh).
///   * **AsyncNotifierProvider.autoDispose** (the v2 feed): `ref.invalidate`
///     again — it rebuilds from `build()`, which refetches page 1 — but with
///     no companion `.future` read. See the note at the call site (PROD-4281).
///
/// The returned future stays pending until the awaited tasks resolve, so
/// `CupertinoSliverRefreshControl` keeps its spinner visible while real
/// data is loading. 600 ms floor prevents a flash-collapse on instant
/// (cached) responses; 4 s ceiling protects against a hung API stranding
/// the spinner.
Future<void> refreshDiscoveryFeed(
  WidgetRef ref, {
  bool holdSpinner = true,
}) async {
  // PROD-2065: also invalidate the IP-detection chain so a user stuck
  // with a cached-null country (e.g. ipapi.co 429'd them at app startup
  // before the network settled) can pull-to-refresh to recover. The
  // underlying `IpGeolocationService` has its own 24h cache so this is
  // cheap when it would otherwise hit the network.
  ref.invalidate(detectedCountryCodeProvider);
  ref.invalidate(cityAutoScopeProvider);

  // FutureProvider.autoDispose shelves — invalidate is correct.
  ref.invalidate(historyGridProvider);
  ref.invalidate(highlightedShelfProvider);
  ref.invalidate(editorPicksShelfProvider);
  ref.invalidate(recommendedShelfProvider);
  ref.invalidate(cityGuidesShelfProvider);

  // PROD-4281 — the v2 feed. It is one `AsyncNotifierProvider.autoDispose`
  // rather than a shelf per section, and `invalidate` is the right verb for it:
  // unlike the PROD-2065 `StateNotifier` shelves it rebuilds from `build()`,
  // which refetches page 1 and resets the seed stores through their own
  // start-order tokens.
  //
  // It belongs HERE, not in `refreshBackendOwnedStrings`, because this function
  // is not "the legacy shelves" — it is **the Discovery route's refresh**, and
  // the v2 page renders under that same route (`discoveryPageName`). The shell
  // hands this very function to its `CupertinoSliverRefreshControl` whichever
  // page is showing, so with the line anywhere else a pull-to-refresh on the v2
  // feed would go on refreshing ten shelves that page does not render and
  // leaving the feed itself untouched.
  //
  // ⚠️ **No `.future` read below to match**, deliberately, and not for the
  // spinner reason the shelves have. `feedHomeProvider` is autoDispose, so on
  // the LEGACY Discovery page — where nothing watches it — reading `.future`
  // would *construct* the v2 feed and fire a `/feed/home` request for a page
  // the user is not looking at, on every pull-to-refresh. The invalidate above
  // is already what makes a MOUNTED feed refetch; an unmounted one is a no-op.
  ref.invalidate(feedHomeProvider);

  // context_changed (PROD-4303) — the feed the reader was looking at is being
  // recomposed under the same visit. The tracker drops the event when no
  // discovery session is live (legacy Discovery page, feed off screen), so
  // this cannot attribute a refresh to a visit that is not happening.
  ref.read(discoverySessionTrackerProvider).contextChanged(context: 'refresh');

  // PROD-3979 — `holdSpinner: false` for callers with no spinner to hold (the
  // locale switch). The five `.future` reads below exist ONLY to keep the
  // pull-to-refresh spinner up while real data loads; for an autoDispose shelf
  // that nobody is watching, `ref.read(...future)` *constructs* the provider
  // and starts a fetch with no consumer, which is then thrown away and fetched
  // again when the section actually mounts. The `invalidate` calls above are
  // what make a MOUNTED shelf refetch, and they are already done — so skipping
  // the reads loses nothing and saves a duplicate round-trip per shelf.
  //
  // The StateNotifier `refresh()` calls still run either way: several of those
  // shelves `keepAlive()`, so they hold stale data whether or not the feed is
  // on screen — refreshing them is the point, not an eager side effect.
  final tasks = <Future<Object?>>[
    // FutureProvider shelves — re-read .future after invalidate, but ONLY when
    // a spinner is being held (see the note above: for an unwatched shelf this
    // read is what constructs it).
    if (holdSpinner) ...[
      ref.read(historyGridProvider.future),
      ref.read(highlightedShelfProvider.future),
      ref.read(editorPicksShelfProvider.future),
      ref.read(recommendedShelfProvider.future),
      ref.read(cityGuidesShelfProvider.future),
    ],
    // StateNotifier shelves — call refresh() on the existing notifier so
    // its `ref.listen(discoveryCityProvider, ...)` subscription stays put
    // and its widget never sees a fresh skeleton state. Trending joined
    // this group in PROD-2221 (was a `FutureProvider` previously).
    ref.read(dailyDropProvider.notifier).refresh(),
    ref.read(weeklyBundleProvider.notifier).refresh(),
    ref.read(happeningShelfProvider.notifier).refresh(),
    ref.read(nearYouPlacesShelfProvider.notifier).refresh(),
    ref.read(spacesShelfProvider.notifier).refresh(),
    // PROD-2416: homepage "Most followed" row is now its own provider
    // (top-25 by save count). The legacy trendingShelfProvider still
    // backs the search-overlay grid and refreshes on its own.
    ref.read(mostFollowedShelfProvider.notifier).refresh(),
  ];

  if (!holdSpinner) {
    await Future.wait<void>(tasks.map(_swallow));
    return;
  }

  await _holdSpinner(tasks);
}

/// Errors are swallowed on purpose — individual shelves render their own error
/// state, so one failing shelf must not sink the whole refresh.
Future<void> _swallow(Future<Object?> f) =>
    f.then<void>((_) {}, onError: (_) {});

/// Hold the pull-to-refresh future until [tasks] resolve (errors swallowed
/// — individual shelves render their own error state), with a min visible
/// time and a hard ceiling.
Future<void> _holdSpinner(List<Future<Object?>> tasks) async {
  await Future.wait<void>([
    Future<void>.delayed(const Duration(milliseconds: 600)),
    Future.wait<void>(
      tasks.map(_swallow),
    ).timeout(const Duration(seconds: 4), onTimeout: () => const <void>[]),
  ]);
}
