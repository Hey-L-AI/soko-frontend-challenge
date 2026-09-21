import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'short_link_resolver.dart';

/// Loop-proofing for the short-link browser fallback (`app.dart`
/// `_resolveAndHandleShortLink`).
///
/// Background: the app claims `l.soko.fyi` / `l.heyl.ai` / `t.heyl.ai` /
/// `r.soko.fyi` as verified App Links. When a tapped short link fails to
/// resolve, the fallback used to `launchUrl(shortUri, inAppBrowserView)`.
/// On Android that is `CustomTabsIntent.launchUrl` with NO target package,
/// i.e. a plain `ACTION_VIEW` on a host we own — so the system hands the
/// intent straight back to this app, `uriLinkStream` re-emits the same short
/// URL, resolution fails again, and the app bounces against itself at 3–8
/// iterations a second for as long as the link keeps failing (2,570 events
/// from one OPPO in 6.5 h on 2026-08-18; 1,107 from a Xiaomi in 6 min on
/// 2026-08-10). iOS never loops. Two layers close it:
///
/// 1. [ShortLinkRelaunchGuard] — a short URL that failed within [window]
///    is not resolved or launched again. Breaks any loop deterministically.
/// 2. [shortLinkFallbackTarget] + `LaunchMode.inAppWebView` in `app.dart` —
///    the fallback never issues an `ACTION_VIEW` on a domain we claim.
class ShortLinkRelaunchGuard {
  ShortLinkRelaunchGuard({
    this.window = const Duration(seconds: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How long after a failure the same short URL is treated as "in a loop".
  /// The loop cadence in production was 0.1–2 s; a human re-tap after an
  /// error is slower than that in practice, and a swallowed re-tap costs one
  /// browser fallback, whereas a missed loop costs thousands of events.
  final Duration window;

  final DateTime Function() _now;
  final Map<String, DateTime> _lastFailure = <String, DateTime>{};

  /// True when [shortUri] failed less than [window] ago. Callers must then
  /// skip both resolution and the browser fallback — relaunching is the loop.
  bool shouldSuppress(Uri shortUri) {
    _prune();
    final at = _lastFailure[_key(shortUri)];
    return at != null && _now().difference(at) < window;
  }

  /// Record that [shortUri] just failed (resolution error or unroutable).
  void recordFailure(Uri shortUri) {
    _lastFailure[_key(shortUri)] = _now();
  }

  /// Scheme and host are case-insensitive per RFC 3986; path and query are
  /// not, and two different slugs on the same host are two different links.
  static String _key(Uri u) =>
      '${u.scheme.toLowerCase()}://${u.host.toLowerCase()}${u.path}'
      '${u.hasQuery ? '?${u.query}' : ''}';

  void _prune() {
    final now = _now();
    _lastFailure.removeWhere((_, at) => now.difference(at) >= window);
  }
}

/// Where the browser fallback should go. Prefer the resolved URL when the
/// chain did resolve (it is further along than the short link, and for an
/// unroutable target it IS the page the user wanted); otherwise the short
/// URL itself, which the in-app WebView will follow redirect by redirect.
Uri shortLinkFallbackTarget({required Uri shortUri, required Uri? resolved}) =>
    resolved ?? shortUri;

/// Orchestrates the failure side of a short-link tap so the loop-breaking
/// contract is testable without a widget tree: [suppressIfLooping] runs
/// BEFORE any network resolution, [handleFailure] is the only place that
/// launches anything, and it always launches with [LaunchMode.inAppWebView].
class ShortLinkFallbackCoordinator {
  ShortLinkFallbackCoordinator({
    required this.trackFailed,
    ShortLinkRelaunchGuard? guard,
    Future<bool> Function(Uri uri, LaunchMode mode)? launch,
  }) : guard = guard ?? ShortLinkRelaunchGuard(),
       _launch = launch ?? ((uri, mode) => launchUrl(uri, mode: mode));

  final ShortLinkRelaunchGuard guard;
  final Future<bool> Function(Uri uri, LaunchMode mode) _launch;

  /// Emits `deep_link.short_link_resolve_failed` with the given `error_kind`.
  final void Function(Uri shortUri, String errorKind) trackFailed;

  /// Layer 1. Call before resolving. Returns true when [shortUri] failed
  /// within the guard window — the caller must stop: no resolution (one
  /// network round-trip per loop iteration), no launch (the relaunch IS the
  /// loop). The failure is still recorded in analytics under its own kind so
  /// a live loop remains countable.
  ///
  /// A suppressed delivery re-arms the window: a re-delivery inside the
  /// window is by definition the loop, so as long as they keep coming the
  /// link stays suppressed — otherwise a persistent loop would relaunch once
  /// per window (12×/min) instead of never.
  bool suppressIfLooping(Uri shortUri) {
    if (!guard.shouldSuppress(shortUri)) return false;
    guard.recordFailure(shortUri);
    trackFailed(shortUri, ShortLinkFailureKind.relaunchSuppressed);
    return true;
  }

  /// Layer 2. Resolution failed ([resolved] null) or resolved to something
  /// the app cannot route. Records the failure, then opens the best target
  /// in the plugin's in-app WebView — never an ACTION_VIEW on a host this
  /// app claims as an App Link, which is what Android hands straight back.
  Future<void> handleFailure({
    required Uri shortUri,
    required Uri? resolved,
    required String errorKind,
  }) async {
    trackFailed(shortUri, errorKind);
    guard.recordFailure(shortUri);
    try {
      await _launch(
        shortLinkFallbackTarget(shortUri: shortUri, resolved: resolved),
        LaunchMode.inAppWebView,
      );
    } catch (e) {
      debugPrint('[SokoApp] short-link browser fallback failed: $e');
    }
  }
}
