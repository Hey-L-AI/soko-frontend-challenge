import 'follow_user_summary.dart';

/// Viewer-relative social proof for a profile (backend PROD-2822).
///
/// "N tastes in common" + "followed by people you know". Display-only.
class ProfileSocialProof {
  final List<String> sharedTastes;
  final int sharedTastesCount;
  final List<FollowUserSummary> mutualFollowers;
  final int mutualFollowersCount;

  const ProfileSocialProof({
    this.sharedTastes = const [],
    this.sharedTastesCount = 0,
    this.mutualFollowers = const [],
    this.mutualFollowersCount = 0,
  });

  factory ProfileSocialProof.fromJson(Map<String, dynamic> json) {
    final tastes = (json['shared_tastes'] as List<dynamic>? ?? const [])
        .map((e) => e as String)
        .toList();
    final mutuals = (json['mutual_followers'] as List<dynamic>? ?? const [])
        .map((e) => FollowUserSummary.fromJson(e as Map<String, dynamic>))
        .toList();
    return ProfileSocialProof(
      sharedTastes: tastes,
      sharedTastesCount: json['shared_tastes_count'] as int? ?? 0,
      mutualFollowers: mutuals,
      mutualFollowersCount: json['mutual_followers_count'] as int? ?? 0,
    );
  }
}
