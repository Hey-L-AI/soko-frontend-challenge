/// Generic error response
class ErrorResponse {
  final String detail;

  const ErrorResponse({required this.detail});

  factory ErrorResponse.fromJson(Map<String, dynamic> json) {
    return ErrorResponse(detail: json['detail'] as String? ?? 'Unknown error');
  }
}

/// Generic message response
class MessageResponse {
  final String message;

  const MessageResponse({required this.message});

  factory MessageResponse.fromJson(Map<String, dynamic> json) {
    return MessageResponse(message: json['message'] as String);
  }
}

/// Login response with token expiry information
class LoginResponse {
  final Map<String, dynamic> user;
  final String accessToken;
  final String tokenType;
  final int? expiresIn;
  final DateTime? expiresAt;
  final String? refreshToken;
  final String? refreshTokenExpiresAt;

  /// PROD-2137: `true` only when this call created a new account. The backend
  /// sets it on the login-style endpoints that can also register
  /// (`/auth/google/token`, `/auth/apple/token`, `/auth/phone/verify`);
  /// linking an OAuth provider onto an existing email user stays `false`.
  /// Lets the client fire signup-only analytics (`fb_mobile_complete_registration`)
  /// on OAuth/phone signups instead of only email register. Defaults `false`.
  final bool isNewUser;

  /// PROD-4040 T2.4: the backend echoes the validated, allowlisted Business
  /// Connect return target here when the login carried a `return_to`/
  /// `claim_intent` (e.g. an owner who logged in from a public business link).
  /// The client navigates here after it holds the tokens; null for ordinary
  /// logins. Metadata only — never a security boundary on its own.
  final String? businessReturnTo;

  const LoginResponse({
    required this.user,
    required this.accessToken,
    required this.tokenType,
    this.expiresIn,
    this.expiresAt,
    this.refreshToken,
    this.refreshTokenExpiresAt,
    this.isNewUser = false,
    this.businessReturnTo,
  });

  factory LoginResponse.fromJson(Map<String, dynamic> json) {
    DateTime? expiresAt;
    if (json['expires_at'] != null) {
      expiresAt = DateTime.parse(json['expires_at'] as String);
    }

    return LoginResponse(
      user: json['user'] as Map<String, dynamic>,
      accessToken: json['access_token'] as String,
      tokenType: json['token_type'] as String? ?? 'bearer',
      expiresIn: json['expires_in'] as int?,
      expiresAt: expiresAt,
      refreshToken: json['refresh_token'] as String?,
      refreshTokenExpiresAt: json['refresh_token_expires_at'] as String?,
      isNewUser: json['is_new_user'] as bool? ?? false,
      businessReturnTo: json['business_return_to'] as String?,
    );
  }
}

/// Response from `POST /auth/phone/start` (PROD-2609).
///
/// `status` is always one of:
/// * `sent` — request accepted; client navigates to the OTP screen
/// * `region_unsupported` — destination country isn't served (PROD-2610);
///   client surfaces email/social fallback
/// * `channel_unavailable` — the requested channel (typically WhatsApp)
///   can't reach this recipient; client offers SMS retry if
///   [smsFallbackAvailable] is true, else email/social fallback
///
/// All three statuses arrive as 200 OK in the same response shape — there
/// are no new 4xx error codes to parse.
class PhoneStartResponse {
  static const statusSent = 'sent';
  static const statusRegionUnsupported = 'region_unsupported';
  static const statusChannelUnavailable = 'channel_unavailable';

  static const channelSms = 'sms';
  static const channelWhatsapp = 'whatsapp';

  final String status;
  final String channel;
  final bool smsFallbackAvailable;

  const PhoneStartResponse({
    required this.status,
    required this.channel,
    required this.smsFallbackAvailable,
  });

  factory PhoneStartResponse.fromJson(Map<String, dynamic> json) {
    return PhoneStartResponse(
      status: json['status'] as String? ?? statusSent,
      channel: json['channel'] as String? ?? channelWhatsapp,
      smsFallbackAvailable: json['sms_fallback_available'] as bool? ?? false,
    );
  }
}

/// Response from `POST /api/v1/auth/email/login/start` (PROD-3595).
///
/// Passwordless email-OTP login — the email fallback rung of the phone-login
/// channel ladder. The response is deliberately generic: it always carries
/// `status: "sent"` whether or not the email maps to an account
/// (anti-enumeration), and upstream Twilio/SendGrid send failures are swallowed
/// into the same shape. A rate-limit hit surfaces as a `429`, not in this body.
class EmailLoginStartResponse {
  static const statusSent = 'sent';

  final String status;

  const EmailLoginStartResponse({required this.status});

  factory EmailLoginStartResponse.fromJson(Map<String, dynamic> json) {
    return EmailLoginStartResponse(
      status: json['status'] as String? ?? statusSent,
    );
  }
}

/// Support info response (matches OpenAPI SupportInfoResponse schema)
class SupportInfo {
  final String email;
  final String? whatsapp;
  final String hours;
  final String responseTime;

  const SupportInfo({
    required this.email,
    this.whatsapp,
    required this.hours,
    required this.responseTime,
  });

  factory SupportInfo.fromJson(Map<String, dynamic> json) {
    return SupportInfo(
      email: json['email'] as String,
      whatsapp: json['whatsapp'] as String?,
      hours: json['hours'] as String,
      responseTime: json['response_time'] as String,
    );
  }
}

/// Delete account request
class DeleteAccountRequest {
  final String confirmation;

  const DeleteAccountRequest({required this.confirmation});

  Map<String, dynamic> toJson() => {'confirmation': confirmation};
}

/// Session list response
class SessionListResponse {
  final List<Map<String, dynamic>> items;
  final String? nextCursor;

  const SessionListResponse({required this.items, this.nextCursor});

  factory SessionListResponse.fromJson(Map<String, dynamic> json) {
    return SessionListResponse(
      items: (json['items'] as List<dynamic>).cast<Map<String, dynamic>>(),
      nextCursor: json['next_cursor'] as String?,
    );
  }

  bool get hasMore => nextCursor != null;
}

/// Session detail response
class SessionDetailResponse {
  final Map<String, dynamic> session;
  final List<Map<String, dynamic>> messages;
  final String? nextCursor;

  const SessionDetailResponse({
    required this.session,
    required this.messages,
    this.nextCursor,
  });

  factory SessionDetailResponse.fromJson(Map<String, dynamic> json) {
    return SessionDetailResponse(
      session: json['session'] as Map<String, dynamic>,
      messages: (json['messages'] as List<dynamic>)
          .cast<Map<String, dynamic>>(),
      nextCursor: json['next_cursor'] as String?,
    );
  }
}

// ============================================================================
// Email/Password Auth Responses
// ============================================================================

/// Registration response with token expiry information (same structure as LoginResponse but 201)
class RegisterResponse {
  final Map<String, dynamic> user;
  final String accessToken;
  final String tokenType;
  final int? expiresIn;
  final DateTime? expiresAt;
  final String? refreshToken;
  final String? refreshTokenExpiresAt;

  const RegisterResponse({
    required this.user,
    required this.accessToken,
    required this.tokenType,
    this.expiresIn,
    this.expiresAt,
    this.refreshToken,
    this.refreshTokenExpiresAt,
  });

  factory RegisterResponse.fromJson(Map<String, dynamic> json) {
    DateTime? expiresAt;
    if (json['expires_at'] != null) {
      expiresAt = DateTime.parse(json['expires_at'] as String);
    }

    return RegisterResponse(
      user: json['user'] as Map<String, dynamic>,
      accessToken: json['access_token'] as String,
      tokenType: json['token_type'] as String? ?? 'bearer',
      expiresIn: json['expires_in'] as int?,
      expiresAt: expiresAt,
      refreshToken: json['refresh_token'] as String?,
      refreshTokenExpiresAt: json['refresh_token_expires_at'] as String?,
    );
  }
}

/// PROD-1979 — stateless guest session minted from `visitor_id`.
///
/// Returned by `POST /api/v1/auth/guest`. The JWT has `sub="guest:<visitor_id>"`,
/// `role="guest"`, and a 24 h TTL. No DB row, no refresh cookie — the FE
/// re-mints on 401. Real-user endpoints reject this token with a
/// guest-specific 401 (`error_code: AUTH_TOKEN_INVALID`,
/// message tells the caller to sign in).
class GuestSessionResponse {
  final String accessToken;
  final String tokenType;
  final int? expiresIn;
  final DateTime? expiresAt;
  final String visitorId;

  const GuestSessionResponse({
    required this.accessToken,
    required this.tokenType,
    required this.visitorId,
    this.expiresIn,
    this.expiresAt,
  });

  factory GuestSessionResponse.fromJson(Map<String, dynamic> json) {
    DateTime? expiresAt;
    if (json['expires_at'] != null) {
      expiresAt = DateTime.parse(json['expires_at'] as String);
    }
    return GuestSessionResponse(
      accessToken: json['access_token'] as String,
      tokenType: json['token_type'] as String? ?? 'bearer',
      expiresIn: json['expires_in'] as int?,
      expiresAt: expiresAt,
      visitorId: json['visitor_id'] as String,
    );
  }
}

/// Token refresh response
class RefreshResponse {
  final String accessToken;
  final String tokenType;
  final int? expiresIn;
  final DateTime? expiresAt;
  final String? refreshToken;
  final String? refreshTokenExpiresAt;

  const RefreshResponse({
    required this.accessToken,
    required this.tokenType,
    this.expiresIn,
    this.expiresAt,
    this.refreshToken,
    this.refreshTokenExpiresAt,
  });

  factory RefreshResponse.fromJson(Map<String, dynamic> json) {
    DateTime? expiresAt;
    if (json['expires_at'] != null) {
      expiresAt = DateTime.parse(json['expires_at'] as String);
    }

    return RefreshResponse(
      accessToken: json['access_token'] as String,
      tokenType: json['token_type'] as String? ?? 'bearer',
      expiresIn: json['expires_in'] as int?,
      expiresAt: expiresAt,
      refreshToken: json['refresh_token'] as String?,
      refreshTokenExpiresAt: json['refresh_token_expires_at'] as String?,
    );
  }
}

/// Structured 401 authentication error response
class AuthErrorResponse {
  final String error;
  final String errorCode;
  final bool refreshable;
  final String message;

  const AuthErrorResponse({
    required this.error,
    required this.errorCode,
    required this.refreshable,
    required this.message,
  });

  factory AuthErrorResponse.fromJson(Map<String, dynamic> json) {
    return AuthErrorResponse(
      error: json['error'] as String? ?? 'unknown',
      errorCode: json['error_code'] as String? ?? 'AUTH_UNKNOWN',
      refreshable: json['refreshable'] as bool? ?? false,
      message: json['message'] as String? ?? 'Authentication failed',
    );
  }

  /// Check if this error indicates the token can be refreshed
  bool get canRefresh => refreshable;

  /// Check if this error indicates the token has expired (and is refreshable)
  bool get isTokenExpired => errorCode == 'AUTH_TOKEN_EXPIRED';

  /// Check if this error indicates the session was revoked (must re-login)
  bool get isSessionRevoked => errorCode == 'AUTH_SESSION_REVOKED';

  /// Check if this error indicates an invalid token (must re-login)
  bool get isTokenInvalid => errorCode == 'AUTH_TOKEN_INVALID';
}

/// Account activation response
class ActivationResponse {
  final String message;
  final String email;

  const ActivationResponse({required this.message, required this.email});

  factory ActivationResponse.fromJson(Map<String, dynamic> json) {
    return ActivationResponse(
      message: json['message'] as String,
      email: json['email'] as String,
    );
  }
}

/// Resend activation email response
class ResendActivationResponse {
  final String message;
  final String email;

  const ResendActivationResponse({required this.message, required this.email});

  factory ResendActivationResponse.fromJson(Map<String, dynamic> json) {
    return ResendActivationResponse(
      message: json['message'] as String,
      email: json['email'] as String,
    );
  }
}

/// Forgot password response
class ForgotPasswordResponse {
  final String message;

  const ForgotPasswordResponse({required this.message});

  factory ForgotPasswordResponse.fromJson(Map<String, dynamic> json) {
    return ForgotPasswordResponse(message: json['message'] as String);
  }
}

/// Reset password response
class ResetPasswordResponse {
  final String message;

  const ResetPasswordResponse({required this.message});

  factory ResetPasswordResponse.fromJson(Map<String, dynamic> json) {
    return ResetPasswordResponse(message: json['message'] as String);
  }
}

/// Pending search response for referral links
class PendingSearchResponse {
  final String? searchQuery;
  final bool autoExecute;
  final String? referralSlug;

  const PendingSearchResponse({
    this.searchQuery,
    this.autoExecute = false,
    this.referralSlug,
  });

  factory PendingSearchResponse.fromJson(Map<String, dynamic> json) {
    return PendingSearchResponse(
      searchQuery: json['search_query'] as String?,
      autoExecute: json['auto_execute'] as bool? ?? false,
      referralSlug: json['referral_slug'] as String?,
    );
  }

  /// Check if this response has a valid search to execute
  bool get hasValidSearch => searchQuery != null && autoExecute;
}
