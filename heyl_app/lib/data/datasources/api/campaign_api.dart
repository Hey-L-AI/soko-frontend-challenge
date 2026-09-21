import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/campaign.dart';
import '../interfaces/campaign_api.dart';
import 'api_client.dart';

/// Real HTTP implementation of [ICampaignApi].
///
/// Tolerates 404 responses on the read paths so the app can ship ahead of
/// the backend endpoints landing: [getActiveCampaigns] returns an empty
/// list, and [submitCampaignResponse] is a no-op. [getCampaign] rethrows —
/// a direct fetch by key has no sensible empty fallback, so the caller
/// (typically a deep link) surfaces the error.
class CampaignApi implements ICampaignApi {
  CampaignApi({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  @override
  Future<List<Campaign>> getActiveCampaigns() =>
      _fetchList(ApiConstants.campaignsActive);

  @override
  Future<List<Campaign>> getCampaignsForUser() =>
      _fetchList(ApiConstants.campaigns);

  /// Shared parse for the two list reads (`/active` and the `/campaigns`
  /// catalog) — both return `ActiveCampaignsOut` (`{ campaigns: [...] }`) and
  /// both tolerate a 404 (endpoint not yet deployed) as an empty list.
  Future<List<Campaign>> _fetchList(String path) async {
    try {
      final response = await _apiClient.dio.get(path);
      final data = response.data;
      if (data is! Map<String, dynamic>) return const [];
      final raw = data['campaigns'];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((c) => Campaign.fromJson(Map<String, dynamic>.from(c)))
          .toList(growable: false);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const [];
      rethrow;
    }
  }

  @override
  Future<Campaign> getCampaign(String key) async {
    final response = await _apiClient.dio.get(ApiConstants.campaign(key));
    return Campaign.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<void> submitCampaignResponse(
    String key,
    CampaignResponseRequest request,
  ) async {
    try {
      await _apiClient.dio.post(
        ApiConstants.campaignResponse(key),
        data: request.toJson(),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return;
      rethrow;
    }
  }
}
