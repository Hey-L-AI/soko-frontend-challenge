import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// PROD-3319 — `?share=<action>` deep-link param on the public detail
/// routes (`/lists/:id`, `/venues/:id`, `/events/:id` and the two in-list
/// variants). When present, the mounted screen auto-presents the existing
/// share sheet for its subject once it loads — the last-mile entry point
/// for the share-nudge push notifications (PROD-3035).
///
/// `share=sheet` (the only recognised value today) opens the generic
/// channel-picker sheet. The enum leaves room for future channel-specific
/// actions (e.g. `share=whatsapp` auto-firing that channel) without a
/// second param.
enum ShareDeepLinkAction {
  sheet;

  /// The wire value, used to re-stamp the marker on internal redirects
  /// (e.g. the in-list § 7.7 not-found fallback to the standalone route).
  String get queryValue => switch (this) {
    ShareDeepLinkAction.sheet => 'sheet',
  };
}

/// Action-agnostic parse of the `?share=` param. Unknown or absent
/// values → null → the page renders plainly (never an error).
ShareDeepLinkAction? parseShareDeepLink(String? raw) => switch (raw) {
  'sheet' => ShareDeepLinkAction.sheet,
  _ => null,
};

/// `entry_point` value for `share_intent_fired` when the sheet was
/// auto-presented by a `?share=` deep link — distinguishes the push→share
/// funnel from manual `share_sheet` / `direct_button` opens.
const String shareDeepLinkEntryPoint = 'deep_link';

/// One-shot auto-present of the share sheet for a `?share=` deep link.
///
/// Mix into the `ConsumerState` of a detail screen and call
/// [maybeAutoPresentShare] from `build()` on every frame with:
///   - [ready]: whether the subject has loaded (the `present` closure can
///     build the same shareUrl the manual share button would);
///   - [present]: the screen's existing share call (read fresh state via
///     `ref.read` inside — don't capture a snapshot at build time).
///
/// Fire-once semantics mirror the daily-drop marker (PROD-2565,
/// `discovery_screen.dart`): the marker is stripped from the URL right
/// before presenting, so back-nav / refresh land on a clean URL and never
/// re-fire, while a warm re-tap of the same push link delivers the param
/// again and does. Stripping re-arms the latch (the pageBuilder reruns
/// with a null param), so no nonce counter is needed here.
///
/// Native cold start: `app.dart` re-issues the launch link post-frame
/// (idempotent re-`go()`); that runs same-startup-frame while the strip
/// waits on the subject's network round trip, so it cannot re-add the
/// marker after the strip.
mixin ShareDeepLinkAutoPresent<W extends StatefulWidget> on State<W> {
  bool _handledShareDeepLink = false;

  /// Implementers return the widget's `autoShareAction` ctor param
  /// (threaded from the route's `?share=` query by `app_router.dart`).
  ShareDeepLinkAction? get autoShareAction;

  /// Call from `build()` every frame. No-op unless a recognised action
  /// is pending, unhandled, and [ready] is true.
  void maybeAutoPresentShare({
    required bool ready,
    required VoidCallback present,
  }) {
    if (autoShareAction == null) {
      // Param stripped (or never present) → re-arm for a future warm
      // re-tap of the same push link.
      _handledShareDeepLink = false;
      return;
    }
    if (_handledShareDeepLink || !ready) return;
    _handledShareDeepLink = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _stripShareMarker();
      present();
    });
  }

  /// Remove the `share` marker from the URL (keeping `ref`, `utm_*`,
  /// `from`/`dropId`, `view`, …) via an in-place `context.replace` — same
  /// route + same pageKey, so the page updates under the already-open
  /// modal without a remount.
  void _stripShareMarker() {
    final state = GoRouterState.of(context);
    // Web cold start: GoRouter already stripped the query from its own
    // location (the param was read via the `Uri.base` fallback in
    // app_router.dart) and re-synced the URL bar to path-only — nothing
    // to replace. The guard avoids a redundant same-location replace.
    if (!state.uri.queryParameters.containsKey('share')) return;
    final params = Map<String, String>.from(state.uri.queryParameters)
      ..remove('share');
    context.replace(
      Uri(
        path: state.uri.path,
        queryParameters: params.isEmpty ? null : params,
      ).toString(),
      extra: state.extra,
    );
  }
}
