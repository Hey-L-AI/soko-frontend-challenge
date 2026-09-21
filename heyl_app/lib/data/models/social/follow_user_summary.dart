/// A safe public summary of a user in a follower / following / request list
/// (backend PROD-2819 / PROD-2776).
class FollowUserSummary {
  final String userId;
  final String? handle;
  final String? fullName;
  final String? avatarUrl;

  /// Manually-assigned Expert tag (backend PROD-3336). Drives the Expert badge
  /// next to the name in follower / following lists.
  final bool isExpert;

  /// Whether the current viewer actively follows this user — drives the
  /// row's "Following" button.
  final bool isFollowing;

  /// Whether this user actively follows the viewer. With [isFollowing] false,
  /// this drives "Follow back". Viewer-relative (not relative to whichever
  /// profile's list this row appears in).
  final bool followsYou;

  /// Whether the viewer has a pending follow request to this user — drives
  /// "Requested" on load. Disjoint from [isFollowing].
  final bool requested;

  const FollowUserSummary({
    required this.userId,
    this.handle,
    this.fullName,
    this.avatarUrl,
    this.isExpert = false,
    this.isFollowing = false,
    this.followsYou = false,
    this.requested = false,
  });

  factory FollowUserSummary.fromJson(Map<String, dynamic> json) {
    return FollowUserSummary(
      userId:
          json['user_id']
              as String, // gstack:allow check-error-handling json-cast-string
      handle: json['handle'] as String?,
      fullName: json['full_name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      isExpert: json['is_expert'] as bool? ?? false,
      isFollowing: json['is_following'] as bool? ?? false,
      followsYou: json['follows_you'] as bool? ?? false,
      requested: json['requested'] as bool? ?? false,
    );
  }
}

/// Paginated list of user summaries (followers / following / requests).
class FollowUserListResponse {
  final List<FollowUserSummary> items;
  final int total;

  const FollowUserListResponse({required this.items, required this.total});

  factory FollowUserListResponse.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>? ?? const []);
    return FollowUserListResponse(
      items: rawItems
          .map((e) => FollowUserSummary.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
    );
  }
}
