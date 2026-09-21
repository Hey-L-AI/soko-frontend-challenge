import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/user_profile.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of WhatsApp API
class WhatsAppApi implements IWhatsAppApi {
  final ApiClient _apiClient;

  WhatsAppApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<List<WhatsAppNumber>> listNumbers() async {
    final response = await _dio.get(ApiConstants.whatsappNumbers);
    final data = response.data as Map<String, dynamic>;
    final numbers = (data['numbers'] as List<dynamic>?) ?? [];
    debugPrint('[WhatsAppApi] listNumbers response: ${numbers.length} numbers');
    return numbers
        .map((e) => WhatsAppNumber.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
