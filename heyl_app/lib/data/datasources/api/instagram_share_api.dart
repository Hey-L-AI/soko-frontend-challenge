import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/instagram_share.dart';
import 'api_client.dart';
import 'instagram_share_failure.dart';

/// API client for Instagram share extension endpoints.
class InstagramShareApi {
  final ApiClient _apiClient;

  InstagramShareApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Submit an Instagram URL for scraping.
  ///
  /// Returns a [ShareSubmitResponse] discriminated by type (post vs profile).
  /// Throws [InstagramShareFailure] on errors.
  Future<ShareSubmitResponse> submitShare(String url, {String? listId}) async {
    try {
      final response = await _dio.post(
        ApiConstants.instagramShare,
        data: {'url': url, if (listId != null) 'list_id': listId},
      );
      return ShareSubmitResponse.fromJson(
        response.data as Map<String, dynamic>,
      );
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  /// List the authenticated user's shared posts (newest first).
  Future<List<SharedPostOut>> listShares({int? limit, int? skip}) async {
    final queryParams = <String, dynamic>{};
    if (limit != null) queryParams['limit'] = limit;
    if (skip != null) queryParams['skip'] = skip;

    final response = await _dio.get(
      ApiConstants.instagramShares,
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );

    final list = response.data as List<dynamic>;
    return list
        .map((e) => SharedPostOut.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get one submitted Instagram share by ID.
  Future<SharedPostOut> getShare(String sharedPostId) async {
    final response = await _dio.get(
      ApiConstants.instagramShareById(sharedPostId),
    );

    return SharedPostOut.fromJson(response.data as Map<String, dynamic>);
  }

  InstagramShareFailure _mapDioError(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.connectionError) {
      return const InstagramShareNetworkError();
    }

    final status = e.response?.statusCode;
    switch (status) {
      case 400:
        final detail =
            (e.response?.data as Map<String, dynamic>?)?['detail'] as String?;
        return InstagramShareInvalidUrl(detail: detail);
      case 429:
        return const InstagramShareRateLimited();
      default:
        return InstagramShareUnknown(statusCode: status);
    }
  }
}
