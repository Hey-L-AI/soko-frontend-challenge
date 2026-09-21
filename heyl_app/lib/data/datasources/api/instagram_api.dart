import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/instagram_connection.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Instagram API
class InstagramApi implements IInstagramApi {
  final ApiClient _apiClient;

  InstagramApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<InstagramConnectResponse> getConnectUrl() async {
    final response = await _dio.get(ApiConstants.instagramConnect);
    final data = response.data as Map<String, dynamic>;
    debugPrint('[InstagramApi] getConnectUrl response received');
    return InstagramConnectResponse.fromJson(data);
  }

  @override
  Future<InstagramConnectionListResponse> listConnections() async {
    final response = await _dio.get(ApiConstants.instagramConnections);
    final data = response.data as Map<String, dynamic>;
    debugPrint(
        '[InstagramApi] listConnections: ${(data['connections'] as List?)?.length ?? 0} connections');
    return InstagramConnectionListResponse.fromJson(data);
  }

  @override
  Future<void> disconnect(String connectionId) async {
    await _dio.delete(ApiConstants.instagramConnection(connectionId));
    debugPrint('[InstagramApi] disconnected connection: $connectionId');
  }

  @override
  Future<PendingConnectionResponse> getPendingConnection(String key) async {
    final response =
        await _dio.get(ApiConstants.instagramPendingConnection(key));
    final data = response.data as Map<String, dynamic>;
    debugPrint('[InstagramApi] getPendingConnection: ${data['ig_username']}');
    return PendingConnectionResponse.fromJson(data);
  }

  @override
  Future<PendingConnectionConfirmResponse> confirmPendingConnection(
      String key) async {
    final response =
        await _dio.post(ApiConstants.instagramPendingConnectionConfirm(key));
    final data = response.data as Map<String, dynamic>;
    debugPrint('[InstagramApi] confirmPendingConnection: ${data['status']}');
    return PendingConnectionConfirmResponse.fromJson(data);
  }
}
