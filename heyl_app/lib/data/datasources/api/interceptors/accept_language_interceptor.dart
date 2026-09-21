import 'package:dio/dio.dart';

/// Adds an `Accept-Language` header to every outgoing Dio request, sourced
/// from a callback that reads the app's current locale.
///
/// PROD-2037: without this header, the backend's
/// `detect_locale_from_accept_language` falls back to `"en"`, the user is
/// persisted with `preferred_locale = "en"` on register, and the next
/// `currentUserProvider` change triggers `syncFromProfile("en")` which
/// silently overrides the user's pre-auth language pick.
///
/// The callback returns a locale code already normalized to the backend's
/// supported set (`pt-PT`, `pt-BR`, `es-MX`, `en`) via `normalizeToApiLocale` —
/// sending raw values like `pt` or `en-US` would round-trip to the EN
/// default and re-introduce the same override.
class AcceptLanguageInterceptor extends Interceptor {
  AcceptLanguageInterceptor({required this.getLocaleCode});

  final String? Function() getLocaleCode;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final code = getLocaleCode();
    if (code != null && code.isNotEmpty) {
      options.headers['Accept-Language'] = code;
    }
    handler.next(options);
  }
}
