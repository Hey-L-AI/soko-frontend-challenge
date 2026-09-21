import 'package:flutter/foundation.dart';

/// Value for the `X-Client-Platform` request header (OpenAPI enum: web|ios|android).
///
/// Single source of truth for the header the backend uses to strip mobile-only
/// preference fields (`/me/preferences`) and to grant platform-aware refresh
/// lifetimes on `/auth/refresh` (365 days native, 30 days web — PROD-3931/3933).
///
/// Desktop is not a build target (CLAUDE.md: Web/iOS/Android only), so the
/// non-iOS native fallback of `android` is acceptable.
String clientPlatformHeader() {
  if (kIsWeb) return 'web';
  return defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
}
