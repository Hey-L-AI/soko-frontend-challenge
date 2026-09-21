// PROD-4005 — the one place the search-location picker is opened from.
//
// Extracted verbatim from `ActionBarLocationPill._openPicker` so the Discovery
// feed's two headers (D31 top header, D32 pinned header) open **the same**
// picker with the same semantics, rather than a second copy that drifts.
//
// The subtlety worth preserving is all in the normalization: the picker opens
// on the same tier the label shows (PROD-3307), a pick that lands back on the
// auto-detected scope persists `null` rather than freezing an override
// (so C keeps following U), and the commit goes through
// `commitSearchCenterChange` so the active chat's search center moves with it.
// Duplicating any of that would be a silent behaviour fork between two
// surfaces the design says are the same control.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/lists/widgets/location_scope_picker_sheet.dart';
import '../../providers/city_auto_scope_provider.dart';
import '../../providers/city_scope_provider.dart';
import '../../providers/resolved_search_location_provider.dart';
import '../../providers/search_center_commit.dart';
import '../../providers/session_provider.dart';
import '../notifications/heyl_notification.dart';
import '../notifications/notification_state.dart';

Future<void> openSearchLocationPicker(
  BuildContext context,
  WidgetRef ref,
) async {
  // PROD-3188: every picker open applies the single C-vs-U TTL rule before
  // choosing its initial camera. A stale explicit scope must not win just
  // because it survived in SharedPreferences from a previous session.
  final override = await ref
      .read(cityScopeProvider.notifier)
      .openSearchCenter();
  if (!context.mounted) return;
  // PROD-3307: mirror the pill label's resolution order so the picker opens
  // on the SAME place the pill shows. [resolvedSearchLocationProvider] (the
  // label source) resolves `explicit ?? autoFollowUser ?? autoCityCascade`;
  // opening the picker with `override ?? autoScope` skipped the follow-user
  // neighbourhood tier, so the pill said "Alta de Lisboa" while the map
  // opened on the coarser IP/profile city (Marquês). Fetch the follow-user
  // area and slot it in between.
  final autoFollow = await ref.read(autoFollowUserScopeProvider.future);
  if (!context.mounted) return;
  // Resolve the auto-detected scope so a confirmed pick that lands back on it
  // normalizes to "no override" (the isAutoPick check below).
  final autoScope = await ref.read(cityAutoScopeProvider.future);
  if (!context.mounted) return;
  final picked = await showLocationScopePicker(
    context,
    ref,
    currentScope: override ?? autoFollow ?? autoScope,
  );
  if (picked == null) return;
  // If the user landed back on the auto-detected scope (via the reset
  // button or an exact match), persist null so we don't store a
  // redundant override — auto-detect takes over. Both auto tiers count:
  // the follow-user neighbourhood (now the picker's default when there's no
  // override) and the IP/profile city cascade. Confirming either unchanged
  // must keep C following U, not freeze it into an explicit pick.
  final isAutoPick =
      picked == autoFollow || (autoScope != null && picked == autoScope);
  final normalized = isAutoPick ? null : picked;
  if (normalized == null) {
    await ref.read(cityScopeProvider.notifier).set(null);
    return;
  }

  try {
    final candidate = await ref.read(
      resolvedSearchScopeProvider((scope: normalized, isExplicit: true)).future,
    );
    await commitSearchCenterChange(
      persistActiveChat: () async {
        await ref
            .read(sessionsProvider.notifier)
            .persistActiveChatSearchCenter(candidate);
      },
      publishGlobal: () => ref.read(cityScopeProvider.notifier).set(normalized),
    );
  } catch (error) {
    if (!context.mounted) return;
    showSoko(
      ref,
      message: 'Could not update this chat’s search area. Please try again.',
      variant: SokoVariant.error,
    );
    return;
  }
}
