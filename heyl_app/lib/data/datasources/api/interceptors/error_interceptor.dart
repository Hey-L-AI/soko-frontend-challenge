import 'package:dio/dio.dart';

import '../../../../core/exceptions/api_exceptions.dart';
import '../../../../core/services/auth_event_service.dart';
import '../../../models/moderation.dart';
import 'retry_after.dart';

/// Interceptor that transforms Dio errors into typed exceptions.
///
/// PROD-2264 — also intercepts 403 [ModerationErrorResponse] bodies
/// (`error_code: USER_SUSPENDED | USER_BANNED`) and broadcasts
/// [AuthEvent.accountSuspended] so the app shell can force-logout +
/// route to the suspended-account landing screen. Distinct from the
/// 401 path so the client doesn't loop on token refresh.
class ErrorInterceptor extends Interceptor {
  final AuthEventService? _authEventService;

  ErrorInterceptor({AuthEventService? authEventService})
    : _authEventService = authEventService;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    // PROD-2264 — moderation 403 fires the suspension event before
    // mapping to a typed exception, so the app shell can react even
    // when no callsite happens to read the rejected future.
    if (err.response?.statusCode == 403) {
      final modError = ModerationError.tryParse(
        err.response?.data is Map<String, dynamic>
            ? err.response!.data as Map<String, dynamic>
            : null,
      );
      if (modError != null) {
        _authEventService?.notifyAccountSuspended();
      }
    }

    final exception = _transformError(err);

    // If we created a typed exception, reject with it
    // Otherwise, pass through the original error
    if (exception != null) {
      handler.reject(
        DioException(
          requestOptions: err.requestOptions,
          error: exception,
          type: err.type,
          response: err.response,
        ),
      );
    } else {
      handler.next(err);
    }
  }

  /// Transform DioException into typed ApiException
  ApiException? _transformError(DioException err) {
    // Handle connection errors
    if (err.type == DioExceptionType.connectionError ||
        err.type == DioExceptionType.connectionTimeout) {
      return NetworkException('Unable to connect to server');
    }

    // Handle timeout errors
    if (err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.sendTimeout) {
      return GatewayTimeoutException('Request timed out');
    }

    // Handle HTTP errors
    final statusCode = err.response?.statusCode;
    final data = err.response?.data;
    final detail = _extractDetail(data);

    switch (statusCode) {
      case 400:
        // PROD-2264 — UGC wordlist filter rejects input with body
        // `{detail: {error_code: CONTENT_BLOCKED, message, ...}}`.
        // PROD-2404 — contribution image content rejected by Vision
        // SafeSearch reuses the same exception type since the UI maps
        // both to a "content blocked" copy with the backend's
        // (already-localized) message.
        // Other 400s still flow through [ValidationException] unchanged.
        if (data is Map<String, dynamic>) {
          final rawDetail = data['detail'];
          if (rawDetail is Map<String, dynamic>) {
            final code = rawDetail['error_code'];
            if (code == 'CONTENT_BLOCKED' ||
                code == 'CONTRIBUTION_IMAGE_CONTENT_REJECTED') {
              return ContentBlockedException(
                (rawDetail['message'] as String?)?.trim() ?? '',
              );
            }
            // Backend refused to save an external place/event (a street/area,
            // a non-business, or a closed venue). The UI maps the code to
            // localized copy; keep the backend message as a fallback.
            if (code == 'PLACE_NOT_SAVEABLE' ||
                code == 'PLACE_UNAVAILABLE' ||
                code == 'SAVE_FAILED') {
              return PlaceSaveRejectedException(
                code as String,
                (rawDetail['message'] as String?)?.trim() ?? '',
              );
            }
          }
        }
        return ValidationException(detail ?? 'Invalid request');

      case 401:
        // Note: 401 is handled by RefreshInterceptor first
        // This is a fallback if refresh also fails
        return AuthenticationException(detail ?? 'Authentication required');

      case 403:
        // Check if this is an account not activated error
        if (detail != null &&
            (detail.toLowerCase().contains('not activated') ||
                detail.toLowerCase().contains('activate'))) {
          return AccountNotActivatedException(message: detail);
        }
        return ApiException(detail ?? 'Access denied', statusCode: 403);

      case 409:
        // Onboarding preliminary zines return 409 when the user's interests
        // aren't persisted yet (a not-ready race) — retryable, not a hard error.
        if (err.requestOptions.path.contains('/onboarding/preliminary-zines')) {
          return NotReadyException(detail ?? 'Zines not ready yet');
        }
        // Otherwise 409 means email already exists (from registration).
        return EmailExistsException(detail ?? 'Email already registered');

      case 404:
        return NotFoundException(detail ?? 'Resource not found');

      case 422:
        return ValidationException(
          detail ?? 'Validation failed',
          errors: data is Map<String, dynamic> ? data : null,
        );

      case 429:
        final retryAfter = _extractRetryAfter(err.response);
        return RateLimitException(
          retryAfterSeconds: retryAfter,
          message: detail ?? 'Too many requests',
        );

      case 500:
      case 502:
      case 503:
        // PROD-4369 / PROD-4321 — load-shedding middleware refuses a request
        // with `503` + a **flat, top-level** `error_code` (a sibling of the
        // string `detail`, since it comes from middleware / a global handler,
        // not a route HTTPException). Surface it as a typed, non-auth,
        // don't-retry-blindly exception carrying `Retry-After`. Checked BEFORE
        // the nested moderation shape below so the two `error_code` locations
        // (top-level vs `detail.error_code`) never cross-match.
        if (statusCode == 503 && data is Map<String, dynamic>) {
          final topLevelCode = data['error_code'];
          if (topLevelCode == 'pool_saturated' ||
              topLevelCode == 'feed_admission_saturated') {
            return PoolSaturatedException(
              errorCode: topLevelCode as String,
              retryAfterSeconds: retryAfterSeconds(err.response),
              message:
                  detail?.trim().isNotEmpty == true
                  ? detail!.trim()
                  : 'Service briefly saturated - please retry',
            );
          }
        }
        // PROD-2404 — Vision SafeSearch moderation service can be
        // transiently down on the contribution POST; the backend
        // signals this with `503 + IMAGE_MODERATION_UNAVAILABLE`.
        // Distinct from a permanent content rejection (400) — UI
        // copy is "we couldn't screen this image right now, try
        // again" with a retry CTA.
        if (statusCode == 503 && data is Map<String, dynamic>) {
          final rawDetail = data['detail'];
          if (rawDetail is Map<String, dynamic> &&
              rawDetail['error_code'] == 'IMAGE_MODERATION_UNAVAILABLE') {
            return ImageModerationUnavailableException(
              (rawDetail['message'] as String?)?.trim() ?? '',
            );
          }
        }
        return ApiException(
          detail ?? 'Server error - please try again',
          statusCode: statusCode,
        );

      case 504:
        return GatewayTimeoutException(detail ?? 'Gateway timeout');

      default:
        if (statusCode != null && statusCode >= 400) {
          return ApiException(
            detail ?? 'Request failed',
            statusCode: statusCode,
            data: data,
          );
        }
        return null;
    }
  }

  /// Extract error detail from response body
  String? _extractDetail(dynamic data) {
    if (data == null) return null;

    if (data is Map<String, dynamic>) {
      // Standard error format: {"detail": "message"}
      if (data.containsKey('detail')) {
        return data['detail']?.toString();
      }
      // Alternative format: {"message": "message"}
      if (data.containsKey('message')) {
        return data['message']?.toString();
      }
      // Alternative format: {"error": "message"}
      if (data.containsKey('error')) {
        return data['error']?.toString();
      }
    }

    if (data is String && data.isNotEmpty) {
      return data;
    }

    return null;
  }

  /// Extract Retry-After seconds for the 429 [RateLimitException], with the
  /// rate-limit-specific fallbacks the shared [retryAfterSeconds] parser does
  /// not carry: an `X-RateLimit-Reset` Unix timestamp, then a 60 s default.
  int _extractRetryAfter(Response? response) {
    if (response == null) return 60;

    final fromHeader = retryAfterSeconds(response);
    if (fromHeader != null) return fromHeader;

    // Try X-RateLimit-Reset header (Unix timestamp)
    final resetAt = response.headers.value('x-ratelimit-reset');
    if (resetAt != null) {
      final resetTimestamp = int.tryParse(resetAt);
      if (resetTimestamp != null) {
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        return (resetTimestamp - now).clamp(1, 3600);
      }
    }

    return 60; // Default to 60 seconds
  }
}
