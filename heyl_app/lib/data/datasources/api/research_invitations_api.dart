import 'package:dio/dio.dart';

import '../../../core/config/research_invitation.dart';
import '../../models/research_invitation_status.dart';
import 'interceptors/retry_interceptor.dart';

/// Own-user status/events from PROD-4390. Requests are cancelled on identity
/// changes, including requests waiting in the shared client's refresh queue.
class ResearchInvitationsApi {
  ResearchInvitationsApi({
    required Dio dio,
    required String? Function() currentAccountId,
  }) : _dio = dio,
       _currentAccountId = currentAccountId;

  final Dio _dio;
  final String? Function() _currentAccountId;
  final _pending = <CancelToken>{};

  void cancelPending() {
    for (final token in _pending.toList()) {
      token.cancel('Research invitation identity changed');
    }
  }

  Future<ResearchInvitationStatus> status(String accountId) => _request(
    accountId,
    (token) => _dio.get(
      '/api/v1/app/research-invitations/${ResearchInvitation.campaign}/status',
      cancelToken: token,
      options: Options(headers: {'Cache-Control': 'no-cache'}),
    ),
  );

  Future<ResearchInvitationStatus> record(
    String accountId, {
    required ResearchInvitationAction action,
    required ResearchOffer offer,
    required int revision,
  }) => _request(
    accountId,
    (token) => _dio.post(
      '/api/v1/app/research-invitations/${ResearchInvitation.campaign}/events',
      data: {
        'action': action.apiValue,
        'variant': offer.flagValue,
        'revision': revision,
      },
      cancelToken: token,
      // Set-once timestamps and an immutable revision make this POST retry-safe.
      options: Options(extra: {RetryInterceptor.idempotentRetryKey: true}),
    ),
  );

  Future<ResearchInvitationStatus> _request(
    String accountId,
    Future<Response<dynamic>> Function(CancelToken) send,
  ) async {
    if (_currentAccountId() != accountId) {
      throw StateError('Research invitation account changed');
    }
    final token = CancelToken();
    _pending.add(token);
    try {
      final response = await send(token);
      if (token.isCancelled || _currentAccountId() != accountId) {
        throw StateError('Research invitation account changed');
      }
      final result = ResearchInvitationStatus.fromJson(
        response.data as Map<String, dynamic>,
      );
      if (result.campaignId != ResearchInvitation.campaign) {
        throw const FormatException('Research invitation campaign mismatch');
      }
      return result;
    } finally {
      _pending.remove(token);
    }
  }
}
