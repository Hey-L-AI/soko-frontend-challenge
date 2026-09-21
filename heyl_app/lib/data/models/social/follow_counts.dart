/// Display-only follower / following counts (backend PROD-2819, ADR-032-safe).
class FollowCounts {
  final int followers;
  final int following;

  const FollowCounts({required this.followers, required this.following});

  factory FollowCounts.fromJson(Map<String, dynamic> json) {
    return FollowCounts(
      followers: json['followers'] as int? ?? 0,
      following: json['following'] as int? ?? 0,
    );
  }
}
