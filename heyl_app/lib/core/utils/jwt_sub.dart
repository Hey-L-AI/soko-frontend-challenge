import 'dart:convert';

/// PROD-1979 — decode a JWT's `sub` claim without verifying the
/// signature, and return true when it identifies a guest session
/// (i.e. the BE signed it with `sub="guest:<visitor_id>"`).
///
/// Used by both [AuthNotifier] (state-level flag, refresh skip) and
/// [RefreshInterceptor] (401 routing — guest tokens re-mint at
/// `POST /api/v1/auth/guest` instead of `/auth/refresh`).
///
/// Signature verification is the BE's job — tampered tokens get a 401
/// at the next request. This helper exists only to branch FE behaviour.
bool isGuestJwt(String? token) {
  if (token == null || token.isEmpty) return false;
  try {
    final parts = token.split('.');
    if (parts.length < 2) return false;
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final sub = (jsonDecode(payload) as Map<String, dynamic>)['sub'];
    return sub is String && sub.startsWith('guest:');
  } catch (_) {
    return false;
  }
}

/// Decode a JWT's `exp` claim without verifying the signature and return
/// true when the token is past its expiry.
///
/// Used by [RefreshInterceptor] to disambiguate two cases that both
/// surface as `AUTH_TOKEN_INVALID` for a guest token:
///   - the stored guest JWT has expired locally → re-mint and retry
///   - the guest token hit a real-user endpoint → propagate so the UI
///     routes the visitor to login
///
/// Returns false on any decode/parse error or when the `exp` claim is
/// missing — fail-soft, preserving the historical propagate-as-fatal
/// behaviour when expiry can't be determined.
bool isJwtExpired(String? token) {
  if (token == null || token.isEmpty) return false;
  try {
    final parts = token.split('.');
    if (parts.length < 2) return false;
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final exp = (jsonDecode(payload) as Map<String, dynamic>)['exp'];
    if (exp is! num) return false;
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return nowSeconds >= exp.toInt();
  } catch (_) {
    return false;
  }
}

/// PROD-2168 — decode a JWT's `exp` claim and return it as a [DateTime],
/// or null if the claim is missing or unparseable.
///
/// Used by [AuthNotifier.completeGoogleLogin] so the web OAuth callback
/// path can schedule proactive refresh. The OAuth redirect URL only
/// carries `access_token` (no `expires_at` query param — see OpenAPI
/// `/api/v1/auth/google/callback`), so we recover expiry by decoding
/// the JWT locally. Signature verification is the BE's job; we only
/// need the claim to time the next proactive refresh.
DateTime? jwtExpiryAt(String? token) {
  if (token == null || token.isEmpty) return null;
  try {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final exp = (jsonDecode(payload) as Map<String, dynamic>)['exp'];
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true);
  } catch (_) {
    return null;
  }
}
