import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'mock_data.dart';

/// Mock implementation of Account API
class MockAccountApi implements IAccountApi {
  /// Delete account
  Future<MessageResponse> deleteAccount(DeleteAccountRequest request) async {
    await _simulateDelay();

    if (request.confirmation != 'delete') {
      throw Exception('Confirmation must be "delete"');
    }

    return const MessageResponse(message: 'Account deletion requested');
  }

  /// Get support info
  Future<SupportInfo> getSupportInfo() async {
    await _simulateDelay(milliseconds: 200);
    return MockData.mockSupportInfo;
  }

  Future<void> _simulateDelay({int milliseconds = 300}) async {
    await Future.delayed(Duration(milliseconds: milliseconds));
  }
}
