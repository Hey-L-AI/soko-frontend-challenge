import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../../../core/config/environment.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/services/app_group_bridge.dart';
import '../../../core/services/auth_diagnostics_service.dart';
import '../../../core/services/auth_event_service.dart';
import '../../../core/services/refresh_coordinator.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/services/token_refresh_service.dart';
import 'interceptors/accept_language_interceptor.dart';
import 'interceptors/auth_interceptor.dart';
import 'interceptors/error_interceptor.dart';
import 'interceptors/refresh_interceptor.dart';
import 'interceptors/request_id_interceptor.dart';
import 'interceptors/retry_interceptor.dart';
import 'interceptors/version_header_interceptor.dart';

/// API client configuration and factory
class ApiClient {
  final StorageService _storageService;
  final AuthEventService _authEventService;
  final TokenRefreshService _tokenRefreshService;
  final AuthDiagnosticsService _diagnostics;
  final RefreshCoordinator _refreshCoordinator;
  final CookieJar? _cookieJar;

  /// PROD-1979 — supplies the persisted `visitor_id` for guest re-mints
  /// triggered by the [RefreshInterceptor]. Optional so the API client
  /// still constructs in tests that don't wire attribution.
  final Future<String> Function()? _getVisitorId;

  /// PROD-2037 — supplies the normalized API locale code (one of
  /// `pt-PT`, `pt-BR`, `en`) for the [AcceptLanguageInterceptor]. Optional
  /// so the API client still constructs in tests that don't wire locale.
  final String? Function()? _getLocaleCode;
  late final Dio _dio;

  ApiClient({
    required StorageService storageService,
    required AuthEventService authEventService,
    required TokenRefreshService tokenRefreshService,
    required AuthDiagnosticsService diagnostics,
    required RefreshCoordinator refreshCoordinator,
    CookieJar? cookieJar,
    Future<String> Function()? getVisitorId,
    String? Function()? getLocaleCode,
  }) : _storageService = storageService,
       _authEventService = authEventService,
       _tokenRefreshService = tokenRefreshService,
       _diagnostics = diagnostics,
       _refreshCoordinator = refreshCoordinator,
       _getVisitorId = getVisitorId,
       _getLocaleCode = getLocaleCode,
       // Don't use cookie jar on web - browsers handle cookies automatically
       _cookieJar = kIsWeb ? null : (cookieJar ?? CookieJar()) {
    _dio = _createDioInstance();
    // Mirror the resolved base URL to the App Group so the iOS Share
    // Extension hits the same backend as the host app (staging/prod/ngrok).
    AppGroupBridge.instance.writeBaseUrl(EnvironmentConfig.baseUrl);
  }

  /// Get the configured Dio instance
  Dio get dio => _dio;

  /// Get the cookie jar for managing cookies (null on web)
  CookieJar? get cookieJar => _cookieJar;

  Dio _createDioInstance() {
    final dio = Dio(
      BaseOptions(
        baseUrl: EnvironmentConfig.baseUrl,
        connectTimeout: ApiConstants.defaultTimeout,
        receiveTimeout: ApiConstants.defaultTimeout,
        sendTimeout: ApiConstants.defaultTimeout,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          if (EnvironmentConfig.isDev) 'ngrok-skip-browser-warning': 'true',
        },
        // On web, let browser handle cookies automatically
        extra: kIsWeb ? {'withCredentials': true} : null,
      ),
    );

    // Add interceptors in order:

    // 1. RequestIdInterceptor (PROD-2095) — FIRST so it runs for ALL requests
    //    including public endpoints. AuthInterceptor short-circuits public
    //    paths (phone/start, phone/verify, guest), so if request.about_to_dispatch
    //    lived there, Diana-class login wedges wouldn't produce a breadcrumb.
    //    Placing it first ensures every outbound request gets X-Request-ID
    //    and a dispatch breadcrumb.
    dio.interceptors.add(
      RequestIdInterceptor(
        storageService: _storageService,
        diagnostics: _diagnostics,
        isRefreshInflight: () => _refreshCoordinator.isRefreshing,
        refreshQueueDepth: () => _refreshCoordinator.awaiterCount,
      ),
    );

    // 1.5. VersionHeaderInterceptor (PROD-2131) — stamps X-App-Version on
    //      every outbound request so backend auth_diag logs can pair with
    //      the build that produced them. Cached after the first
    //      PackageInfo.fromPlatform() resolves (~5-10ms).
    dio.interceptors.add(VersionHeaderInterceptor());

    // 2. Cookie manager (handles refresh token cookie) - only on mobile
    if (!kIsWeb && _cookieJar != null) {
      dio.interceptors.add(CookieManager(_cookieJar));
    }

    // 3. Accept-Language interceptor (PROD-2037): mirrors the app's chosen
    // locale into every outgoing request so the backend's locale-detection
    // path doesn't default to "en" and bounce that back into the client.
    final getLocale = _getLocaleCode;
    if (getLocale != null) {
      dio.interceptors.add(AcceptLanguageInterceptor(getLocaleCode: getLocale));
    }

    // 4. Auth interceptor (adds Bearer token)
    dio.interceptors.add(AuthInterceptor(storageService: _storageService));

    // 5. Refresh interceptor (handles 401 by delegating to the coordinator)
    dio.interceptors.add(
      RefreshInterceptor(
        dio: dio,
        storageService: _storageService,
        authEventService: _authEventService,
        tokenRefreshService: _tokenRefreshService,
        diagnostics: _diagnostics,
        coordinator: _refreshCoordinator,
        cookieJar: _cookieJar,
        getVisitorId: _getVisitorId,
      ),
    );

    // 5.5. Retry interceptor (B) — retries idempotent GETs on transient
    //      failures (timeout / connection / 5xx). MUST sit after refresh (so
    //      401s refresh first) and BEFORE the error interceptor (which
    //      `reject`s and would stop the error before this one's onError ran).
    dio.interceptors.add(RetryInterceptor(dio: dio));

    // 6. Error interceptor (transforms errors to typed exceptions).
    //    PROD-2264 — also broadcasts USER_SUSPENDED / USER_BANNED 403s
    //    via [AuthEventService] so the app shell can force-logout +
    //    route to the suspended-account screen.
    dio.interceptors.add(ErrorInterceptor(authEventService: _authEventService));

    // Verbose request/response logging in dev — opt-in via
    // `--dart-define=API_LOGS=true`. Off by default because the
    // ~10-15 `[API]` lines per call drown out actual app errors. The
    // [_RedactingLogInterceptor] masks `Authorization` so it's safe to
    // enable without leaking the bearer JWT into Sentry session-replay
    // (rrweb scrapes `console.log`).
    if (EnvironmentConfig.isDev && EnvironmentConfig.apiLogsEnabled) {
      dio.interceptors.add(_RedactingLogInterceptor());
    }

    return dio;
  }
}

/// Verbose request/response log interceptor for dev debugging. Mirrors
/// Dio's stock [LogInterceptor] but redacts the `Authorization` header so
/// the bearer JWT never lands in browser-console / Sentry-replay logs.
///
/// Off by default — gated behind `EnvironmentConfig.apiLogsEnabled`
/// (`--dart-define=API_LOGS=true`). The output is noisy (~10-15 lines
/// per call); enable only when actively debugging API traffic.
class _RedactingLogInterceptor extends Interceptor {
  static const _redacted = '*** redacted ***';

  void _log(Object? obj) {
    // ignore: avoid_print
    print('[API] $obj');
  }

  Map<String, dynamic> _redactedHeaders(Map<String, dynamic> headers) {
    final out = <String, dynamic>{};
    headers.forEach((k, v) {
      out[k] = k.toLowerCase() == 'authorization' ? _redacted : v;
    });
    return out;
  }

  void _printHeaders(Map<String, dynamic> headers) {
    _redactedHeaders(headers).forEach((k, v) => _log(' $k: $v'));
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _log('*** Request ***');
    _log('uri: ${options.uri}');
    _log('method: ${options.method}');
    _log('responseType: ${options.responseType}');
    _log('followRedirects: ${options.followRedirects}');
    _log('persistentConnection: ${options.persistentConnection}');
    _log('connectTimeout: ${options.connectTimeout}');
    _log('sendTimeout: ${options.sendTimeout}');
    _log('receiveTimeout: ${options.receiveTimeout}');
    _log('receiveDataWhenStatusError: ${options.receiveDataWhenStatusError}');
    _log('extra: ${options.extra}');
    _log('headers:');
    _printHeaders(options.headers);
    _log('data:');
    _log(options.data);
    _log('');
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _log('*** Response ***');
    _log('uri: ${response.requestOptions.uri}');
    _log('statusCode: ${response.statusCode}');
    _log('headers:');
    response.headers.forEach((k, list) {
      final value = k.toLowerCase() == 'authorization'
          ? _redacted
          : list.join(', ');
      _log(' $k: $value');
    });
    _log('Response Text:');
    _log(response.data);
    _log('');
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _log('*** DioException ***:');
    _log('uri: ${err.requestOptions.uri}');
    _log('$err');
    final response = err.response;
    if (response != null) {
      _log('statusCode: ${response.statusCode}');
      _log('headers:');
      response.headers.forEach((k, list) {
        final value = k.toLowerCase() == 'authorization'
            ? _redacted
            : list.join(', ');
        _log(' $k: $value');
      });
      _log('Response Text:');
      _log(response.data);
    }
    _log('');
    handler.next(err);
  }
}
