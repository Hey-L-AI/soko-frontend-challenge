// PROD-4008 — which Discovery page the route builds: the legacy shelf stack or
// the server-driven v2 feed, decided by the `discovery-feed-v2` release flag
// (D44) as held for the session by `discoveryFeedVariantProvider` (D48/D49).
//
// This replaces `DiscoveryPageSwitcher`, the admin-only seam PROD-4005 shipped
// so the v2 page could be looked at before the flag existed. The admin gate
// that sat in front of the variant, and the right-edge tab that toggled it, are
// gone with it: from here on the ONLY thing between a user and the new feed is
// the flag's targeting in the PostHog dashboard. That is a weaker guarantee
// than the code gate was, and an intentional trade — see
// `docs/features/feature-flags.md` § `discovery-feed-v2`.
//
// **Read the variant provider, never the raw `ExperimentState` field.** The
// flag resolves asynchronously and `reloadFlags()` double-loads with a 2-second
// delay; gating a whole page on the resolved value would show a v2 user the
// legacy page, then flip it. The variant provider decides once, at creation,
// and holds that answer — so there is no frame in which the answer is unknown.
//
// PROD-4419 — **and read the gate before the variant, never after.** The
// variant provider fixes the session the instant it is created, so touching it
// before the flag has answered commits the user to the cached value (`false` on
// every fresh install) for the whole session. That is the "v2 arrives one cold
// start late" bug. The gate holds this route — and only this route — until the
// answer is in hand or its cap fires.
//
// PROD-4423 — **and everything the exposure event needs is read after both.**
// `feed_exposed` is the denominator for the whole A/B comparison, so it is
// emitted from here, the one place that knows which page a user actually got.
// It hangs off a RESOLVED page state, which is also why nothing fires during
// the gate's splash: "which feed was the reader exposed to" has no answer while
// neither page is on screen.
//
// PROD-4436 — **and `feed_exposed` is preceded by a second event that is not
// deferred.** Hanging off a resolved page state is what makes `feed_exposed`
// honest and what makes it a BAD denominator: v1 resolves at mount, v2 only
// after its first fetch, so the two arms' exposure is not counted the same way.
// `feed_variant_committed` fires at the decision instead — synchronously,
// before the watch that starts the fetch — so the abandonment between them is
// measurable. The two emits read in opposite directions on purpose; see the
// comment at each call site before moving either.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../shared/widgets/soko_splash_view.dart';
import '../providers/feed_exposure_provider.dart';
import '../providers/feed_filter_provider.dart';
import '../providers/feed_variant_provider.dart';
import 'discovery_feed_v2_screen.dart';

class DiscoveryVariantPage extends ConsumerStatefulWidget {
  /// The legacy Discovery page, built by the router with its deep-link nonces.
  final Widget legacy;

  const DiscoveryVariantPage({super.key, required this.legacy});

  @override
  ConsumerState<DiscoveryVariantPage> createState() =>
      _DiscoveryVariantPageState();
}

/// Stateful only for `mounted`: the emit is deferred to a post-frame callback
/// so the event marks the page RENDERING rather than the fetch resolving (the
/// discipline `_sessionTracker?.pagePresented` already follows), and
/// `ref.read` on a disposed `WidgetRef` throws.
class _DiscoveryVariantPageState extends ConsumerState<DiscoveryVariantPage> {
  /// PROD-4531 — the wait `feed_exposed.wait_ms` reports: request start → the
  /// paint that fires the event. Monotonic, never a wall clock, and the event
  /// carries the number rather than two timestamps for the dashboard to pair.
  ///
  /// **Page-local rather than a keep-alive holder, deliberately.** The thing
  /// being timed is `feedHomeProvider`, which is `autoDispose` — so it restarts
  /// its request exactly when this State is recreated, and a clock with the
  /// same lifetime cannot drift out of step with it. A keep-alive holder would
  /// have to be purged on identity change to avoid timing a signed-out
  /// reader's wait under a new account, and would still be wrong on the one
  /// case it was meant to fix.
  ///
  /// ⚠️ **Not a field on `FeedExposure`.** That class's value equality is
  /// load-bearing against rebuild loops and this provider recomputes on every
  /// `feedHomeProvider` movement — a monotonically rising field on it would
  /// make every payload unequal and rebuild the page forever.
  final Stopwatch _wait = Stopwatch();

  /// What [_wait] is currently timing, as `variant|filter`.
  ///
  /// ⚠️ **The same key `feed_exposed` dedupes on, and that is not a
  /// coincidence.** Every distinct key is one emitted row, so the clock must
  /// restart exactly where a new row starts. Keying on the filter alone looks
  /// right and is wrong for the mid-session variant changes PROD-4425 and
  /// PROD-4008 made routine: `post_login`, `rollback` and `sign_out` all move
  /// `v1 <-> v2` while the filter stays `events`, which emits a SECOND row —
  /// and it would have carried a clock started at the previous variant's
  /// decision, possibly minutes earlier. Found by codex review.
  String? _waitingFor;

  /// Start timing this `(variant, filter)` unless it is already being timed.
  ///
  /// Called from `build`, above the watch that creates `feedHomeProvider` — so
  /// the clock is always started a statement before the request it measures,
  /// never after. That direction matters: a clock started late reports a wait
  /// shorter than the reader's, which is the failure mode that makes the
  /// number worthless.
  void _startWaitFor({required bool isV2, required String filter}) {
    final key = '${isV2 ? 'v2' : 'v1'}|$filter';
    if (_waitingFor == key) return;
    _waitingFor = key;
    _wait
      ..reset()
      ..start();
  }

  @override
  Widget build(BuildContext context) {
    // The early return is load-bearing: `discoveryFeedVariantProvider` must not
    // be read while the gate is closed, because reading it creates it and
    // creating it decides the session.
    //
    // The gate latches, so this costs a loading frame once per app launch at
    // most — not on every return from Map.
    if (!ref.watch(feedVariantGateProvider)) return const SokoSplashView();

    // One expression, three readers: `feedVariantHolderProvider` stamps
    // `feed_variant` on Discovery analytics from this same provider, and
    // `feedExposureProvider` is HANDED the result rather than deriving it, so
    // the page on screen, the label on its events, and the exposure event
    // cannot disagree (D46).
    final showV2 = ref.watch(discoveryFeedVariantProvider);

    // Why the gate opened, snapshotted when it latched. Non-null past the early
    // return above — every latch site writes it — so the fallback is defensive
    // only, and `cap` is the honest answer if one were ever missed: it claims
    // the least.
    final variantSource =
        ref.watch(feedVariantSourceProvider) ?? FeedVariantSource.cap;

    // PROD-4436 — the commit beat, and **the two lines below it are why this
    // one is not deferred.**
    //
    // `feed_exposed` cannot be the A/B denominator it was built to be: v1
    // reports the moment it mounts, while v2 waits on `feedHomeProvider` and
    // deliberately reports nothing if the reader leaves during the first fetch.
    // The fastest bouncers are therefore dropped from the treatment arm only.
    // This event is the symmetric one — fired at the decision, on both arms —
    // and the gap between the two is v2 fetch abandonment.
    //
    // **Synchronous, and physically above the `ref.watch` below.** That watch
    // creates `feedHomeProvider`, whose `async build()` runs to its first await
    // at once and resumes on a microtask — and microtasks drain before the
    // frame ends. So an `addPostFrameCallback` here would fire AFTER the fetch
    // had already started, losing exactly the readers this event exists to
    // count. `feed_exposed` marks a RENDER, so post-frame is right for it; this
    // marks a DECISION, so it is not. Keeping the ordering structural rather
    // than a matter of callback-registration order is the point — a refactor
    // that moves this below the watch is then a visible code move.
    //
    // Emitting during `build` is safe here specifically because `_dispatch`
    // touches no provider and no element; it is fire-and-forget I/O, and
    // `ref.read` of a keep-alive provider is legal in build. A speculative
    // build that never paints still emits, which is correct: the beat means
    // "committed", not "rendered". Deduped per variant per app session inside
    // the service, so every rebuild after the first is free.
    ref
        .read(unifiedAnalyticsProvider)
        .trackFeedVariantCommitted(
          variantSource: variantSource.wire,
          // PROD-4455 — what the wait actually cost this reader. Read off the
          // gate rather than measured here: the gate starts holding before this
          // page's first build, so a clock started here would report ~0 for
          // every session and make the wait look free.
          gateWaitMs: ref.read(feedVariantGateProvider.notifier).waitMs,
        );

    // PROD-4531 — **the decision is where `wait_ms` starts**, which is this
    // line and not one above it. Above is the gate's splash, and that wait is
    // already reported as `gate_wait_ms` on the beat immediately preceding
    // this; starting here is what keeps the two from double-counting the same
    // seconds. The early return for a closed gate guarantees we never get here
    // while it holds.
    //
    // Watched, not read: `feedFilterProvider` is a plain `StateProvider`, and
    // the page already rebuilds on a filter change through the exposure
    // provider below — so this adds a dependency that was there in substance,
    // and no rebuild that was not.
    _startWaitFor(isV2: showV2, filter: ref.watch(feedFilterProvider).wire);

    // Null until there is something honest to report — see the provider. Only
    // reachable past the gate, which is what keeps the PROD-4419 invariant
    // true for the exposure path too.
    final exposure = ref.watch(feedExposureProvider(showV2));
    if (exposure != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Deduped per (variant, filter) per session inside the service, so a
        // rebuild re-calling this is a no-op and a filter switch is not.
        ref
            .read(unifiedAnalyticsProvider)
            .trackFeedExposed(
              feedFilter: exposure.filter,
              blockCount: exposure.blockCount,
              variantSource: variantSource.wire,
              state: exposure.state.wire,
              // Read at the paint, which is what makes this the wait the
              // reader actually experienced rather than the time the fetch
              // took.
              waitMs: _wait.elapsedMilliseconds,
              locationSource: exposure.locationSource,
              cityId: exposure.cityId,
              lat: exposure.lat,
              lon: exposure.lon,
              suggestionCount: exposure.suggestionCount,
            );
      });
    }

    return showV2 ? const DiscoveryFeedV2Screen() : widget.legacy;
  }
}
