import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/services/auth_diagnostics_service.dart';
import '../../../../core/services/storage_service.dart';

/// PROD-2095 — Generates a UUID v4 per request, sets `X-Request-ID` on the
/// outbound headers, and fires the `request.about_to_dispatch` Sentry
/// breadcrumb BEFORE any auth decision runs.
///
/// **Wiring rules** (Decision 8 + Decision 10 in
/// `docs/investigations/ignore--auth-visibility-plan.md`):
///
/// 1. Must run BEFORE [AuthInterceptor] so the breadcrumb fires for public
///    endpoints (phone/start, phone/verify, guest, etc.). `AuthInterceptor`
///    short-circuits those — if the breadcrumb lives there, Diana-class
///    login wedges never produce one.
/// 2. Must also be wired into the [RefreshCoordinator]'s dedicated refresh
///    Dio, because `/auth/refresh` bypasses the main interceptor stack. Without
///    that, the backend cannot correlate refresh calls via `X-Request-ID`.
///
/// The `request_id` is also written to `options.extra[requestIdExtraKey]` so
/// downstream interceptors and the response path can thread it into their
/// own breadcrumbs.
class RequestIdInterceptor extends Interceptor {
  static const String requestIdHeader = 'X-Request-ID';
  static const String requestIdExtraKey = 'request_id';

  final StorageService _storageService;
  final AuthDiagnosticsService _diagnostics;
  final bool Function() _isRefreshInflight;
  final int Function() _refreshQueueDepth;
  final Uuid _uuid;

  RequestIdInterceptor({
    required StorageService storageService,
    required AuthDiagnosticsService diagnostics,
    required bool Function() isRefreshInflight,
    required int Function() refreshQueueDepth,
    Uuid? uuid,
  }) : _storageService = storageService,
       _diagnostics = diagnostics,
       _isRefreshInflight = isRefreshInflight,
       _refreshQueueDepth = refreshQueueDepth,
       _uuid = uuid ?? const Uuid();

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // If a caller pre-set a request id (e.g., to correlate a retry with its
    // original), honor it. Otherwise generate one.
    final existing = options.headers[requestIdHeader] as String?;
    final requestId = (existing != null && existing.isNotEmpty)
        ? existing
        : _uuid.v4();

    options.headers[requestIdHeader] = requestId;
    options.extra[requestIdExtraKey] = requestId;

    // Compute breadcrumb fields. Best-effort — never block dispatch on a
    // storage read failure.
    bool hasAccessToken = false;
    int? accessTokenAgeS;
    // PROD-2236 — fingerprint the storage access token at dispatch time.
    // `AuthInterceptor` runs immediately after this and stamps the same
    // storage value as `Authorization: Bearer <token>`, so this fp is
    // what the BE will see for this request. Used to correlate FE
    // dispatch ↔ BE refusal in post-mortems.
    String accessTokenFingerprint = 'none';
    try {
      final token = await _storageService.getAccessToken();
      hasAccessToken = token != null && token.isNotEmpty;
      accessTokenFingerprint = refreshTokenFingerprint(token);
      final loginTimestamp = _storageService.getLoginTimestamp();
      if (loginTimestamp != null) {
        accessTokenAgeS = DateTime.now().difference(loginTimestamp).inSeconds;
      }
    } catch (_) {
      // Swallow — diagnostic fields only.
    }

    _diagnostics.logRequestAboutToDispatch(
      requestId: requestId,
      method: options.method,
      path: options.uri.path,
      resolvedBaseUrl: options.baseUrl,
      hasAccessToken: hasAccessToken,
      accessTokenAgeS: accessTokenAgeS,
      inflightRefresh: _isRefreshInflight(),
      queueDepth: _refreshQueueDepth(),
      accessTokenFingerprint: accessTokenFingerprint,
    );

    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    // Verify backend echoes the same request id we sent. Mismatch suggests
    // a proxy/middleware regenerated the header, which would break FE↔BE
    // correlation. Log only on mismatch to keep noise low.
    final sent = response.requestOptions.extra[requestIdExtraKey] as String?;
    final echoed =
        response.headers.value(requestIdHeader) ??
        response.headers.value(requestIdHeader.toLowerCase());
    if (sent != null && echoed != null && sent != echoed) {
      _diagnostics.logInterceptorEvent(
        'request_id.echo_mismatch',
        data: {
          'sent': sent,
          'echoed': echoed,
          'path': response.requestOptions.uri.path,
        },
      );
    }
    handler.next(response);
  }
}
