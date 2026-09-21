import '../../../core/constants/api_constants.dart';
import '../../models/moderation.dart';
import '../interfaces/moderation_api.dart';
import 'api_client.dart';

/// Real HTTP implementation of [IModerationApi] (PROD-2264).
class ModerationApi implements IModerationApi {
  final ApiClient _apiClient;

  ModerationApi({required ApiClient apiClient}) : _apiClient = apiClient;

  @override
  Future<ReportCreated> submitReport(ReportCreateRequest request) async {
    final response = await _apiClient.dio.post(
      ApiConstants.moderationReports,
      data: request.toJson(),
    );
    return ReportCreated.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<BlockCreated> blockUser(BlockCreateRequest request) async {
    final response = await _apiClient.dio.post(
      ApiConstants.moderationBlocks,
      data: request.toJson(),
    );
    return BlockCreated.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<List<BlockedUser>> listBlocks() async {
    final response = await _apiClient.dio.get(ApiConstants.moderationBlocks);
    final data = response.data as Map<String, dynamic>;
    final blocks = data['blocks'] as List<dynamic>? ?? const [];
    return blocks
        .map((e) => BlockedUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<void> unblock(String blockId) async {
    await _apiClient.dio.delete(ApiConstants.moderationBlock(blockId));
  }
}
