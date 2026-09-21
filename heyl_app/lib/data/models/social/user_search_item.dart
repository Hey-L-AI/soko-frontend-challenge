/// A lean zine-cover projection for a suggested-user preview thumbnail.
/// Carries exactly the fields `ZineCoverRecipe.fromFields` needs — no full list.
class ZinePreview {
  final String id;
  final String name;
  final String? coverType;
  final String? coverColor;
  final String? coverTexture;
  final String? coverTextColor;
  final String? coverItemId;
  final String? coverItemImageUrl;
  final String? coverImageUrl;
  final bool coverShowTitle;
  final bool coverShowTexture;
  final bool coverShowLogo;
  final String? previewImage;

  const ZinePreview({
    required this.id,
    required this.name,
    this.coverType,
    this.coverColor,
    this.coverTexture,
    this.coverTextColor,
    this.coverItemId,
    this.coverItemImageUrl,
    this.coverImageUrl,
    this.coverShowTitle = true,
    this.coverShowTexture = true,
    this.coverShowLogo = true,
    this.previewImage,
  });

  factory ZinePreview.fromJson(Map<String, dynamic> json) {
    return ZinePreview(
      id:
          json['id']
              as String, // gstack:allow check-error-handling json-cast-string
      name: (json['name'] as String?) ?? '',
      coverType: json['cover_type'] as String?,
      coverColor: json['cover_color'] as String?,
      coverTexture: json['cover_texture'] as String?,
      coverTextColor: json['cover_text_color'] as String?,
      coverItemId: json['cover_item_id'] as String?,
      coverItemImageUrl: json['cover_item_image_url'] as String?,
      coverImageUrl: json['cover_image_url'] as String?,
      coverShowTitle: json['cover_show_title'] as bool? ?? true,
      coverShowTexture: json['cover_show_texture'] as bool? ?? true,
      coverShowLogo: json['cover_show_logo'] as bool? ?? true,
      previewImage: json['preview_image'] as String?,
    );
  }
}

/// A people-search / suggested-users result (backend PROD-2777 / PROD-2821).
class UserSearchItem {
  final String userId;
  final String? handle;
  final String? fullName;
  final String? avatarUrl;

  /// Manually-assigned Expert tag (backend PROD-3336). Drives the Expert badge
  /// next to the name in people search / suggestions.
  final bool isExpert;

  /// Whether the viewer actively follows this user (pending reads false).
  final bool isFollowing;

  /// Whether this user follows the viewer (drives "Follow back") and whether the
  /// viewer has a pending request to them (drives "Requested"). Viewer-relative.
  final bool followsYou;
  final bool requested;

  /// Suggestions-only row-subtitle metadata (empty on the plain search
  /// surface): the user's home city, tastes shared with the viewer, and public
  /// zines created. Display-only (ADR-032).
  final String? city;
  final int sharedTastesCount;
  final int zinesCount;

  /// "Followed by X + N" — people the viewer follows who also follow this user.
  final int mutualFollowersCount;
  final String? mutualFollowerName;

  /// Up to 3 avatar URLs of those mutual followers, for the "N in common" row
  /// of mini round profile photos on the Locals surfaces.
  final List<String> mutualFollowerAvatars;

  /// Up to 3 public zine covers, for the suggestion card preview (empty on the
  /// plain search surface).
  final List<ZinePreview> zinePreviews;

  /// Contact-discovery only: the SHA-256 phone hash (of the ones the client
  /// sent) that matched this user, so the app can map the match back to the
  /// local address-book entry ("you may know as …"). Null on every other
  /// surface (search / suggestions never populate it).
  final String? phoneHash;

  const UserSearchItem({
    required this.userId,
    this.handle,
    this.fullName,
    this.avatarUrl,
    this.isExpert = false,
    this.isFollowing = false,
    this.followsYou = false,
    this.requested = false,
    this.city,
    this.sharedTastesCount = 0,
    this.zinesCount = 0,
    this.mutualFollowersCount = 0,
    this.mutualFollowerName,
    this.mutualFollowerAvatars = const [],
    this.zinePreviews = const [],
    this.phoneHash,
  });

  factory UserSearchItem.fromJson(Map<String, dynamic> json) {
    return UserSearchItem(
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
      city: json['city'] as String?,
      sharedTastesCount: json['shared_tastes_count'] as int? ?? 0,
      zinesCount: json['zines_count'] as int? ?? 0,
      mutualFollowersCount: json['mutual_followers_count'] as int? ?? 0,
      mutualFollowerName: json['mutual_follower_name'] as String?,
      mutualFollowerAvatars:
          (json['mutual_follower_avatars'] as List<dynamic>? ?? const [])
              .map((e) => e as String)
              .toList(),
      zinePreviews: (json['zine_previews'] as List<dynamic>? ?? const [])
          .map((e) => ZinePreview.fromJson(e as Map<String, dynamic>))
          .toList(),
      phoneHash: json['phone_hash'] as String?,
    );
  }
}

/// Paginated list of user results (search or suggestions).
class UserSearchListResponse {
  final List<UserSearchItem> items;
  final int total;

  const UserSearchListResponse({required this.items, required this.total});

  factory UserSearchListResponse.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>? ?? const []);
    return UserSearchListResponse(
      items: rawItems
          .map((e) => UserSearchItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
    );
  }
}
