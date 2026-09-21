import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/user_list.dart';
import '../../features/lists/providers/unified_list_provider.dart';
import '../../providers/lists_provider.dart';

/// Compute the set of `unifiedListProvider` family keys (both UUID and slug)
/// that should be refreshed after a long-running ingest job produced entities.
///
/// **Background — slug/id family-key gotcha (PROD-1755):** `unifiedListProvider`
/// is a `.family` keyed by whatever string the consumer passes. Every list-
/// detail navigation uses `urlIdentifier = slug ?? id`, so the screen instance
/// is cached under the SLUG when one exists. Background refresh paths that
/// only fire under the UUID leave the slug-keyed cache stale and the user
/// sees old items on re-entry. Fan-out **MUST** hit both keys for every
/// affected list.
///
/// This helper centralizes that logic so each ingest flow (IG-share,
/// contributions, future imports) doesn't re-invent it.
///
/// [shouldInclude] picks which lists to fan out to — feature-specific (IG
/// uses `isFromInstagramShare`, contributions uses `isUserContributions`).
/// [targetListId] is the optional explicit write target from the job
/// (matched against `id` OR `slug` of any provided list) and is always
/// included in the result; if it doesn't match a known list, the bare key
/// is still emitted so a still-loading detail screen can warm itself.
Set<String> computeAffectedListKeys(
  Iterable<UserList> lists, {
  String? targetListId,
  required bool Function(UserList list) shouldInclude,
}) {
  final keys = <String>{};

  for (final list in lists) {
    final matchesTarget =
        targetListId != null &&
        (list.id == targetListId || list.slug == targetListId);
    if (!shouldInclude(list) && !matchesTarget) continue;
    keys.add(list.id);
    final slug = list.slug;
    if (slug != null && slug.isNotEmpty) {
      keys.add(slug);
    }
  }

  // Target id passed by the caller but not present in the current lists
  // snapshot: still emit it so the detail screen (which has likely already
  // bound a provider under this key) can refresh itself.
  if (targetListId != null && !keys.contains(targetListId)) {
    keys.add(targetListId);
  }

  return keys;
}

/// Refresh the lists hub + the per-list items of every list affected by an
/// ingest job's terminal outcome.
///
/// Two surfaces:
///   1. `listsProvider.notifier.loadLists()` — list metadata (cover, item
///      count) used by the hub's list cards.
///   2. `unifiedListProvider(key).notifier.loadItemsQuietly()` — per-list
///      items held by each open list-detail screen. Without this, the user
///      sees the new cover on the hub but the detail still shows stale
///      items until they navigate away or pull-to-refresh.
///
/// See [computeAffectedListKeys] for the slug/id family-key gotcha.
Future<void> refreshAffectedLists(
  Ref ref, {
  String? targetListId,
  required bool Function(UserList list) shouldInclude,
}) async {
  await ref.read(listsProvider.notifier).loadLists();
  final keys = computeAffectedListKeys(
    ref.read(listsProvider).lists,
    targetListId: targetListId,
    shouldInclude: shouldInclude,
  );
  for (final key in keys) {
    // ignore: discarded_futures
    ref.read(unifiedListProvider(key).notifier).loadItemsQuietly();
  }
}
