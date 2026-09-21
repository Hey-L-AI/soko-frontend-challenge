import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../data/models/models.dart';
import '../../../providers/providers.dart';
import '../../../shared/widgets/mapbox_map_widget.dart' show kZineMapHeight;
import 'guest_blurred_map.dart';
import 'list_map_view.dart';

/// PROD-1979 — shared cover-map block used by both the zine cover and
/// the list view body. Owns the guest-gate wiring so the two view
/// modes can never drift apart again: for guests the underlying
/// [ListMapView] is wrapped in a [GuestBlurredMap] with the standard
/// `AuthReferrer.guestListBlurCta` sign-in flow; for authenticated
/// users the map is fully interactive.
///
/// Height comes from [kZineMapHeight] (PROD-2205-followup) so the
/// cover map, list-view body map, and zine item-page map all share
/// the same canvas size.
///
/// [onItemTap] is forwarded only on the authenticated branch. The zine
/// cover uses it to jump the `TurnPageController` to the tapped pin's
/// item page; the list view body passes `null` (map is read-only there).
class ListPageMapBlock extends ConsumerWidget {
  final List<UserListItem> items;
  final ValueChanged<UserListItem>? onItemTap;

  const ListPageMapBlock({super.key, required this.items, this.onItemTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isGuest = !ref.watch(isAuthenticatedProvider);
    return SizedBox(
      height: kZineMapHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: isGuest
            ? GuestBlurredMap(
                child: ListMapView(items: items),
                onSignIn: () => navigateToLoginPreservingReturn(
                  context,
                  ref,
                  referrer: AuthReferrer.guestListBlurCta,
                ),
              )
            : ListMapView(items: items, onItemTap: onItemTap),
      ),
    );
  }
}
