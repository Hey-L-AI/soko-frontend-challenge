import '../../../core/constants/api_constants.dart';
import '../../models/eula.dart';
import '../interfaces/eula_api.dart';
import 'api_client.dart';

/// Real HTTP implementation of [IEulaApi] (PROD-2264).
class EulaApi implements IEulaApi {
  final ApiClient _apiClient;

  EulaApi({required ApiClient apiClient}) : _apiClient = apiClient;

  @override
  Future<EulaAcceptance> accept(EulaAcceptRequest request) async {
    final response = await _apiClient.dio.post(
      ApiConstants.eulaAccept,
      data: request.toJson(),
    );
    return EulaAcceptance.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<EulaStatus> status() async {
    final response = await _apiClient.dio.get(ApiConstants.eulaMe);
    return EulaStatus.fromJson(response.data as Map<String, dynamic>);
  }
}
