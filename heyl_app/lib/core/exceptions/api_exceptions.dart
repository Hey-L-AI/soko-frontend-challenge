/// Base exception for API errors
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final dynamic data;

  ApiException(this.message, {this.statusCode, this.data});

  @override
  String toString() => 'ApiException: $message (status: $statusCode)';
}

/// Exception thrown when authentication fails (401)
class AuthenticationException extends ApiException {
  AuthenticationException([String message = 'Authentication failed'])
    : super(message, statusCode: 401);

  @override
  String toString() => 'AuthenticationException: $message';
}

/// Exception thrown when rate limited (429)
class RateLimitException extends ApiException {
  final int retryAfterSeconds;

  RateLimitException({
    this.retryAfterSeconds = 60,
    String message = 'Rate limit exceeded',
  }) : super(message, statusCode: 429);

  @override
  String toString() =>
      'RateLimitException: $message (retry after ${retryAfterSeconds}s)';
}

/// Exception thrown on gateway timeout (504)
class GatewayTimeoutException extends ApiException {
  GatewayTimeoutException([String message = 'Gateway timeout - please retry'])
    : super(message, statusCode: 504);

  @override
  String toString() => 'GatewayTimeoutException: $message';
}

/// Exception thrown on validation errors (400/422)
class ValidationException extends ApiException {
  final Map<String, dynamic>? errors;

  ValidationException(String message, {this.errors})
    : super(message, statusCode: 422);

  @override
  String toString() => 'ValidationException: $message';
}

/// Exception thrown when resource not found (404)
class NotFoundException extends ApiException {
  NotFoundException([String message = 'Resource not found'])
    : super(message, statusCode: 404);

  @override
  String toString() => 'NotFoundException: $message';
}

/// Exception thrown on network/connectivity errors
class NetworkException extends ApiException {
  NetworkException([String message = 'Network error - check your connection'])
    : super(message);

  @override
  String toString() => 'NetworkException: $message';
}

/// Exception thrown when account is not activated (403)
class AccountNotActivatedException extends ApiException {
  final String? email;

  AccountNotActivatedException({
    String message = 'Account not activated. Please check your email.',
    this.email,
  }) : super(message, statusCode: 403);

  @override
  String toString() => 'AccountNotActivatedException: $message';
}

/// Exception thrown when email already exists (409)
class EmailExistsException extends ApiException {
  EmailExistsException([String message = 'Email already registered'])
    : super(message, statusCode: 409);

  @override
  String toString() => 'EmailExistsException: $message';
}

/// Exception thrown when a resource is requested before its preconditions are
/// met (409) — e.g. onboarding preliminary zines fetched before the user's
/// interests are persisted. Distinct from [EmailExistsException] so callers can
/// treat it as a transient "not ready yet" and retry instead of erroring.
class NotReadyException extends ApiException {
  NotReadyException([String message = 'Not ready yet'])
    : super(message, statusCode: 409);

  @override
  String toString() => 'NotReadyException: $message';
}

/// Exception thrown when password doesn't meet requirements (400)
class WeakPasswordException extends ApiException {
  WeakPasswordException([
    String message = 'Password does not meet requirements',
  ]) : super(message, statusCode: 400);

  @override
  String toString() => 'WeakPasswordException: $message';
}

/// Exception thrown when activation/reset token is invalid (400)
class InvalidTokenException extends ApiException {
  InvalidTokenException([String message = 'Invalid or expired token'])
    : super(message, statusCode: 400);

  @override
  String toString() => 'InvalidTokenException: $message';
}

/// PROD-2264 — thrown when the backend's wordlist filter rejects a piece
/// of user-authored content on input (400 + body
/// `{detail: {error: content_blocked, error_code: CONTENT_BLOCKED, message}}`).
///
/// [userMessage] is the human-readable copy returned by the backend (already
/// localized server-side). Render it directly when non-empty; fall back to
/// the localized `moderationContentBlockedFallback` / `…NameFallback`
/// strings when it's missing.
///
/// Use [tryFrom] at callsites — it accepts the raw error from a
/// `catch (e)` block and unwraps either a bare [ContentBlockedException]
/// or a Dio-wrapped one (`DioException.error`). Returns null when the
/// error is something else.
class ContentBlockedException extends ApiException {
  final String userMessage;

  ContentBlockedException(this.userMessage)
    : super(userMessage, statusCode: 400);

  /// Extracts a [ContentBlockedException] from any thrown object. Returns
  /// null if [error] is not (and does not wrap) one. Mirrors the existing
  /// `e.error is X` unwrap pattern used in `account_provider.updateHandle`
  /// and `auth_provider.signUp` — extracted into one place so every
  /// callsite for content-blocked UX shares the same matcher.
  static ContentBlockedException? tryFrom(Object? error) {
    if (error is ContentBlockedException) return error;
    if (error is Object) {
      // Avoid importing dio here just to type-check; the interceptor
      // wraps typed exceptions in `DioException.error`, and that field
      // is `dynamic`. The runtimeType-name probe is intentional —
      // matches the pattern used by other lookup helpers in this layer
      // without introducing a cross-package dependency.
      try {
        final inner = (error as dynamic).error;
        if (inner is ContentBlockedException) return inner;
      } catch (_) {
        // Not a DioException-shaped object — fall through.
      }
    }
    return null;
  }

  @override
  String toString() => 'ContentBlockedException: $userMessage';
}

/// Thrown when the backend refuses to save an external place/event because it
/// isn't something we can hold — a street/area or a non-business
/// (`PLACE_NOT_SAVEABLE`), a closed/removed business (`PLACE_UNAVAILABLE`), or
/// a generic retryable failure (`SAVE_FAILED`). Backend body is
/// `400 {detail: {error, error_code, message}}` on `POST .../items` and
/// `POST .../me/saved`.
///
/// [errorCode] is the stable machine code the UI switches on to pick localized
/// copy; [userMessage] is the backend's English fallback (rendered only when no
/// localized string maps the code). Use [tryFrom] to unwrap it from a raw
/// `catch (e)` object or a Dio-wrapped one — mirrors [ContentBlockedException].
class PlaceSaveRejectedException extends ApiException {
  final String errorCode;
  final String userMessage;

  PlaceSaveRejectedException(this.errorCode, this.userMessage)
    : super(userMessage, statusCode: 400);

  static PlaceSaveRejectedException? tryFrom(Object? error) {
    if (error is PlaceSaveRejectedException) return error;
    if (error is Object) {
      try {
        final inner = (error as dynamic).error;
        if (inner is PlaceSaveRejectedException) return inner;
      } catch (_) {
        // Not a DioException-shaped object — fall through.
      }
    }
    return null;
  }

  @override
  String toString() => 'PlaceSaveRejectedException($errorCode): $userMessage';
}

/// 503 `IMAGE_MODERATION_UNAVAILABLE` from `POST /api/v1/app/contributions/events`
/// (PROD-2147 backend / PROD-2404 webapp): the Vision SafeSearch moderation
/// service couldn't screen the submitted image — a transient failure the
/// user should retry. Distinct from a permanent rejection
/// ([ContentBlockedException] for `CONTRIBUTION_IMAGE_CONTENT_REJECTED`),
/// which means the image WAS screened and refused.
class ImageModerationUnavailableException extends ApiException {
  final String userMessage;

  ImageModerationUnavailableException(this.userMessage)
    : super(userMessage, statusCode: 503);

  @override
  String toString() => 'ImageModerationUnavailableException: $userMessage';
}

/// 503 pool-saturation shed from the backend's load-shedding middleware
/// (PROD-4321 feed shed / PROD-4610 auth-path lookup / PROD-4608 admission
/// bound). The body carries a **flat, top-level** `error_code`
/// (`pool_saturated` | `feed_admission_saturated`) — a sibling of the string
/// `detail`, NOT the nested `detail.error_code` moderation shape — because it
/// comes from middleware / a global handler, not a route `HTTPException`.
///
/// This is a transient "server briefly overloaded" signal, distinct from a real
/// auth failure: callers must NOT log the user out, and the client must NOT
/// blindly re-send (that turned the 2026-09-09 shed into a 40-minute outage —
/// PROD-4369). [retryAfterSeconds] is the server's `Retry-After` when present,
/// so the UI can delay a manual Retry.
class PoolSaturatedException extends ApiException {
  /// `pool_saturated` or `feed_admission_saturated`.
  final String errorCode;

  /// The server's `Retry-After`, in seconds — null when the header was absent.
  final int? retryAfterSeconds;

  PoolSaturatedException({
    required this.errorCode,
    this.retryAfterSeconds,
    String message = 'Service briefly saturated - please retry',
  }) : super(message, statusCode: 503);

  @override
  String toString() =>
      'PoolSaturatedException($errorCode): $message '
      '(retry after ${retryAfterSeconds ?? "?"}s)';
}

/// Unwraps the typed [ApiException] the [ErrorInterceptor] tucks inside a
/// rejected `DioException.error`, so call sites can `on NotReadyException`
/// (etc.) and actually match (PROD-4394 F4).
///
/// The interceptor rejects with `DioException(error: <typed exception>)` — the
/// typed exception is the wrapper's payload, not the thrown object. Every
/// `on <TypedException> catch` that doesn't go through this helper silently
/// misses in production while passing in unit tests that throw the bare typed
/// exception (the zines 409 poll loop was dead in prod because of exactly
/// this). Returns the original error unchanged when there is nothing to unwrap.
Object unwrapApiError(Object error) {
  // Avoid importing dio here: match structurally on the `error` field so this
  // stays a pure-Dart helper usable from any layer.
  final dynamic err = error;
  try {
    final inner = err.error;
    if (inner is ApiException) return inner;
  } catch (_) {
    // Not a DioException-shaped object — nothing to unwrap.
  }
  return error;
}
