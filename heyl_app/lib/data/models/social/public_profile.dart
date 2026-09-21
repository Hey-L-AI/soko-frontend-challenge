import '../../../core/config/environment.dart';

/// The by-handle public profile payload (backend PROD-2775).
///
/// Returned for both public and private accounts. For a private account viewed
/// by a non-follower this is the locked "stub": identity + counts are present,
/// but [canViewPrivateSections] is false so the client hides the
/// activity / saved / bio-memories / follower lists.
class PublicProfile {
  final String userId;
  final String? handle;
  final String? fullName;
  final String? avatarUrl;

  /// Paper-grain texture id for the avatar (catalog id like '03'); null falls
  /// back to the default texture.
  final String? avatarTexture;
  final String? bio;

  /// LLM-generated memory bio, viewer-relative + privacy-gated by the backend.
  /// Null when none exists, the owner hid it, their `show_bio_memories` toggle
  /// is off, or the viewer may not see the private person surfaces.
  final String? memoryBio;

  /// Owner-only: a freshly-regenerated bio awaiting the owner's acceptance
  /// (propose-not-overwrite). Null for non-owners and when nothing is pending.
  final String? memoryBioPending;

  /// Owner-only: whether the owner has hidden their memory bio. Always false
  /// for non-owners.
  final bool memoryBioHidden;

  final String? city;

  // Social links shown as a row under the profile actions (Figma Frame
  // 9534/9535). Handles are stored without the '@' prefix; the website is a
  // bare URL (scheme optional). Null/empty = not set.
  final String? instagramHandle;
  final String? tiktokHandle;
  final String? websiteUrl;

  final bool isPrivate;

  /// Manually-assigned Expert tag (backend PROD-3336). Drives the Expert badge
  /// next to the name on the profile header.
  final bool isExpert;

  // Display-only counts (shown even on a private account's stub).
  final int followersCount;
  final int followingCount;
  final int zinesCount;
  final int savedCount;

  /// Viewer's relationship: `self` | `following` | `requested` | `none`.
  final String viewerRelationship;

  /// Whether this profile's owner follows the viewer. With [viewerRelationship]
  /// `none`, drives a "Follow back" header button instead of a plain "Follow".
  final bool followsYou;

  /// Whether the viewer may see the privacy-gated person surfaces
  /// (activity / saved / bio memories).
  final bool canViewPrivateSections;

  /// Whether the follower / following lists are browsable — only on a mutual
  /// follow (both follow each other), or on your own profile.
  final bool isMutualFollow;

  // Owner's section toggles (only meaningful when the section is visible).
  final bool showBioMemories;
  final bool showActivity;
  final bool showSaved;

  /// Backend flag marking the official Soko account (brand/editorial, not a
  /// person). Absent today — see [isOfficial], which falls back to matching the
  /// configured Soko handle so the surface works before the flag ships.
  final bool isOfficialFlag;

  const PublicProfile({
    required this.userId,
    this.handle,
    this.fullName,
    this.avatarUrl,
    this.avatarTexture,
    this.bio,
    this.memoryBio,
    this.memoryBioPending,
    this.memoryBioHidden = false,
    this.city,
    this.instagramHandle,
    this.tiktokHandle,
    this.websiteUrl,
    this.isPrivate = false,
    this.isExpert = false,
    this.followersCount = 0,
    this.followingCount = 0,
    this.zinesCount = 0,
    this.savedCount = 0,
    this.viewerRelationship = 'none',
    this.followsYou = false,
    this.canViewPrivateSections = false,
    this.isMutualFollow = false,
    this.showBioMemories = true,
    this.showActivity = true,
    this.showSaved = true,
    this.isOfficialFlag = false,
  });

  bool get isSelf => viewerRelationship == 'self';
  bool get isFollowing => viewerRelationship == 'following';
  bool get isRequested => viewerRelationship == 'requested';

  /// Whether this is the official Soko account — a brand/editorial account,
  /// not a person. Such accounts hide the person-only surfaces (bio + memory
  /// "tastes" section). Uses the backend [isOfficialFlag] when present, and
  /// otherwise falls back to matching the configured
  /// [EnvironmentConfig.sokoHandle] (case-insensitive, mirroring the backend's
  /// by-handle lookup) so the pilot works before the flag ships.
  bool get isOfficial =>
      isOfficialFlag ||
      (handle != null &&
          handle!.toLowerCase() == EnvironmentConfig.sokoHandle.toLowerCase());

  factory PublicProfile.fromJson(Map<String, dynamic> json) {
    return PublicProfile(
      userId:
          json['user_id']
              as String, // gstack:allow check-error-handling json-cast-string
      handle: json['handle'] as String?,
      fullName: json['full_name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      avatarTexture: json['avatar_texture'] as String?,
      bio: json['bio'] as String?,
      memoryBio: json['memory_bio'] as String?,
      memoryBioPending: json['memory_bio_pending'] as String?,
      memoryBioHidden: json['memory_bio_hidden'] as bool? ?? false,
      city: json['city'] as String?,
      instagramHandle: json['instagram_handle'] as String?,
      tiktokHandle: json['tiktok_handle'] as String?,
      websiteUrl: json['website_url'] as String?,
      isPrivate: json['is_private'] as bool? ?? false,
      isExpert: json['is_expert'] as bool? ?? false,
      followersCount: json['followers_count'] as int? ?? 0,
      followingCount: json['following_count'] as int? ?? 0,
      zinesCount: json['zines_count'] as int? ?? 0,
      savedCount: json['saved_count'] as int? ?? 0,
      viewerRelationship: json['viewer_relationship'] as String? ?? 'none',
      followsYou: json['follows_you'] as bool? ?? false,
      canViewPrivateSections:
          json['can_view_private_sections'] as bool? ?? false,
      isMutualFollow: json['is_mutual_follow'] as bool? ?? false,
      showBioMemories: json['show_bio_memories'] as bool? ?? true,
      showActivity: json['show_activity'] as bool? ?? true,
      showSaved: json['show_saved'] as bool? ?? true,
      isOfficialFlag: json['is_official'] as bool? ?? false,
    );
  }
}
