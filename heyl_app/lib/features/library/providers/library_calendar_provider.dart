import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/lists_provider.dart';
import '../../lists/providers/lists_hub_items_provider.dart'
    show calendarEventToSyntheticItem;

/// Whether `/library` is showing the calendar body instead of the feed.
///
/// Flipped by the header's calendar button. Per-visit like the search flag:
/// the screen resets it on mount so a parked calendar never outlives the
/// visit that opened it.
final libraryCalendarOpenProvider = StateProvider<bool>((_) => false);

/// How far the whole-library calendar window reaches around today. The
/// calendar-events endpoint requires a date window; the library calendar
/// deliberately fetches one wide window instead of refetching per visible
/// month, so month navigation inside [ListCalendarView] stays client-side.
const int kLibraryCalendarPastMonths = 12;
const int kLibraryCalendarFutureMonths = 24;

/// Every saved event in the caller's library — owned lists (including
/// collaborative ones) plus followed lists — as synthetic [UserListItem]s
/// ready for `ListCalendarView`, same adapter the `/lists` hub used.
///
/// The endpoint has no `scope=all`, so the two scopes are fetched in
/// parallel and merged. The same underlying event saved in both an owned
/// and a followed list is deduped by entity here; the calendar view would
/// dedupe its chips anyway (PROD-1975), but dropping duplicates early also
/// keeps the agenda's "no date" section honest.
///
/// **Parked like the library feed, not refetched per open.** Keep-alive, so
/// closing the calendar keeps the merged set in memory; reopening renders it
/// instantly while the header toggle invalidates this provider for a silent
/// revalidate behind the stale render (`AsyncValue.when`'s default
/// `skipLoadingOnRefresh` keeps the data branch painted during the refetch).
/// Registered in [userScopedProviders] so an account switch drops it.
final libraryCalendarItemsProvider = FutureProvider<List<UserListItem>>((
  ref,
) async {
  final listsApi = ref.read(listsApiProvider);
  final now = DateTime.now();
  final fromDate = DateTime(
    now.year,
    now.month - kLibraryCalendarPastMonths,
    1,
  );
  final toDate = DateTime(
    now.year,
    now.month + kLibraryCalendarFutureMonths,
    1,
  );

  final results = await Future.wait([
    listsApi.getListsCalendarEvents(
      fromDate: fromDate,
      toDate: toDate,
      includeCollaborative: true,
    ),
    listsApi.getListsCalendarEvents(
      fromDate: fromDate,
      toDate: toDate,
      scope: 'following',
    ),
  ]);

  // Same read-after-write defense as the hub provider: a just-deleted or
  // just-unfollowed list may still echo in the BE response briefly.
  final tombstones = ref.watch(
    listsProvider.select(
      (s) => <String>{
        ...s.recentlyDeletedListIds,
        ...s.recentlyUnfollowedListIds,
      },
    ),
  );

  final seenEntities = <String>{};
  final items = <UserListItem>[];
  for (final response in results) {
    for (final e in response.items) {
      if (tombstones.contains(e.listId)) continue;
      final item = calendarEventToSyntheticItem(e);
      final key = item.entityKey ?? item.id;
      if (seenEntities.add(key)) items.add(item);
    }
  }
  return items;
});
