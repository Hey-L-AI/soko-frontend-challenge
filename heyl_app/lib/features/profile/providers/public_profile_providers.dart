import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../data/models/social/public_profile.dart';
import '../../../data/models/social/social_proof.dart';
import '../../../data/models/social/follow_user_summary.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../entity_signals/providers/signal_controller.dart'
    show signalRevisionProvider;

/// Data providers for the admin-gated public-profile pilot (by @handle).
///
/// Each section is fetched independently so the header renders immediately and
/// gated sections (which may 403 for a private account) fail in isolation
/// without taking down the whole screen.

/// The by-handle profile payload (identity + counts + flags).
final publicProfileProvider = FutureProvider.family<PublicProfile, String>((
  ref,
  handle,
) {
  return ref.watch(socialProfileApiProvider).getProfile(handle);
});

/// The user's zines (viewer-relative).
final profileZinesProvider = FutureProvider.family<UserListsResponse, String>((
  ref,
  handle,
) {
  return ref.watch(socialProfileApiProvider).getZines(handle);
});

/// Editor-pick lists for the official Soko profile's "Editor picks" tab —
/// the same corpus as Discovery's Editor Picks shelf (public lists flagged
/// `editor_pick=true` by Soko admins, PROD-1513), but profile-scoped: fetched
/// globally (no location centroid) since a profile has no picker city. Empty
/// lists are filtered out at render like the Zines grid does.
final sokoEditorPicksProvider = FutureProvider.autoDispose<UserListsResponse>((
  ref,
) {
  return ref.watch(listsApiProvider).listPublicLists(editorPick: true);
});

/// The user's public taste twin (chips + narrative), viewer-relative. Used by
/// the "O que a {X} gosta" section for both self and visitors — the backend
/// returns an empty twin when the section is gated.
final profileTastesProvider = FutureProvider.family<MemoryTwinResponse, String>(
  (ref, handle) {
    return ref.watch(socialProfileApiProvider).getTastes(handle);
  },
);

/// The user's saved items (gated — throws on 403).
final profileSavedProvider = FutureProvider.family<SavedListResponse, String>((
  ref,
  handle,
) {
  return ref.watch(socialProfileApiProvider).getSaved(handle);
});

/// The caller's OWN liked items, merged into the Saved tab's Events / Places
/// segments (PROD-3779). Deliberately not `.family` over a handle: a like is
/// not public, so this only ever describes the signed-in user and the tab only
/// reads it when the profile being viewed is theirs.
///
/// Returns the same [SavedListResponse] shape as [profileSavedProvider] so the
/// two merge without a second model — but `savedId` here is a signal row id,
/// not a saved-item id.
///
/// Refetches itself on every chip tap, by DEPENDING on
/// [signalRevisionProvider] rather than waiting to be invalidated from a
/// widget. The difference is not style: an invalidate wired into a screen's
/// `build` only runs while that screen happens to be mounted, so a thumb tapped
/// anywhere else left this cached forever — stale until a page reload on web,
/// until an app restart on mobile. As a dependency it holds no matter who taps,
/// or where.
///
/// `autoDispose` on top of that: nothing outside the Saved tab reads it, so
/// there is no reason to keep the list warm once the tab is gone.
final myLikedItemsProvider = FutureProvider.autoDispose<SavedListResponse>((
  ref,
) {
  ref.watch(signalRevisionProvider);
  return ref.watch(signalApiProvider).getMySignals();
});

/// The public zines the user follows — the "Zines" segment of the Saved tab
/// (gated exactly like saved items — throws on 403).
final profileSavedZinesProvider =
    FutureProvider.family<UserListsResponse, String>((ref, handle) {
      return ref.watch(socialProfileApiProvider).getSavedZines(handle);
    });

/// The user's recent activity (empty when gated/hidden).
final profileActivityProvider =
    FutureProvider.family<ActivityListResponse, String>((ref, handle) {
      return ref.watch(socialProfileApiProvider).getActivity(handle);
    });

/// Viewer-relative social proof (tastes in common + mutual follows).
final profileSocialProofProvider =
    FutureProvider.family<ProfileSocialProof, String>((ref, handle) {
      return ref.watch(socialProfileApiProvider).getSocialProof(handle);
    });

/// Followers list (person surface — throws on 403 when gated).
final profileFollowersProvider =
    FutureProvider.family<FollowUserListResponse, String>((ref, handle) {
      return ref.watch(socialProfileApiProvider).getFollowers(handle);
    });

/// Following list (person surface — throws on 403 when gated).
final profileFollowingProvider =
    FutureProvider.family<FollowUserListResponse, String>((ref, handle) {
      return ref.watch(socialProfileApiProvider).getFollowing(handle);
    });

/// Mutual followers list — the full list behind the "Followed by …" line.
final profileMutualFollowersListProvider =
    FutureProvider.family<FollowUserListResponse, String>((ref, handle) {
      return ref.watch(socialProfileApiProvider).getMutualFollowers(handle);
    });

/// Incoming pending follow requests for the current (private) account.
final followRequestsProvider = FutureProvider<FollowUserListResponse>((ref) {
  return ref.watch(followsApiProvider).followRequests();
});

/// Live pending-request count for the inbox badge. Seeded from
/// [followRequestsProvider] and **decremented immediately** on each
/// accept/reject — so the badge updates right away even though the request
/// rows persist in the list until re-entry. Re-adopts the real count whenever
/// the list re-fetches.
class PendingRequestCount extends Notifier<int> {
  @override
  int build() {
    ref.listen(followRequestsProvider, (_, next) {
      next.whenData((r) => state = r.items.length);
    });
    return ref.read(followRequestsProvider).valueOrNull?.items.length ?? 0;
  }

  void decrement() {
    if (state > 0) state = state - 1;
  }
}

final pendingRequestCountProvider = NotifierProvider<PendingRequestCount, int>(
  PendingRequestCount.new,
);

/// Refresh the current user's own profile (its follower count) + followers
/// list after an accept/reject. Does NOT touch [followRequestsProvider] — the
/// requests row persists (Instagram-style "Follow back") and the list only
/// re-fetches on re-entry; the banner invalidates it explicitly to dismiss.
void invalidateMyFollowerCounts(WidgetRef ref) {
  final myHandle = ref.read(currentUserProvider)?.handle;
  if (myHandle != null && myHandle.isNotEmpty) {
    ref.invalidate(publicProfileProvider(myHandle));
    ref.invalidate(profileFollowersProvider(myHandle));
  }
}

/// After following someone (e.g. "Follow back"): refresh my own profile
/// (following count) + following list.
void invalidateMyFollowingCounts(WidgetRef ref) {
  final myHandle = ref.read(currentUserProvider)?.handle;
  if (myHandle != null && myHandle.isNotEmpty) {
    ref.invalidate(publicProfileProvider(myHandle));
    ref.invalidate(profileFollowingProvider(myHandle));
  }
}

/// Optimistic adjustment to the viewer's OWN "following" count — the count
/// sibling of [followStateProvider]. The counts are server-owned (they live on
/// [publicProfileProvider]), but a follow/unfollow deliberately does NOT refetch
/// that provider (it would flash the whole profile header through
/// `AsyncLoading`), so the mutation carries its net change here and the header
/// adds it to the server value. Every follow button on every screen writes it,
/// so my following count drops the instant I unfollow from anywhere — the same
/// cross-surface behaviour the buttons already have.
///
/// Reset to 0 by [resetMyFollowingCountDelta] on entry to my own profile, at the
/// same moment we invalidate [publicProfileProvider] for an authoritative
/// refetch — the fresh server count already includes every change, so pairing
/// the reset with the refetch means it never double-counts. Cleared on restart.
class MyFollowingCountDelta extends Notifier<int> {
  @override
  int build() => 0;

  /// +1 when the viewer follows someone, -1 when they unfollow.
  void bump(int by) => state = state + by;
  void reset() => state = 0;
}

final myFollowingCountDeltaProvider =
    NotifierProvider<MyFollowingCountDelta, int>(MyFollowingCountDelta.new);

/// Optimistic adjustment to the viewer's OWN "followers" count — the sibling of
/// [myFollowingCountDeltaProvider]. My followers count only changes by *my* hand
/// when I remove a follower, so this carries that -1 for an instant drop; other
/// changes (someone follows/unfollows me) come from the server refetch. Reset
/// alongside the following delta on an authoritative refetch of my profile.
class MyFollowerCountDelta extends Notifier<int> {
  @override
  int build() => 0;

  /// -1 when I remove a follower.
  void bump(int by) => state = state + by;
  void reset() => state = 0;
}

final myFollowerCountDeltaProvider =
    NotifierProvider<MyFollowerCountDelta, int>(MyFollowerCountDelta.new);

/// The net change to the viewer's following count for a [from] → [to] follow
/// transition. Only `following` membership counts — request transitions on a
/// private account (`none` ↔ `requested`) don't change it.
int followingCountDelta(String from, String to) {
  final wasFollowing = from == 'following';
  final nowFollowing = to == 'following';
  if (wasFollowing == nowFollowing) return 0;
  return nowFollowing ? 1 : -1;
}

/// Drop the optimistic follower/following-count deltas. Call this paired with an
/// authoritative refetch of the viewer's own [publicProfileProvider] (e.g. on
/// entry to their own profile), never on its own — the fresh server counts
/// already fold in every change.
void resetMyProfileCountDeltas(WidgetRef ref) {
  ref.read(myFollowingCountDeltaProvider.notifier).reset();
  ref.read(myFollowerCountDeltaProvider.notifier).reset();
}
