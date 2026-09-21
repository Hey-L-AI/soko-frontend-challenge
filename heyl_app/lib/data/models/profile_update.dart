/// Request to update user profile (name, handle, and/or preferred_locale)
class ProfileUpdateRequest {
  final String? fullName;
  final String? handle;
  final String? preferredLocale;
  // Social profile fields (PROD-2814). Null = leave unchanged. Empty bio clears it.
  final String? bio;
  final bool? isPrivate;
  final bool? showBioMemories;
  final bool? showActivity;
  final bool? showSaved;

  /// Avatar paper-grain texture id (catalog id like '03'). Empty string clears
  /// it back to the default.
  final String? avatarTexture;

  /// User-chosen static display city (e.g. 'Lisboa'). Empty string clears it.
  /// NOT the live GPS/IP location.
  final String? city;

  // Social links (profile banner row). Handles are sent without the '@'
  // prefix; the website is a bare URL. Empty string clears the field.
  final String? instagramHandle;
  final String? tiktokHandle;
  final String? websiteUrl;

  const ProfileUpdateRequest({
    this.fullName,
    this.handle,
    this.preferredLocale,
    this.bio,
    this.isPrivate,
    this.showBioMemories,
    this.showActivity,
    this.showSaved,
    this.avatarTexture,
    this.city,
    this.instagramHandle,
    this.tiktokHandle,
    this.websiteUrl,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (fullName != null) {
      json['full_name'] = fullName;
    }
    if (handle != null) {
      json['handle'] = handle;
    }
    if (preferredLocale != null) {
      json['preferred_locale'] = preferredLocale;
    }
    if (bio != null) {
      json['bio'] = bio;
    }
    if (isPrivate != null) {
      json['is_private'] = isPrivate;
    }
    if (showBioMemories != null) {
      json['show_bio_memories'] = showBioMemories;
    }
    if (showActivity != null) {
      json['show_activity'] = showActivity;
    }
    if (showSaved != null) {
      json['show_saved'] = showSaved;
    }
    if (avatarTexture != null) {
      json['avatar_texture'] = avatarTexture;
    }
    if (city != null) {
      json['city'] = city;
    }
    if (instagramHandle != null) {
      json['instagram_handle'] = instagramHandle;
    }
    if (tiktokHandle != null) {
      json['tiktok_handle'] = tiktokHandle;
    }
    if (websiteUrl != null) {
      json['website_url'] = websiteUrl;
    }
    return json;
  }
}

/// Response from profile update API
class ProfileUpdateResponse {
  final String id;
  final String userId; // Now a UUID (same as id)
  final String? displayIdentifier; // Phone or email for display
  final String? fullName;
  final String? preferredLocale;
  final String? handle;
  final DateTime? handleLastChangedAt;
  final DateTime? handleNextChangeAllowedAt;
  final String? bio;
  final String? avatarUrl;
  final bool isPrivate;
  final bool showBioMemories;
  final bool showActivity;
  final bool showSaved;
  final DateTime updatedAt;

  const ProfileUpdateResponse({
    required this.id,
    required this.userId,
    this.displayIdentifier,
    this.fullName,
    this.preferredLocale,
    this.handle,
    this.handleLastChangedAt,
    this.handleNextChangeAllowedAt,
    this.bio,
    this.avatarUrl,
    this.isPrivate = false,
    this.showBioMemories = true,
    this.showActivity = true,
    this.showSaved = true,
    required this.updatedAt,
  });

  factory ProfileUpdateResponse.fromJson(Map<String, dynamic> json) {
    return ProfileUpdateResponse(
      id: json['id'] as String,
      userId: json['id'] as String,
      displayIdentifier: json['display_identifier'] as String?,
      fullName: json['full_name'] as String?,
      preferredLocale: json['preferred_locale'] as String?,
      handle: json['handle'] as String?,
      handleLastChangedAt: json['handle_last_changed_at'] != null
          ? DateTime.parse(json['handle_last_changed_at'] as String)
          : null,
      handleNextChangeAllowedAt: json['handle_next_change_allowed_at'] != null
          ? DateTime.parse(json['handle_next_change_allowed_at'] as String)
          : null,
      bio: json['bio'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      isPrivate: json['is_private'] as bool? ?? false,
      showBioMemories: json['show_bio_memories'] as bool? ?? true,
      showActivity: json['show_activity'] as bool? ?? true,
      showSaved: json['show_saved'] as bool? ?? true,
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }
}
