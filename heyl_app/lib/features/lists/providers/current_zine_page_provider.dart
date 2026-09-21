import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';

/// The item currently foregrounded in a zine's page pager, keyed by the
/// list id (slug or UUID — whatever the route gave). `null` means the
/// **cover** page (page 0) is showing, or the pager isn't mounted.
///
/// Bridges the pager state (owned by `_ListZineViewState`) up to the
/// separately-built [ListPageHeader] sliver, which sits above the pager and
/// otherwise has no way to know which page is on screen. The header uses it
/// to decide whether the contextual reminder **bell** should show (non-owner
/// event pages only) and which event it targets. The pager writes it on each
/// page settle; reset to `null` on the cover.
final currentZinePageItemProvider = StateProvider.autoDispose
    .family<UserListItem?, String>((ref, listId) => null);

/// PROD-4XXX — the entity id (event/venue) currently foregrounded on the
/// **in-list detail** page for a given list. When the user swipes between
/// sibling items on the detail (`SiblingSwipeNav` → `context.replace`), the
/// underlying zine pager listens to this and jumps its page to match, so
/// pressing back lands the zine on the item they were just viewing.
///
/// Keyed by list id (slug or UUID — same key the zine + detail share).
/// `null` = nothing to sync. Separate from [currentZinePageItemProvider]
/// (which flows pager → header) to avoid a feedback loop.
final zineDetailSyncTargetProvider = StateProvider.autoDispose
    .family<String?, String>((ref, listId) => null);
