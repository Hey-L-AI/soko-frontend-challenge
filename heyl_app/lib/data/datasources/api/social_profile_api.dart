import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../../models/social/public_profile.dart';
import '../../models/social/memory_bio_state.dart';
import '../../models/social/social_proof.dart';
import '../../models/social/follow_counts.dart';
import '../../models/social/follow_user_summary.dart';
import 'api_client.dart';

/// By-handle public profile + its sections (backend PROD-2775 / 2815 / 2816 /
/// 2819 / 2822). Admin-gated pilot ahead of the real designs.
///
/// Privacy is enforced server-side by the viewer-relative resolver: a private
/// account returns the stub (identity + counts) with private sections locked;
/// gated section endpoints return 403 when the viewer may not see them.
class SocialProfileApi {
  final ApiClient _apiClient;

  SocialProfileApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// The profile payload behind a @handle.
  Future<PublicProfile> getProfile(String handle) async {
    final response = await _dio.get(ApiConstants.profileByHandle(handle));
    return PublicProfile.fromJson(response.data as Map<String, dynamic>);
  }

  /// Viewer-relative social proof (tastes in common + mutual follows).
  Future<ProfileSocialProof> getSocialProof(String handle) async {
    final response = await _dio.get(
      ApiConstants.profileSocialProofByHandle(handle),
    );
    return ProfileSocialProof.fromJson(response.data as Map<String, dynamic>);
  }

  /// Display-only follower/following counts (also on the profile payload).
  Future<FollowCounts> getFollowCounts(String handle) async {
    final response = await _dio.get(
      ApiConstants.profileFollowCountsByHandle(handle),
    );
    return FollowCounts.fromJson(response.data as Map<String, dynamic>);
  }

  /// Followers list (person surface — 403 when gated).
  Future<FollowUserListResponse> getFollowers(
    String handle, {
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.profileFollowersByHandle(handle),
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return FollowUserListResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// Following list (person surface — 403 when gated).
  Future<FollowUserListResponse> getFollowing(
    String handle, {
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.profileFollowingByHandle(handle),
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return FollowUserListResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// Mutual followers — people the viewer follows who also follow this profile
  /// (the full list behind the "Followed by …" line).
  Future<FollowUserListResponse> getMutualFollowers(
    String handle, {
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.profileMutualFollowersByHandle(handle),
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return FollowUserListResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// The user's zines, viewer-relative (owner all / follower +followers /
  /// else public). Reuses the existing lists response shape.
  Future<UserListsResponse> getZines(
    String handle, {
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.profileZinesByHandle(handle),
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return UserListsResponse.fromJson(response.data as Map<String, dynamic>);
  }

  /// The public zines the user follows (their "saved zines"), gated exactly
  /// like the saved-items tab (403 when the viewer may not see them). Reuses
  /// the lists response shape.
  Future<UserListsResponse> getSavedZines(
    String handle, {
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.profileSavedZinesByHandle(handle),
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return UserListsResponse.fromJson(response.data as Map<String, dynamic>);
  }

  /// The user's public taste twin (chips + narrative), viewer-relative
  /// (PROD-2775 redesign). Powers the "O que a {X} gosta" section for both self
  /// and visitors; the backend strips raw backing facts and returns an empty
  /// twin when the section is gated (private account / hidden by the owner).
  Future<MemoryTwinResponse> getTastes(String handle) async {
    final response = await _dio.get(ApiConstants.profileTastesByHandle(handle));
    return MemoryTwinResponse.fromJson(response.data as Map<String, dynamic>);
  }

  /// The user's saved items (gated — 403 when the viewer may not see them).
  Future<SavedListResponse> getSaved(
    String handle, {
    String? itemType,
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.profileSavedByHandle(handle),
      queryParameters: {
        if (itemType != null) 'item_type': itemType,
        'limit': limit,
        'offset': offset,
      },
    );
    return SavedListResponse.fromJson(response.data as Map<String, dynamic>);
  }

  /// Upload (or replace) the current user's avatar. Bytes work on web + native
  /// (image_picker `readAsBytes`). Returns the updated profile response.
  Future<ProfileUpdateResponse> uploadAvatar(
    List<int> bytes,
    String filename,
  ) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    final response = await _dio.post(
      ApiConstants.myAvatarUpload,
      data: formData,
      options: Options(contentType: 'multipart/form-data'),
    );
    return ProfileUpdateResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// Remove the current user's avatar. Idempotent; returns the updated profile.
  Future<ProfileUpdateResponse> deleteAvatar() async {
    final response = await _dio.delete(ApiConstants.myAvatar);
    return ProfileUpdateResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// Accept a pending (proposed) memory bio, promoting it to the public one
  /// (propose-not-overwrite). No-op returning the current state when nothing is
  /// pending. Owner-only.
  Future<MemoryBioState> acceptMemoryBio() async {
    final response = await _dio.post(ApiConstants.myMemoryBioAccept);
    return MemoryBioState.fromJson(response.data as Map<String, dynamic>);
  }

  /// Reject a pending (proposed) memory bio, keeping the current one. No-op
  /// returning the current state when nothing is pending. Owner-only.
  Future<MemoryBioState> rejectMemoryBio() async {
    final response = await _dio.post(ApiConstants.myMemoryBioReject);
    return MemoryBioState.fromJson(response.data as Map<String, dynamic>);
  }

  /// Hide or unhide the memory bio on the public profile. Owner-only.
  Future<MemoryBioState> setMemoryBioHidden(bool hidden) async {
    final response = await _dio.patch(
      ApiConstants.myMemoryBio,
      data: {'hidden': hidden},
    );
    return MemoryBioState.fromJson(response.data as Map<String, dynamic>);
  }

  /// The user's recent public activity (empty when gated / hidden).
  Future<ActivityListResponse> getActivity(
    String handle, {
    int limit = 6,
  }) async {
    final response = await _dio.get(
      ApiConstants.profileActivityByHandle(handle),
      queryParameters: {'limit': limit},
    );
    return ActivityListResponse.fromJson(response.data as Map<String, dynamic>);
  }
}
