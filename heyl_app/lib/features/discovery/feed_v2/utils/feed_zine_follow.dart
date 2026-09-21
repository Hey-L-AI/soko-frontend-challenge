// PROD-4118 — following a zine from a feed bundle row.
//
// The sibling of `feed_item_save.dart`, and deliberately shaped like it: a
// derived `Provider<Set<String>>` for the state plus one function for the
// action, so a page holding ten of these buttons rebuilds narrowly and widget
// tests override one small thing rather than a notifier with an API behind it.
//
// **Why follow and not save.** Events and venues get saved *into* a zine; a zine
// is not saved into anything — the app's affordance for one has always been
// follow (`list_page_header.dart`), and it already renders as a bookmark, filled
// when following. So the row keeps the same glyph vocabulary as its two siblings
// while acting on a different rail.
//
// ⚠️ **Do NOT route this through `UnifiedListNotifier.toggleFollow()`.** That
// notifier is per-list and loads the list *and its items* on construction, so
// mounting one per row would reintroduce exactly the per-card fan-out PROD-4027
// removed from this feed a week ago. The three pieces of bookkeeping it does
// after a successful call are already public on `ListsNotifier`, and this file
// calls them directly.
//
// ⚠️ **KNOWN LIMITATION, and it is a backend gap rather than a shortcut here.**
// There is no bulk followed-zine-ids endpoint: `/users/me/saved/entity-ids`
// carries `event_ids` / `venue_ids` / `google_place_ids` and no `list_ids`, and
// `FeedZineItem` carries no `is_following`. The only client-side source is
// `ListsState.followingLists`, which is a **paginated section** of
// `/users/me/lists` — so a zine the caller follows beyond the first page renders
// **unfollowed until tapped**. Tapping still does the right thing (the endpoint
// is idempotent) and the local override then holds. The fix is one field on the
// wire; see the PROD-4116 backend ticket.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/models/discovery_engagement.dart';
import '../../../../data/models/feed_home.dart';
import '../../../../providers/api_provider.dart';
import '../../../../providers/auth_provider.dart';
import '../../../../providers/lists_provider.dart';
import '../../../../shared/widgets/impression_detector.dart';

/// Local, explicit follow overrides for zines shown in the feed.
///
/// `true` = followed, `false` = unfollowed. Absent = defer to
/// [ListsState.followingLists].
///
/// This exists because the optimistic path the list page uses does not fit here:
/// `ListsNotifier.prependFollowingList` takes a full [UserList], and a
/// `FeedZineItem` cannot honestly synthesise one — it has an id, a name and a
/// cover, not a visibility, an owner id or timestamps. Faking one to get an
/// optimistic tick would put a counterfeit list into the cache that every
/// `/yours` surface then reads. An override map says the one thing we actually
/// know.
///
/// ⚠️ **Registered in `userScopedProviders`.** It is the caller's own follows,
/// keyed by zine, so left unregistered account B would see account A's filled
/// bookmarks. `test/lint/user_scoped_provider_registry_test.dart` enforces it.
class FeedZineFollowOverrides extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  void record(String zineId, {required bool following}) {
    if (state[zineId] == following) return;
    state = {...state, zineId: following};
  }
}

final feedZineFollowOverridesProvider =
    NotifierProvider<FeedZineFollowOverrides, Map<String, bool>>(
      FeedZineFollowOverrides.new,
    );

/// Ids of zines the caller follows, from the cached following page.
///
/// A derived read rather than watching `listsProvider` wholesale, for the two
/// reasons its `feedSavedEventIdsProvider` sibling gives: it narrows the
/// rebuild — a page can hold ten of these bookmarks and every one would
/// otherwise rebuild on any lists mutation — and it gives widget tests **one
/// small thing to override** instead of a `ListsNotifier` with an API, a storage
/// service and an analytics client behind it. Reaching through to
/// `listsProvider` from a widget throws `UnimplementedError('Initialize in
/// main.dart')` in any test that never needed it, and it surfaces as an empty
/// tree rather than as the missing stub it is.
///
/// ⚠️ **Incomplete by construction** — `followingLists` is the first page of
/// `/users/me/lists`, not the full set. See the file header.
final feedFollowedZineIdsProvider = Provider<Set<String>>(
  (ref) => ref.watch(
    listsProvider.select((s) => s.followingLists.map((l) => l.id).toSet()),
  ),
);

/// Ids the caller has just unfollowed, from the shared tombstone set.
///
/// Separate from [feedFollowedZineIdsProvider] because an unfollow performed on
/// the zine *page* writes only this — `followingLists` is not re-fetched
/// synchronously — so a row that ignored it would keep showing a filled
/// bookmark for a zine the user just dropped.
final feedUnfollowedZineIdsProvider = Provider<Set<String>>(
  (ref) => ref.watch(listsProvider.select((s) => s.recentlyUnfollowedListIds)),
);

/// Whether the caller follows [zine].
///
/// Precedence: a local override wins, then the tombstone set, then the cached
/// following page.
bool isFeedZineFollowed(WidgetRef ref, FeedZineItem zine) {
  final override = ref.watch(
    feedZineFollowOverridesProvider.select((m) => m[zine.id]),
  );
  if (override != null) return override;
  if (ref.watch(feedUnfollowedZineIdsProvider).contains(zine.id)) return false;
  return ref.watch(feedFollowedZineIdsProvider).contains(zine.id);
}

/// Follows or unfollows [zine], optimistically.
///
/// Returns silently for a signed-out caller rather than prompting: the feed path
/// applies **no policy of its own** (D10) and a second guest branch here is how
/// the app's two gates diverge. Guest handling for the Zines page belongs
/// wherever the backend's `blurred` treatment puts it.
Future<void> toggleFeedZineFollow(
  BuildContext context,
  WidgetRef ref,
  FeedZineItem zine, {
  required bool currentlyFollowing,
}) async {
  if (!ref.read(isAuthenticatedProvider)) return;

  final api = ref.read(listsApiProvider);
  final lists = ref.read(listsProvider.notifier);
  final overrides = ref.read(feedZineFollowOverridesProvider.notifier);
  // PROD-4303 — captured before the await (the tracker is keepAlive; `ref` may
  // not survive the round trip), emitted only on the success path below.
  final tracker = ref.read(discoverySessionTrackerProvider);
  final next = !currentlyFollowing;

  // Optimistic first, so the bookmark fills in the same frame as the tap.
  overrides.record(zine.id, following: next);
  try {
    if (next) {
      await api.followList(zine.id);
      // Clear any prior tombstone, or an unfollow → re-follow round trip leaves
      // the zine hidden from every `/yours` "A seguir" surface (PROD-2128).
      lists.markListFollowed(zine.id);
    } else {
      await api.unfollowList(zine.id);
      lists.markListUnfollowed(zine.id);
    }
    // Confirmed by the server, so it may feed the engagement rail (PROD-4303).
    // Follow is a zine's save affordance — same glyph, same rail — and the
    // contract's `action_kind` enum has no `follow`, so it travels as
    // save/unsave with `item_type: zine` (wire vocabulary; `list` in store).
    // Exposure resolves first so it precedes the action in `seq` order
    // (contract v2).
    ImpressionDetector.resolveForItem(zine.id, endReason: 'action');
    tracker.action(
      actionKind: next
          ? DiscoveryEngagementAction.save
          : DiscoveryEngagementAction.unsave,
      itemId: zine.id,
      itemType: 'zine',
    );
  } catch (_) {
    // Roll the optimistic tick back to what the server still believes. Left
    // forward, the row would show a follow that does not exist and the user
    // would have no way to retry — the button would already look done.
    overrides.record(zine.id, following: currentlyFollowing);
  }
}
