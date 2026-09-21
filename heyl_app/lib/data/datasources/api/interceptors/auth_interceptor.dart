import 'package:dio/dio.dart';

import '../../../../core/constants/api_constants.dart';
import '../../../../core/services/storage_service.dart';

/// Interceptor that attaches Bearer token to authenticated requests
class AuthInterceptor extends Interceptor {
  final StorageService _storageService;

  AuthInterceptor({required StorageService storageService})
    : _storageService = storageService;

  /// Endpoints that don't require authentication (exact match)
  static const _publicEndpoints = [
    ApiConstants.authPhoneStart,
    ApiConstants.authPhoneVerify,
    // PROD-1979 — the guest-session mint itself is unauthenticated, so
    // we skip attaching any (possibly stale) bearer on the way out. The
    // refresh interceptor also funnels expired guest tokens through this
    // endpoint to mint a fresh one.
    ApiConstants.authGuest,
    ApiConstants.support,
    ApiConstants.attributionTouchpoint,
    ApiConstants.guestSuggestedLists,
    ApiConstants.curatedLists,
    ApiConstants.whatsappNumbers,
  ];

  /// Patterns for public endpoints (regex match)
  /// These endpoints allow unauthenticated access (no token sent)
  static final _publicEndpointPatterns = [
    // Public list endpoints: /api/v1/app/lists/{list_id}/public
    RegExp(r'/api/v1/app/lists/[^/]+/public$'),
    // Public list items: /api/v1/app/lists/{list_id}/public/items
    RegExp(r'/api/v1/app/lists/[^/]+/public/items'),
  ];

  /// Patterns for optional-auth endpoints (regex match)
  /// These support both authenticated and guest access
  /// Token is sent if available, but requests proceed without it
  /// Note: This list is intentionally unused - it serves as documentation for
  /// which endpoints support guest mode. The default interceptor behavior
  /// (add token if present, proceed without if not) is correct for these.
  // ignore: unused_field
  static final _optionalAuthEndpointPatterns = [
    // Guest mode: Session endpoints (POST /sessions, GET /sessions/{id})
    RegExp(r'/api/v1/app/sessions$'),
    RegExp(r'/api/v1/app/sessions/[^/]+$'),
    // Guest mode: Message endpoints (POST /sessions/{id}/messages, :image, :voice)
    RegExp(r'/api/v1/app/sessions/[^/]+/messages$'),
    RegExp(r'/api/v1/app/sessions/[^/]+/messages:image$'),
    RegExp(r'/api/v1/app/sessions/[^/]+/messages:voice$'),
    // Guest mode: Message stream endpoint
    RegExp(r'/api/v1/app/sessions/[^/]+/messages/[^/]+/stream$'),
  ];

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Skip auth header for public endpoints
    if (_isPublicEndpoint(options.path)) {
      return handler.next(options);
    }

    // Get token and attach to request
    final token = await _storageService.getAccessToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }

    handler.next(options);
  }

  /// Check if the path matches a public endpoint
  bool _isPublicEndpoint(String path) {
    // Remove base URL if present
    final cleanPath = path.replaceFirst(RegExp(r'^https?://[^/]+'), '');

    // Check exact matches
    for (final endpoint in _publicEndpoints) {
      if (cleanPath == endpoint || cleanPath.endsWith(endpoint)) {
        return true;
      }
    }

    // Check pattern matches
    for (final pattern in _publicEndpointPatterns) {
      if (pattern.hasMatch(cleanPath)) {
        return true;
      }
    }

    return false;
  }
}
