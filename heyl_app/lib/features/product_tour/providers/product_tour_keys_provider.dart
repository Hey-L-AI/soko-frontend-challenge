import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProductTourKeys {
  ProductTourKeys()
    : searchBar = GlobalKey(debugLabel: 'tour_searchBar'),
      createButton = GlobalKey(debugLabel: 'tour_createButton'),
      createSheet = GlobalKey(debugLabel: 'tour_createSheet'),
      yoursNav = GlobalKey(debugLabel: 'tour_yoursNav'),
      profileMenu = GlobalKey(debugLabel: 'tour_profileMenu'),
      discoverCity = GlobalKey(debugLabel: 'tour_discoverCity'),
      discoverCityPage = GlobalKey(debugLabel: 'tour_discoverCityPage'),
      searchOverlayClose = GlobalKey(debugLabel: 'tour_searchOverlayClose'),
      discoverTabZines = GlobalKey(debugLabel: 'tour_discoverTabZines'),
      discoverTabEventos = GlobalKey(debugLabel: 'tour_discoverTabEventos'),
      discoverTabSitios = GlobalKey(debugLabel: 'tour_discoverTabSitios');

  final GlobalKey searchBar;
  final GlobalKey createButton;
  final GlobalKey createSheet;

  /// The Biblioteca nav cell — step 4's click target and tooltip anchor.
  /// Named `yoursNav` only because `TourStep.yoursNav.analyticsName` must
  /// stay `'yours'`; the step lands on `/library` (PROD-4167).
  final GlobalKey yoursNav;
  final GlobalKey profileMenu;

  /// Attached to the "Descobre a cidade" search pill in the discovery
  /// action bar. Cursor click target for step 2 → step 3 transition.
  final GlobalKey discoverCity;

  /// Attached to the search-overlay panel that opens when "Descobre
  /// a cidade" is tapped. Primary spotlight target for step 3 (the
  /// new "discoverCity" step).
  final GlobalKey discoverCityPage;

  /// Attached to the X close-button inside the search overlay. Cursor
  /// click target for step 3 → step 4 transition (cursor clicks X
  /// to close the overlay, then continues to the Create-+ button).
  final GlobalKey searchOverlayClose;

  /// Attached to the Zines / Eventos / Sítios pills inside the
  /// search overlay's category tabs. Drive the looping demo cursor
  /// (`_TourDescobreTabsCursor`) that cycles through the three tabs
  /// while the user reads the Descobre tooltip card — showing what
  /// the tabs do without the user having to tap.
  final GlobalKey discoverTabZines;
  final GlobalKey discoverTabEventos;
  final GlobalKey discoverTabSitios;
}

/// In production this provider is overridden per `DiscoveryShell` mount
/// via `ProviderScope.overrideWith` (see `_DiscoveryShellState._tourKeys`)
/// so every shell mount serves a fresh `ProductTourKeys`. The fallback
/// `ProductTourKeys()` here only runs in tests or in places that read
/// the provider outside the shell subtree.
///
/// **Misdiagnosis history.** Several rounds of fixes (PROD-2438,
/// 2026-06-07) targeted this provider on the theory that the post-
/// profiling `Explorar o app` → `/` assertion was a `ProductTourKeys`
/// `GlobalKey` collision. It was not. The colliding key was
/// `GlobalObjectKey(navigatorKey.hashCode)` from go_router's
/// `_CustomNavigator` (`go_router-14.8.1/lib/src/builder.dart:287`),
/// reparented across an unmount→remount of `DiscoveryShell` that
/// `ShellSliverScope` couldn't acknowledge. The real fix lives in the
/// profiling screens: they switched from `context.go` to
/// `context.pushReplacement` so the shell never unmounts during the
/// flow. See
/// `docs/learnings/go-router-shell-navigator-globalobjectkey-collision.md`.
///
/// The override is still here because it cheaply guarantees fresh
/// `GlobalKey` lifetime per shell mount in widget tests (no Riverpod
/// autoDispose timing dependency), but it is NOT load-bearing for any
/// known on-device crash.
final productTourKeysProvider = Provider<ProductTourKeys>((ref) {
  return ProductTourKeys();
});
