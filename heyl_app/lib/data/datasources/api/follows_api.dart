import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/social/follow_state.dart';
import '../../models/social/follow_user_summary.dart';
import 'api_client.dart';

/// User→user follow graph + private-account request flow
/// (backend Phase A + PROD-2776 / 2819). Admin-gated pilot.
class FollowsApi {
  final ApiClient _apiClient;

  FollowsApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Follow a user. Public account → immediate active follow; private account
  /// → a pending request (`requested` true, `status` = 'pending').
  Future<FollowState> follow(String userId) async {
    final response = await _dio.post(ApiConstants.followUser(userId));
    return FollowState.fromJson(response.data as Map<String, dynamic>);
  }

  /// Unfollow a user (also cancels a pending request).
  Future<FollowState> unfollow(String userId) async {
    final response = await _dio.delete(ApiConstants.followUser(userId));
    return FollowState.fromJson(response.data as Map<String, dynamic>);
  }

  /// My followers.
  Future<FollowUserListResponse> myFollowers({
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.myFollowers,
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return FollowUserListResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// Remove one of my followers — the `follower → me` edge. On success (204)
  /// that user no longer follows me; they are NOT notified (Instagram
  /// behaviour). 404 if they weren't an active follower.
  Future<void> removeFollower(String followerUserId) async {
    await _dio.delete(ApiConstants.removeFollower(followerUserId));
  }

  /// Incoming pending follow requests (private account).
  Future<FollowUserListResponse> followRequests({
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.myFollowRequests,
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return FollowUserListResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// Approve a pending request (the requester becomes an active follower).
  Future<FollowState> acceptRequest(String followerUserId) async {
    final response = await _dio.post(
      ApiConstants.acceptFollowRequest(followerUserId),
    );
    return FollowState.fromJson(response.data as Map<String, dynamic>);
  }

  /// Reject a pending request.
  Future<FollowState> rejectRequest(String followerUserId) async {
    final response = await _dio.post(
      ApiConstants.rejectFollowRequest(followerUserId),
    );
    return FollowState.fromJson(response.data as Map<String, dynamic>);
  }
}
