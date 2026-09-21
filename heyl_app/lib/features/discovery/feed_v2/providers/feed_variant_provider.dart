// PROD-4007 — which Discovery page this SESSION is on, held fixed for the
// session (D48) with two deliberate exceptions (D49 rollback, and since
// PROD-4425 a post-login re-decide).
//
// **Why this file exists at all.** `ExperimentState` starts at defaults with
// `loaded: false` and resolves asynchronously, and `ExperimentNotifier
// .reloadFlags()` double-loads with a 2-second delay on purpose so PostHog can
// ingest person properties before targeting evaluates. Every other flag in the
// app gates something small — a button, a toggle, a slot — so a late resolve is
// invisible. This one would gate an ENTIRE PAGE: read naively, a v2 user gets
// old page → flash → new page on every cold start, and watches the page swap
// two seconds after logging in.
//
// So the resolved flag is not what the app renders. This is:
//
//   * **Creation uses the best answer available at that instant** — the
//     resolved flag if it is real (see `_isRealAnswer`), the cached variant
//     otherwise. Either way it is decided synchronously inside `build()`, so
//     there is no frame in which the answer is unknown and nothing to flash
//     between.
//   * **An answer that arrives LATER is written to the cache but not acted
//     on** — it takes effect on the NEXT launch. That is the no-flash property.
//   * **Except rollback, which applies at once** (D49). Being pushed INTO the
//     new page mid-session is jarring and has no urgency; being moved OFF a
//     broken page onto the known-good one is a rescue, and it is the only thing
//     that keeps "revert instantly" true. "Next launch" is a browser page load
//     on web (an open tab can hold a variant indefinitely) and a cold start on
//     mobile (a backgrounded app may not restart for days) — so a symmetric
//     rule would make rollback arbitrarily slow, which is the one property the
//     flag exists for.
//   * **And except a post-login answer, which also applies at once**
//     (PROD-4425, see below). That one is not a rescue — it is the only way a
//     reader targeted as a signed-in identity reaches v2 in the session they
//     signed in.
//
// PROD-4419 — **the first bullet is the fix, and it used to say "startup reads
// the cache".** It read the cache even when a real, confirmed answer was
// sitting right there, which cost every newly-targeted user an entire launch:
// the cache starts `false` on every install, so nobody could reach v2 until the
// launch AFTER PostHog first said yes. With the flag at 50% that quietly
// throttled the whole rollout.
//
// The deferral was protecting against a flash that creation cannot produce. A
// flash needs two frames — one showing the old page, one showing the new — and
// `build()` runs once, before either. What genuinely can flash is a *late*
// answer arriving while the page is already on screen, and an ordinary late
// answer is still deferred (see `_onFlagsChanged`; PROD-4425 later carved out
// the post-login one). The two cases were conflated; they are now separated.
//
// Creation only gets the right answer if a fresh one has arrived by then, which
// is what `feedVariantGateProvider` below (plus
// `ExperimentState.flagsFetchedThisLaunch`) is for.
//
// PROD-4008 — **this provider IS what a real user sees.** `DiscoveryVariantPage`
// renders on it and nothing else; the admin code gate that sat in front of it
// under PROD-4007 (`discovery_page_switcher.dart`) is gone. Who is on v2 is
// now purely the flag's targeting in the PostHog dashboard.
//
// **Which made one more rule necessary: a variant a signed-in identity earned
// does not outlive that identity's session on the device.** The cache is
// device-scoped, and nothing reloads flags after a sign-out (`resetFlags()`
// emits defaults with `loaded: false`, which this notifier rightly ignores). So
// an admin who resolved `true`, then signed out, would have handed v2 to
// whoever used the device next — for the rest of that guest session, and again
// as a flash on the next cold start until PostHog answered for the anonymous
// id. The admin gate used to mask exactly this; codex review caught it the
// moment the gate went. Sign-OUT therefore drops a signed-in-earned variant at
// once, while a variant the *guest* identity earned survives a sign-in /
// sign-out round trip, so a stage-3 guest is not bounced to legacy for two
// launches because they logged in once.
//
// PROD-4425 — **D27 ("a guest → login transition must not flip the page") is
// reversed, and only in the sign-IN direction.** A guest and a signed-in user
// are different PostHog identities, so `discovery-feed-v2` can evaluate
// differently for each; deferring meant a reader in the treatment arm *as a
// signed-in identity* browsed legacy for their entire first session after
// logging in, while the cache took the `true` and v2 arrived a launch late.
// Same loss PROD-4419 fixed for cold start, priced per login instead of per
// install. Zé's call (2026-09-15): the staleness costs more than the swap.
//
// Two things about it are decisions, not side effects:
//
//   * **The swap lands ~2s after login, not at login.** `reloadFlags()` is a
//     deliberate double-load with a 2-second delay so PostHog can ingest the
//     person properties before targeting re-evaluates, so by the time the
//     answer is real the reader may have scrolled, opened a card, or left Home.
//     That is precisely what D27 was protecting against. It is accepted
//     knowingly: a feed that changes at that moment reads as "logging in
//     personalised my feed" rather than as a glitch. There is no "only while
//     Discovery is mounted and un-scrolled" guard, on purpose.
//   * **The trigger is `ExperimentState.postIdentifyGeneration`, not
//     `flagsConfirmed`.** See `_onFlagsChanged` — acting on any confirmed
//     answer would silently undo D48 and would act on PRE-identify values.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/experiment_service.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../providers/auth_provider.dart';
import '../debug/feed_flag_debug_log.dart';

/// `shared_preferences` key holding the last variant PostHog resolved for this
/// device. Read at startup, written whenever the flag confirms.
///
/// Device-scoped, deliberately not per-account: it answers "which page did this
/// install last resolve to" — a starting point for the next launch, not a
/// record of who resolved it. PROD-4008's owner tag
/// ([kDiscoveryFeedVariantSignedInPrefsKey]) carries the identity question
/// instead. It used to say a sign-in must not change the answer mid-session
/// (D27); PROD-4425 reversed that for the page, and this key follows the
/// answer either way — `_persist` writes on every real resolve, including the
/// post-login one.
const String kDiscoveryFeedVariantPrefsKey = 'discovery_feed_v2_variant';

/// Whether the value under [kDiscoveryFeedVariantPrefsKey] was resolved while a
/// user was signed in (PROD-4008). A signed-in-earned `true` is dropped on
/// sign-out — see the file header; a guest-earned one is not.
const String kDiscoveryFeedVariantSignedInPrefsKey =
    'discovery_feed_v2_variant_signed_in';

/// PROD-4419 — how long Discovery waits for a flag answer before rendering on
/// whatever it has.
///
/// The wait is bounded because the alternative is a page that never paints. It
/// is not shorter because the thing being avoided — a whole session on the
/// wrong page — costs far more than a moment of loading frame. The refresh pass
/// it waits on has its own 2s timeout
/// (`ExperimentNotifier._discoveryRefreshTimeout`), so this cap should only
/// ever fire when that one has already failed.
/// How long the Discovery route holds [SokoSplashView] waiting for a real
/// `discovery-feed-v2` answer before committing to the cached value.
///
/// PROD-4455 raised this from 2500ms, for two reasons measured in production
/// on 2026-09-15. The first is coverage: p90 to the first real answer is
/// 2.27s, so 2500ms sat right on the shoulder of the distribution. The second
/// is that the old value was internally inconsistent — the refresh pass it is
/// waiting for has a 2s + 2s budget of its own, so the gate gave up ~1.5s
/// BEFORE its own fetch could finish. It now matches
/// `ExperimentNotifier._discoveryAnswerDeadline`; the two are one decision and
/// must move together.
const Duration kDiscoveryFeedVariantGateCap = Duration(milliseconds: 3000);

/// Whether Discovery may commit to a variant yet (PROD-4419).
///
/// **Why this is not in `_SplashGate`.** The obvious place to wait for a flag
/// is the splash, and it is the wrong one: `_SplashGate` wraps the router's
/// child (`app.dart`), so every route — deep links, onboarding, venue and list
/// pages — would pay a Discovery flag wait it has no use for. Caught in codex
/// review before it shipped. The wait belongs to the one route that cares.
///
/// **It latches.** Once open it never closes. Discovery unmounts and remounts
/// whenever the user visits Map and comes back; re-gating there would show a
/// loading frame on a page whose variant was settled minutes ago.
/// [discoveryFeedVariantProvider] is not auto-disposed, so the answer it
/// committed to is still the answer.
///
/// Opens when any of:
///   * the cached variant is already `true` — the session will render v2 and a
///     resolved `false` rolls it back at once (D49), so waiting buys nothing;
///   * the flags are confirmed AND a value was fetched this launch
///     (`flagsFetchedThisLaunch`) — the answer is real and current;
///   * [kDiscoveryFeedVariantGateCap] elapses — fail-open, render on the cache.
///
/// Read this before [discoveryFeedVariantProvider], never after: the variant
/// provider fixes the session the instant it is created, so creating it early
/// is exactly the bug this gate exists to prevent.
/// PROD-4423 — **why** the gate opened, snapshotted at the instant it latched.
///
/// Reported on `feed_exposed` so a dashboard can separate "we knew which feed
/// this reader should get" from "we guessed". It exists because PROD-4419's own
/// open question — how often the cap fires — was otherwise visible only in
/// device logs.
///
/// **This must be a snapshot, never derived at read time.** Deriving it would
/// re-create the bug it measures: `_refreshDiscoveryFlag` has two sequential
/// 2-second timeouts (`experiment_service.dart`), so the refresh can settle
/// around 4s while the cap fires at 2.5s. In that routine ~1.5s window the gate
/// has already opened on the cache, `flagsFetchedThisLaunch` then flips `true`,
/// and `feed_exposed` — which waits for the feed fetch — fires later still. A
/// value read then would report `fresh_flag` for precisely the sessions that
/// did not have a fresh flag.
///
/// PROD-4425 — **and it must be re-snapshotted when the decision is re-made.**
/// The first three values below all describe the gate's latch, which was the
/// only decision there was while the variant could not change mid-session. It
/// can now (the post-login re-decide), so a session that flipped would keep
/// reporting why the *superseded* decision was made. The last two name the
/// re-decisions themselves; [DiscoveryFeedVariantNotifier] owns them, and
/// [feedVariantSourceProvider] prefers them over the gate's latch.
enum FeedVariantSource {
  /// Opened on a real, current answer: `loaded && flagsConfirmed &&
  /// flagsFetchedThisLaunch` — **and `discoveryFlagIsFresh`**, which is the
  /// half that makes this value honest. See [refreshFailed].
  freshFlag('fresh_flag'),

  /// Opened because the cached variant was already `true`. Rendered from
  /// cache and near-certainly right — the session shows v2 and a resolved
  /// `false` rolls it back at once (D49).
  ///
  /// These sessions never see `SokoSplashView` at all: `_openReason` answers
  /// during `build()`, so the gate never closes.
  cached('cached'),

  /// [kDiscoveryFeedVariantGateCap] fired first. **We did not know** — the
  /// page rendered on a possibly-stale cache and the reader may be a launch
  /// behind. This is the cell PROD-4419's residual risk reads off.
  cap('cap'),

  /// PROD-4425 — the refresh pass finished **without a server value**, so the
  /// gate stopped waiting on a value the SDK had on disk. Epistemically this
  /// is [cap]: we did not know. It is separate because the route there is
  /// different — the fetch failed rather than the clock running out — and
  /// because a run of these means PostHog is unreachable, not that the cap is
  /// too tight.
  ///
  /// **This value is the fix for a defect `fresh_flag` shipped with.**
  /// `flagsFetchedThisLaunch` is fail-open by design: it is set when PostHog is
  /// disabled, when `reloadFeatureFlags()` times out, and when
  /// `getFeatureFlag()` times out or throws. Its own doc says it means "stop
  /// waiting for a fresher answer, never the answer is definitely fresh" —
  /// and PROD-4423 mapped it straight to [freshFlag] anyway, so every one of
  /// those sessions reported "we knew". Found in that ticket's staging
  /// verification. [cap] was therefore not the only "we did not know" cell,
  /// and the cap-fire rate understated real uncertainty.
  ///
  /// The gate still OPENS on this path — nothing about routing changes, only
  /// what the session admits to.
  refreshFailed('refresh_failed'),

  /// PROD-4425 — the session was **re-decided mid-session** from a
  /// post-identify fetch, after a sign-in changed which PostHog identity the
  /// flag evaluates for. Supersedes whatever the gate latched on.
  ///
  /// A distinct value rather than [freshFlag]: it is a fresh answer, but its
  /// provenance is a different event, and "how many readers changed feed
  /// because they logged in" is exactly the question this ticket ships.
  postLogin('post_login'),

  /// PROD-4425 — the session was re-decided mid-session by a D49 rollback: a
  /// real answer resolved `false` while the reader was on v2, and they were
  /// moved off at once.
  ///
  /// The gate's latch reason is *stale* for these rows too — the rollback is
  /// a second decision, made on a confirmed answer, and without this value a
  /// rolled-back session re-emits `feed_exposed` still claiming `cap`,
  /// polluting the one cell PROD-4419's residual risk is read off.
  rollback('rollback'),

  /// PROD-4425 — the session was moved to v1 because the signed-in identity
  /// that earned v2 signed out (PROD-4008). No flag answer is involved; the
  /// identity transition itself is the evidence.
  ///
  /// It exists because leaving the previous reason in place is actively wrong
  /// here: a session that flipped on [postLogin] and then signed out would keep
  /// reporting `post_login` while rendering v1. **The invariant is that every
  /// path which can move the variant mid-session names itself** — a path that
  /// does not is not "unlabelled", it inherits somebody else's label.
  signOut('sign_out');

  const FeedVariantSource(this.wire);

  /// The value sent on `feed_exposed`.
  final String wire;
}

final feedVariantGateProvider = NotifierProvider<FeedVariantGateNotifier, bool>(
  FeedVariantGateNotifier.new,
);

/// Why this session is on the variant it is on, or `null` while the gate is
/// still closed.
///
/// A provider rather than reaching for a notifier getter, so the dependency is
/// visible in the widget tree and a test can override it on its own.
///
/// PROD-4425 — **the most recent decision wins.** It used to be the gate's latch
/// reason and nothing else, which was complete only while the variant could not
/// move after creation. A post-login re-decide (and a D49 rollback) is a new
/// decision with its own provenance, so [DiscoveryFeedVariantNotifier.source]
/// takes precedence once it has one; until then it is null and the gate answers.
///
/// The gate guard stays **first**, and that ordering is load-bearing: reading
/// [discoveryFeedVariantProvider] is what CREATES it, and creating it fixes the
/// session (PROD-4419). The `ref.watch` below it is a rebuild trigger — the
/// source is not part of the notifier's `bool` state, so the flip is what
/// signals that it may have changed.
final feedVariantSourceProvider = Provider<FeedVariantSource?>((ref) {
  if (!ref.watch(feedVariantGateProvider)) return null;
  ref.watch(discoveryFeedVariantProvider);
  return ref.read(discoveryFeedVariantProvider.notifier).source ??
      ref.read(feedVariantGateProvider.notifier).source;
});

class FeedVariantGateNotifier extends Notifier<bool> {
  Timer? _cap;

  /// PROD-4455 — how long this session held [SokoSplashView] before committing
  /// to a variant. Started in `build()`, read once at whichever latch fires.
  ///
  /// This is the number the wait was introduced to justify: a wait nobody can
  /// see the cost of is a wait nobody can tune. It reaches the dashboard as
  /// `feed_variant_committed.gate_wait_ms`.
  final Stopwatch _held = Stopwatch();

  /// Milliseconds the gate held, or `null` until it opens. A session that
  /// opened during `build()` reports ~0 rather than null — it waited, for no
  /// measurable time, which is a different statement from "not yet decided".
  int? _waitMs;
  int? get waitMs => _waitMs;

  /// Why the gate opened (PROD-4423), written in the same statement as each
  /// latch and never afterwards. `null` until it opens.
  FeedVariantSource? _source;

  /// Why the gate opened. Read through [feedVariantSourceProvider].
  FeedVariantSource? get source => _source;

  @override
  bool build() {
    ref.onDispose(() {
      _cap?.cancel();
      _cap = null;
    });

    // `ref.read` throughout, like [DiscoveryFeedVariantNotifier]: a rebuild
    // would re-run `build()` and reset a latched-open gate back to closed.
    //
    // `_openReason()` returns the REASON rather than a bool, and is asked
    // exactly once per latch. Asking twice — once for "is it open", again for
    // "why" — would re-open the freshness race in miniature, since
    // `flagsFetchedThisLaunch` can flip between the two reads.
    if (!_held.isRunning) _held.start();

    final openedAtBuild = _openReason();
    if (openedAtBuild != null) {
      _waitMs = _held.elapsedMilliseconds;
      _held.stop();
      feedFlagLog('gate.open', {
        'site': 'build',
        'reason': openedAtBuild.wire,
        'waitMs': _waitMs,
      });
      _source = openedAtBuild;
      return true;
    }
    feedFlagLog('gate.closed', {'site': 'build'});

    ref.listen<ExperimentState>(experimentServiceProvider, (_, __) {
      if (state) return;
      // Only `freshFlag` or `refreshFailed` can arrive here in practice — a
      // cached `true` would have opened the gate during `build()` above — but
      // the reason still comes from the same single call, not an assumption.
      final opened = _openReason();
      if (opened == null) return;
      _waitMs = _held.elapsedMilliseconds;
      _held.stop();
      feedFlagLog('gate.open', {
        'site': 'listen',
        'reason': opened.wire,
        'waitMs': _waitMs,
      });
      _source = opened;
      state = true;
    });

    _cap ??= Timer(kDiscoveryFeedVariantGateCap, () {
      if (state) return;
      // PROD-4455 — this is now the ONLY way a session commits to the cache
      // without a real answer (short of PostHog being disabled outright), so
      // the `cap` rate is the headline health number for the whole experiment:
      // every one of these is a reader whose arm we never learned. The refresh
      // re-asks on the same 3s budget, so a run of these means the answer is
      // not arriving in 3s at all — revisit the budget, not the logic.
      debugPrint(
        '⏱️ [TIMING] discovery variant gate: cap fired after '
        '${kDiscoveryFeedVariantGateCap.inMilliseconds}ms with no fresh flag — '
        'rendering on the cached variant',
      );
      _waitMs = _held.elapsedMilliseconds;
      _held.stop();
      feedFlagLog('gate.open', {
        'site': 'cap',
        'reason': 'cap',
        'waitMs': _waitMs,
      });
      _source = FeedVariantSource.cap;
      state = true;
    });

    return false;
  }

  /// Why the gate may open now, or `null` if it may not.
  ///
  /// The branch ORDER is the contract, not an implementation detail: a cached
  /// `true` answers before freshness is looked at, so such a session reports
  /// `cached` even when the flags happen to be fresh. That is deliberate —
  /// what is being recorded is the reason the gate opened, and for these
  /// sessions it opened without waiting for anything.
  FeedVariantSource? _openReason() {
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getBool(kDiscoveryFeedVariantPrefsKey) ?? false) {
      return FeedVariantSource.cached;
    }

    final experiments = ref.read(experimentServiceProvider);
    feedFlagLog('gate.reason', {
      'loaded': experiments.loaded,
      'confirmed': experiments.flagsConfirmed,
      'fetched': experiments.flagsFetchedThisLaunch,
      'isFresh': experiments.discoveryFlagIsFresh,
      'unavailable': experiments.discoveryFlagUnavailable,
      'value': experiments.enableDiscoveryFeedV2,
      'pending': experiments.postIdentifyPending,
    });

    // PROD-4455 — a REAL answer is the only thing that opens the gate early.
    //
    // This used to open on `loaded && flagsConfirmed && flagsFetchedThisLaunch`
    // and merely LABEL the no-answer case `refresh_failed`. All three of those
    // are fail-open — they mean "stop waiting", never "we know" — so a reader
    // whose flag had not arrived yet was committed to the cached `false` within
    // milliseconds and spent the session on v1. Measured at 30% of production
    // identities, biased toward first launches.
    //
    // `discoveryFlagIsFresh` is the fail-CLOSED counterpart (PROD-4425): it is
    // set only where a server value was actually held. Waiting on it, rather
    // than on "the refresh stopped", is the whole fix.
    if (experiments.discoveryFlagIsFresh) return FeedVariantSource.freshFlag;

    // The one terminal case: PostHog cannot answer at all in this build, so
    // waiting would buy nothing and would cost every local/test launch a 3s
    // splash. Everything else — slow network, blocked SDK, flags not loaded
    // yet — keeps waiting and ends at the cap.
    if (experiments.discoveryFlagUnavailable) {
      return FeedVariantSource.refreshFailed;
    }

    return null;
  }
}

/// Whether THIS SESSION renders the server-driven feed (v2) rather than the
/// legacy Discovery page.
///
/// Fixed at creation from the best answer available then, and held for the
/// session except for a rollback — see the file header for why the asymmetry is
/// not an oversight.
final discoveryFeedVariantProvider =
    NotifierProvider<DiscoveryFeedVariantNotifier, bool>(
      DiscoveryFeedVariantNotifier.new,
    );

class DiscoveryFeedVariantNotifier extends Notifier<bool> {
  /// PROD-4425 — the last identity transition this notifier has already acted
  /// on. Seeded from the state at creation so an answer folded into `build()`
  /// is not applied a second time through the listener.
  int _decidedAtGeneration = 0;

  /// PROD-4425 — why this session is on its CURRENT variant, when that is no
  /// longer the gate's latch. Null until a mid-session re-decide; read through
  /// [feedVariantSourceProvider], which falls back to the gate.
  FeedVariantSource? _source;

  /// Why the session was last re-decided, or `null` if it never was.
  FeedVariantSource? get source => _source;

  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final cached = prefs.getBool(kDiscoveryFeedVariantPrefsKey) ?? false;

    // `ref.read`, NOT `ref.watch` — and that is the entire design.
    //
    // Watching would rebuild this notifier every time a flag resolves, and a
    // rebuild re-runs `build()`, which re-reads the cache and discards the held
    // value. The session-fixed property would silently not exist, while the
    // code still looked like it implemented it. Changes arrive through the
    // listener below, which decides whether to act on them.
    final experiments = ref.read(experimentServiceProvider);

    // PROD-4425 — whatever identity transition has already landed is spent.
    // Without this, a Discovery page mounting AFTER a post-login reload would
    // use that answer at creation (PROD-4419) and then apply it again the next
    // time any flag moved, which is a second decision on a stale trigger.
    _decidedAtGeneration = experiments.postIdentifyGeneration;

    ref.listen<ExperimentState>(
      experimentServiceProvider,
      (previous, next) => _onFlagsChanged(next),
    );

    // PROD-4008 — the sign-out rule (file header). Auth, not flags: after a
    // sign-out no flag answer is coming, so the identity transition itself is
    // the only signal there is.
    ref.listen<bool>(
      isAuthenticatedProvider,
      (previous, next) => _onAuthChanged(previous, next),
    );

    // The common case, not an edge case: `feedVariantGateProvider` holds
    // Discovery until the flag has confirmed, so by the time anything reads
    // this provider the answer is usually already in hand. The `ref.listen`
    // above has missed its chance to fire, so the decision is folded in here —
    // as part of computing the initial value, since `state` cannot be assigned
    // before `build()` returns.
    //
    // PROD-4419: **both directions**. This used to apply only the rollback
    // (`if (cached && !resolved) return false`) and otherwise fall through to
    // the cache, which is what made a newly-targeted user wait a launch. There
    // is no earlier frame to flash from at creation time — see the file header.
    final real = _isRealAnswer(experiments);
    feedFlagLog('variant.build', {
      'cached': cached,
      'loaded': experiments.loaded,
      'confirmed': experiments.flagsConfirmed,
      'value': experiments.enableDiscoveryFeedV2,
      'isFresh': experiments.discoveryFlagIsFresh,
      'gen': experiments.postIdentifyGeneration,
      'decided': real ? experiments.enableDiscoveryFeedV2 : cached,
      'from': real ? 'answer' : 'cache',
    });
    if (real) {
      _persist(experiments.enableDiscoveryFeedV2);
      return experiments.enableDiscoveryFeedV2;
    }

    // No real answer yet: the gate's cap must have fired (or something read
    // this provider without going through the gate). Fall back to the cache and
    // hold it — a late upgrade still waits for the next launch.
    return cached;
  }

  void _onFlagsChanged(ExperimentState experiments) {
    if (!_isRealAnswer(experiments)) return;

    // PROD-4425 — a post-identify reload is in flight, so these values were
    // resolved for the identity being left behind. Neither direction may act on
    // them, and they must not be cached either.
    //
    // `_isRealAnswer` cannot catch this. `reloadFlags` un-confirms at its start,
    // but the re-armed 3s watchdog fires while the reload is still running and
    // stamps `flagsConfirmed` back onto the old values, which `_loadFlags` then
    // preserves by design. The resulting state is indistinguishable from a real
    // answer — `ExperimentState.postIdentifyPending` is the only thing that
    // tells them apart.
    //
    // Concretely, without this: a guest on v2 signs in, PostHog has not yet
    // ingested the person properties so the intermediate pass reads `false`, the
    // watchdog confirms it at +3s, D49 below rolls the page back to legacy — and
    // then the real post-identify `true` lands at ~+4s and flips it back. A
    // visible double swap, two seconds apart. Reproduced before this guard
    // existed; pinned by `a pre-identify false during a login reload…` below.
    if (experiments.postIdentifyPending) {
      feedFlagLog('variant.ignored', {
        'reason': 'post_identify_pending',
        'value': experiments.enableDiscoveryFeedV2,
      });
      return;
    }

    final resolved = experiments.enableDiscoveryFeedV2;

    // Always cached, whichever direction — "takes effect next launch" is
    // implemented by this write and nothing else.
    _persist(resolved);

    // PROD-4425 — a post-identify answer is a NEW decision and applies in BOTH
    // directions, mid-session. This is the D27 reversal (file header).
    //
    // **The trigger is the generation, not the confirmation**, and the
    // difference is the whole ticket. "Any confirmed `true` applies" reads the
    // same from the outside and would silently undo D48 — every late cold-start
    // answer would start swapping the page too. Only
    // `ExperimentState.postIdentifyGeneration` marks the pass that ran *after*
    // the identify; the intermediate `_loadFlags` pass plus the re-armed 3s
    // watchdog can produce a `loaded && flagsConfirmed` state carrying
    // PRE-identify values, which is exactly the stale read this exists to
    // remove.
    //
    // The generation is consumed whether or not the value moved, so a later
    // watchdog confirm cannot re-use this identity's turn.
    if (experiments.postIdentifyGeneration > _decidedAtGeneration) {
      _decidedAtGeneration = experiments.postIdentifyGeneration;
      if (state != resolved) {
        // Only when the page actually moves: an answer that confirmed what was
        // already on screen made no decision, and the `feed_exposed` already
        // emitted described the moment it fired. Leaving the gate's reason in
        // place under-claims rather than over-claims, which is the safe
        // direction for this property.
        feedFlagLog('variant.redecide', {
          'reason': 'post_login',
          'from': state,
          'to': resolved,
          'gen': experiments.postIdentifyGeneration,
        });
        _source = FeedVariantSource.postLogin;
        state = resolved;
      }
      return;
    }

    // D48: into v2 waits for the next launch. Deliberately no `else`.
    // D49: out of v2 is immediate.
    if (state && !resolved) {
      feedFlagLog('variant.redecide', {
        'reason': 'rollback',
        'from': true,
        'to': false,
      });
      _source = FeedVariantSource.rollback;
      state = false;
    }
  }

  /// Whether [experiments] carries a value PostHog actually produced, as
  /// opposed to the constructor defaults wearing a "confirmed" label.
  ///
  /// **`flagsConfirmed` alone is not enough, and assuming it was is a bug this
  /// code shipped with** (caught in review). Two paths set `flagsConfirmed:
  /// true` while the values are still defaults:
  ///
  ///  * **The 3-second watchdog** (`ExperimentNotifier._startConfirmWatchdog`)
  ///    confirms on a timer so a cohort-gated wait can never hang the splash.
  ///    On a slow cold start that means `enableDiscoveryFeedV2: false` gets
  ///    stamped confirmed. It `copyWith`s, so `loaded` stays false.
  ///  * **`resetFlags()` on logout** sets `const ExperimentState(flagsConfirmed:
  ///    true)` — deliberately, since the defaults ARE the final answer for a
  ///    signed-out user — and deliberately leaves `loaded` false.
  ///
  /// Either one would otherwise write `false` over a cached `true` AND roll the
  /// session back to legacy on the wrong evidence: a slow PostHog would cost a
  /// user v2 for two launches, not one, and a *guest-earned* variant would be
  /// lost on sign-out. (Dropping a *signed-in-earned* variant on sign-out is
  /// correct, and [_onAuthChanged] does it deliberately, off the auth
  /// transition rather than off this default-shaped state.)
  ///
  /// `loaded` is the missing half — it means "a `_loadFlags` pass has actually
  /// read PostHog" — so requiring both excludes both paths.
  ///
  /// **Residual, accepted:** the watchdog can also fire *during* a post-login
  /// `reloadFlags()`, when `loaded` is already true from the cold-start pass but
  /// the values are pre-identify. Nothing observable from here distinguishes
  /// that state, and the failure mode is an admin bounced to legacy for one
  /// launch — the safe direction for exposure, and unreachable at all while the
  /// PostHog flag does not exist.
  bool _isRealAnswer(ExperimentState experiments) {
    return experiments.loaded && experiments.flagsConfirmed;
  }

  /// Sign-out drops a variant that a signed-in identity earned — state AND
  /// cache, so the next cold start as a guest does not render v2 for the
  /// seconds it takes PostHog to answer `false` for the anonymous id (that
  /// flash would also issue a real `/feed/home` request and stamp `v2` on
  /// events). A guest-earned variant is left alone.
  ///
  /// **Sign-in is still not handled here, and that is unchanged by PROD-4425.**
  /// The auth transition is the wrong signal for an upgrade: at that instant
  /// the flags are the *guest's*, and the whole point is to apply the answer
  /// PostHog gives the new identity. That answer arrives through
  /// [_onFlagsChanged], stamped with the generation that says it is genuinely
  /// post-identify. A sign-OUT has no such answer coming — `resetFlags()` emits
  /// defaults with `loaded: false` — so it is the only case where the identity
  /// transition itself has to be the evidence.
  void _onAuthChanged(bool? previous, bool next) {
    if (previous != true || next) return;
    final prefs = ref.read(sharedPreferencesProvider);
    final earnedSignedIn =
        prefs.getBool(kDiscoveryFeedVariantSignedInPrefsKey) ?? false;
    if (!earnedSignedIn) return;
    _persist(false, signedIn: false);
    if (state) {
      // PROD-4425 — name this decision. Without it a session that had flipped on
      // `postLogin` keeps reporting `post_login` after signing out, on a page it
      // reached by signing OUT. The dedup key hides the common case (v1 was
      // usually emitted before the login), which is exactly why it would have
      // survived review.
      feedFlagLog('variant.redecide', {
        'reason': 'sign_out',
        'from': true,
        'to': false,
      });
      _source = FeedVariantSource.signOut;
      state = false;
    }
  }

  void _persist(bool value, {bool? signedIn}) {
    // Fire-and-forget: nothing this frame depends on the write landing, and the
    // value is re-derived from PostHog on the next launch anyway, so a failed
    // write costs one stale session at worst.
    //
    // The owner tag records who this answer was for. Read from auth state
    // rather than the profile: `isAuthenticated` is true from the moment the
    // stored token is restored, while `/auth/me` can land after the flags do.
    final prefs = ref.read(sharedPreferencesProvider);
    prefs.setBool(kDiscoveryFeedVariantPrefsKey, value);
    prefs.setBool(
      kDiscoveryFeedVariantSignedInPrefsKey,
      signedIn ?? ref.read(isAuthenticatedProvider),
    );
  }
}

/// The value stamped on Discovery analytics so a before/after comparison is
/// readable (D46). Not a measured A/B split — D47 is explicit that stage 3 is a
/// confidence ramp, not an experiment.
String discoveryFeedVariantLabel(bool isV2) => isV2 ? 'v2' : 'v1';

/// Holder handed to [UnifiedAnalyticsService] so `_dispatch` can stamp the
/// variant without the service depending on Riverpod.
///
/// Mirrors `SessionUtmHolder`, which solves the identical problem for session
/// UTM params in the same file.
///
/// ⚠️ **Feed this from what RENDERED.** Since PROD-4008 that is
/// [discoveryFeedVariantProvider] itself — `DiscoveryVariantPage` renders on it
/// and nothing else. Under PROD-4007 the page on screen was
/// `feedDebugAccessProvider && feedV2EnabledProvider` (an admin gate and a
/// debug toggle), and stamping the resolved variant instead labelled a
/// dogfooding admin's v2 session `v1` — D46's before/after comparison measuring
/// the flag rather than the page, exactly the confound it exists to remove.
/// Caught in review. The rule survives the simplification: if a second input
/// to "which page" ever appears again, this must read the composite, not the
/// flag.
/// **Pull-based, not push-based** — it reads the answer when an event is
/// stamped rather than being told about changes.
///
/// `SessionUtmHolder`, the model for this class, is imperatively *set* by its
/// callers, so a plain mutable field is right there. This value is *derived*
/// from providers, and the first version copied the wrong half of the pattern:
/// a `ref.listen` pushing into a mutable field. Riverpod providers are lazy, so
/// a `Provider` nobody is watching does not recompute, the listener does not
/// fire, and the holder silently serves a stale variant. A test written for the
/// analytics fix caught it — the holder still read `v1` after the toggle had
/// moved to v2 — and the real-world version is worse than the test: several
/// emitters of `discovery_shelf_card_clicked` live on event and venue detail
/// pages, where the Discovery switcher is not mounted to keep the value warm.
///
/// Reading at stamp time removes the staleness window instead of narrowing it.
class FeedVariantHolder {
  FeedVariantHolder(this._isV2);

  final bool Function() _isV2;

  /// `'v1'` or `'v2'` — never null, so the property is always present on the
  /// events that carry it and a missing value can't be mistaken for v1.
  String get label {
    try {
      return discoveryFeedVariantLabel(_isV2());
    } catch (_) {
      // `_dispatch` must never throw: 1.1.20 shipped a regression where it did,
      // and the exception propagated out of an awaited `trackLogout()` and
      // stranded the whole sign-out flow. Reading a disposed container during
      // teardown is the only realistic path here, and `v1` is the right
      // fallback — it is what every user is on.
      return discoveryFeedVariantLabel(false);
    }
  }
}

// `feedVariantHolderProvider` lives in `feed_chrome_providers.dart`, next to
// the other page-chrome providers — see the note on [FeedVariantHolder].
