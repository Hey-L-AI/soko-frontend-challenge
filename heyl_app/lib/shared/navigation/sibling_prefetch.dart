import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/event_detail/providers/event_detail_provider.dart';
import '../../features/venue_detail/providers/venue_detail_provider.dart';
import 'detail_siblings.dart';

/// Invisible widget that pre-fetches the **next** and **previous**
/// sibling detail snapshots so horizontal-swipe navigation doesn't
/// flash a loading state.
///
/// Both `eventDetailProvider` and `venueDetailProvider` are
/// `FutureProvider.autoDispose`, so once the user lands on a sibling
/// the corresponding cache is kept alive by the detail screen's own
/// `ref.watch`. This widget seeds those caches ahead of time while the
/// user is on the current detail.
///
/// Renders nothing — sized-zero. Returns [SizedBox.shrink] when
/// [siblings] is null or has no prev/next.
class SiblingPrefetch extends ConsumerWidget {
  final DetailSiblings? siblings;

  const SiblingPrefetch({super.key, required this.siblings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = siblings;
    if (s == null) return const SizedBox.shrink();

    if (s.hasNext) _watch(ref, s.next!, s.listId);
    if (s.hasPrev) _watch(ref, s.prev!, s.listId);

    return const SizedBox.shrink();
  }

  void _watch(WidgetRef ref, DetailSibling sibling, String? listId) {
    if (sibling.type == DetailSiblingType.event) {
      ref.watch(
        eventDetailProvider(
          EventDetailKey(eventId: sibling.id, listId: listId),
        ),
      );
    } else {
      ref.watch(
        venueDetailProvider(
          VenueDetailKey(venueId: sibling.id, listId: listId),
        ),
      );
    }
  }
}
