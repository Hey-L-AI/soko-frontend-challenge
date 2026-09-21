import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'unified_list_provider.dart';

/// Refresh a single list-detail surface. Calls the family notifier's
/// `refresh()` so optimistic items + pagination state stay coherent.
Future<void> refreshListDetail(WidgetRef ref, String listId) async {
  await _holdSpinner([
    ref.read(unifiedListProvider(listId).notifier).refresh(),
  ]);
}

/// Hold the pull-to-refresh future until [tasks] resolve (errors swallowed
/// — surfaces render their own error state), with a min visible time and
/// a hard ceiling. Mirror of `_holdSpinner` in
/// `features/discovery/providers/discovery_feed_refresh.dart`.
Future<void> _holdSpinner(List<Future<Object?>> tasks) async {
  Future<void> swallow(Future<Object?> f) =>
      f.then<void>((_) {}, onError: (_) {});
  await Future.wait<void>([
    Future<void>.delayed(const Duration(milliseconds: 600)),
    Future.wait<void>(
      tasks.map(swallow),
    ).timeout(const Duration(seconds: 4), onTimeout: () => const <void>[]),
  ]);
}
