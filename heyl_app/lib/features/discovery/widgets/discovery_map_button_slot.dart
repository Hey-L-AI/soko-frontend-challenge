import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/models/user_profile.dart' show UserRole;
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../feature_spotlight/providers/feature_spotlight_service.dart';
import '../../feature_spotlight/widgets/spotlight_trigger.dart';
import '../../map/widgets/map_open_transition.dart';
import 'discovery_map_button.dart';

/// The floating `Mapa` entry point, positioned bottom-centre over a feed page,
/// with its once-only coachmark attached.
///
/// **Extracted so the two feed pages cannot drift** (PROD-4005 / the v2 feed).
/// `DiscoveryMapButton` was already presentation-only; everything *around* it —
/// where it sits, the `map_page_v1` spotlight, the spotlight's admin ordering
/// gate, and the `/map` navigation — lived inline in `discovery_screen.dart`.
/// Mounting the button on the v2 feed by copying that block would have made
/// "the same button" mean "two blocks that happen to match today". This widget
/// is the whole entry point, so both pages mount one thing.
///
/// **Must be a direct child of a page-filling `Stack`** — it returns a
/// [Positioned]. It must also sit inside a `FeedScrollControllerScope` (for the
/// collapse-on-scroll animation) and a `ShowCaseWidget` ancestor (for the
/// spotlight); `DiscoveryShell` supplies the latter via `ProductTourHost`.
class DiscoveryMapButtonSlot extends ConsumerWidget {
  const DiscoveryMapButtonSlot({super.key});

  /// Distance from the bottom of the page to the button. Both feeds sit inside
  /// the same shell body box, so this is the same 16 px on either.
  static const double bottomInset = 16;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);

    return Positioned(
      left: 0,
      right: 0,
      bottom: bottomInset,
      child: Center(
        // PROD-3133: teach existing (already-onboarded) users about the
        // Map now that its entry button is open to everyone. Once-only,
        // signed-in-only coachmark; CTA opens the Map (same as a tap).
        child: SpotlightTrigger(
          featureId: 'map_page_v1',
          // Keep the two home spotlights sequential: for users who have
          // the Profile nav slot (admin pilot), hold the Map coachmark
          // until profile_v1 has been seen. Non-pilot users (no profile
          // slot) are unaffected — the Map fires as before.
          gate: () =>
              ref.read(currentUserProvider)?.role != UserRole.admin ||
              ref
                  .read(featureSpotlightServiceProvider)
                  .suppressed
                  .contains('profile_v1'),
          // PROD-3524 — `go`, not `push`. The imperative push never
          // updated the URL, so `/map` owned no browser-history entry
          // and browser back bypassed the map's `PopScope`. `/map` is
          // now a child route of `/`, which keeps the feed page mounted
          // beneath the map and `canPop()` true — same stack the push
          // produced, but with a real URL behind it.
          //
          // String literal (not `AppRoutes.mapa`) because importing
          // app_router here would cycle: it imports both feed pages. The
          // value is pinned by the router test.
          onCtaAction: () => context.go('/map'),
          // Shared-element anchor: the pill morphs into the full-screen map on
          // open (see [mapOpenFlightShuttleBuilder]). Wraps the button directly
          // so the Hero captures the pill/circle's real rect.
          child: Hero(
            tag: kMapOpenHeroTag,
            flightShuttleBuilder: mapOpenFlightShuttleBuilder,
            child: DiscoveryMapButton(
              label: l10n.discoveryNavMapa,
              onTap: () => context.go('/map'),
            ),
          ),
        ),
      ),
    );
  }
}
