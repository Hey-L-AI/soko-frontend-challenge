import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/social/follow_user_summary.dart';
import '../../../providers/api_provider.dart';

/// Followers of a zine, keyed by list id. Public zines are viewable by anyone;
/// private zines are owner-only (the request 403s otherwise). Rows carry the
/// viewer's follow relationship so the list renders Follow / Following /
/// Follow-back buttons, matching the profile followers list.
final listFollowersProvider =
    FutureProvider.family<FollowUserListResponse, String>((ref, listId) {
      return ref.watch(listsApiProvider).getListFollowers(listId);
    });
