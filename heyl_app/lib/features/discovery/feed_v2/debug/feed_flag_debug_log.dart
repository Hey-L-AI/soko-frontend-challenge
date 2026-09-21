// PROD-4433 — **TEMPORARY** instrumentation for the `discovery-feed-v2` flag
// path. Delete this file and its call sites when that ticket closes.
//
// **Why this exists.** Three staging sessions on 2026-09-15 emitted
// `feed_exposed` rows that cannot all be true at once: the reader was assigned
// `discovery-feed-v2: true`, the app rendered **v1**, and `variant_source` said
// `fresh_flag` — "we knew". The decision is made once, early, from several
// async inputs that resolve in a non-deterministic order, so the row tells you
// the outcome and nothing about how it was reached.
//
// It cannot be reproduced locally: PostHog returns **no flags at all** to a
// `localhost` origin (an in-page `fetch` to `/flags/?v=2` answers
// `{"flags":{}}` while an identical server-side call with the same `api_key`
// and `distinct_id` returns the full set), so every flag reads as its default
// and the race is invisible. See
// `docs/learnings/posthog-blocked-browser-fakes-flag-off.md`. Staging is the
// only place the question can be asked, which is what this file is for.
//
// ## It must never run in production
//
// `kDebugMode` is the instinctive gate and it is **wrong here**: staging is a
// RELEASE build (`render-build.sh` builds both Render services the same way),
// so `kDebugMode` is false on staging — the one environment we need. The
// discriminator is [EnvironmentConfig.analyticsEnvironment], which already
// exists precisely because `ENV=prod` cannot tell staging from production.
//
// [feedFlagDebugEnabledFor] is an **allow-list**, mirroring `klaviyoEnabledFor`
// and `sessionReplayEnabled`: an unrecognised environment logs **nothing**. A
// deny-list (`!= 'prod'`) would fail the wrong way — a new or misspelled
// environment string would start logging in front of real users.

import 'package:flutter/foundation.dart';

import '../../../../core/config/environment.dart';

/// The prefix every line carries, so a staging session can be filtered with a
/// single `grep FEEDFLAG` (or a console filter) and the whole investigation
/// removed with one search.
const String kFeedFlagLogPrefix = 'FEEDFLAG';

/// Whether the temporary flag-path logging may emit, for a given environment.
///
/// Pure so the **production** branch is reachable from a test:
/// [EnvironmentConfig.analyticsEnvironment] collapses to `'dev'` under
/// `kDebugMode`, and `flutter test` always runs in debug — so a test asserting
/// on the live getter could never prove the prod case. Same reason
/// `klaviyoEnabledFor` exists.
///
/// Allow-list, not a deny-list: anything unrecognised is silent.
bool feedFlagDebugEnabledFor({required String environment}) =>
    environment == 'staging' || environment == 'dev';

/// Whether the temporary flag-path logging is active in THIS build.
bool get feedFlagDebugEnabled => feedFlagDebugEnabledFor(
  environment: EnvironmentConfig.analyticsEnvironment,
);

/// Milliseconds since the first log line, so the ORDER and the GAPS between
/// async resolutions are readable.
///
/// The elapsed number is the point of this instrumentation, not decoration:
/// every hypothesis about this bug is about which of `_loadFlags`,
/// `_refreshDiscoveryFlag`, the 2.5s gate cap and the 3s confirm watchdog won a
/// race. A log without timings records the outcome we already have from
/// `feed_exposed` and adds nothing.
final Stopwatch _since = Stopwatch();

/// Emits one line of flag-path diagnostics — on staging and dev only.
///
/// [step] is a short stable token (`refresh.read`, `gate.open`, `variant.build`)
/// so lines can be grouped; [data] is appended as `key=value` pairs.
void feedFlagLog(String step, [Map<String, Object?> data = const {}]) {
  if (!feedFlagDebugEnabled) return;
  if (!_since.isRunning) _since.start();
  final pairs = data.entries.map((e) => '${e.key}=${e.value}').join(' ');
  debugPrint(
    '[$kFeedFlagLogPrefix +${_since.elapsedMilliseconds}ms] $step'
    '${pairs.isEmpty ? '' : ' $pairs'}',
  );
}

/// Resets the elapsed clock. Test-only; production code never calls it.
@visibleForTesting
void resetFeedFlagLogClock() => _since
  ..stop()
  ..reset();
