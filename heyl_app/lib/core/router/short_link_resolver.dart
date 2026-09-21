import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Result of resolving a Short.io branded short link (PROD-2314).
///
/// Either [resolvedUrl] is non-null ([isSuccess] true) — the final
/// app-routable destination the redirect chain pointed at — or [failureKind]
/// describes why resolution failed so the caller can browser-fall-back and
/// emit a `deep_link.short_link_resolve_failed` analytics event.
@immutable
class ShortLinkResolution {
  const ShortLinkResolution._(this.resolvedUrl, this.failureKind);

  const ShortLinkResolution.success(Uri url) : this._(url, null);
  const ShortLinkResolution.failure(String kind) : this._(null, kind);

  /// The resolved final destination, or null on failure.
  final Uri? resolvedUrl;

  /// One of the [ShortLinkFailureKind] constants, or null on success.
  final String? failureKind;

  bool get isSuccess => resolvedUrl != null;
}

/// Stable error-kind tags emitted in the failure analytics event. Kept as a
/// small closed set so PostHog breakdowns stay clean.
abstract final class ShortLinkFailureKind {
  static const String timeout = 'timeout';
  static const String network = 'network';
  static const String httpError = 'http_error';
  static const String noLocation = 'no_location';
  static const String tooManyHops = 'too_many_hops';

  /// Not a resolver outcome: the same short URL was re-delivered within the
  /// `ShortLinkRelaunchGuard` window and the app refused to resolve or launch
  /// it again (short_link_fallback.dart). A non-zero count means the Android
  /// app-link bounce is still being attempted somewhere.
  static const String relaunchSuppressed = 'relaunch_suppressed';
}

/// Max redirect hops to follow before giving up. The expected chain is
/// Short.io → backend resolver → `app.soko.fyi/chat?…` (2 hops); 3 leaves
/// headroom for an extra Short.io-internal hop without risking a loop.
const int _kMaxHops = 3;

/// Hard wall-clock budget for the whole resolution. Cold launch is
/// timing-sensitive, so we never block routing for longer than this.
const Duration _kBudget = Duration(seconds: 3);

/// Hosts treated as the canonical terminal destination: a redirect pointing
/// here is returned immediately without fetching the page (it's the Flutter
/// web SPA, which 200s on any path). The backend emits `app.soko.fyi/chat?…`
/// as the final referral destination (PROD-2069 / PROD-2315). Any other chain
/// shape still terminates correctly via the non-redirect (2xx) branch.
const Set<String> _kTerminalHosts = {'app.soko.fyi'};

/// Resolve a tapped Short.io branded short link into its final destination.
///
/// Strategy (PROD-2314, "follow the Location chain"): GET the tapped URL with
/// redirects disabled, read the `Location` header, and repeat — resolving
/// relative redirects against the current URL — following EVERY redirect until
/// either a non-redirect (2xx) response (then the current URL is the final
/// destination) or a redirect that points at the canonical terminal host
/// `app.soko.fyi` (returned without fetching the SPA page). The expected chain
/// is `r.soko.fyi/<slug>` → `soko.fyi/api/v1/r/<slug>` → `app.soko.fyi/chat?…`:
/// note the intermediate `soko.fyi` hop is itself a redirect, so we must keep
/// following rather than stopping at the first non-short-link host. This is
/// correct regardless of whether Short.io's slugs match the backend's, because
/// we never assume the slug shape — we follow whatever the servers return,
/// exactly like a browser would.
///
/// Uses a bare [Dio] (not the app's authed `ApiClient`): the requests go to
/// soko.fyi / heyl.ai short-link hosts anonymously — we must not leak the
/// user's bearer token to them, and the authed client's `baseUrl` points at
/// the backend API, not these hosts.
///
/// Never throws. On any failure (network error, timeout, non-redirect/4xx/5xx,
/// missing/malformed `Location`, or exceeding [_kMaxHops]) returns a
/// [ShortLinkResolution.failure] so the caller can fall back to opening the
/// original URL in the browser.
///
/// [dio] is injectable for testing; defaults to a fresh anonymous client.
Future<ShortLinkResolution> resolveShortLink(Uri shortUri, {Dio? dio}) async {
  final client =
      dio ??
      Dio(
        BaseOptions(
          followRedirects: false,
          // Treat 3xx/4xx as normal responses we inspect, not as thrown errors.
          validateStatus: (_) => true,
          connectTimeout: _kBudget,
          receiveTimeout: _kBudget,
          sendTimeout: _kBudget,
        ),
      );

  try {
    return await _follow(client, shortUri).timeout(
      _kBudget,
      onTimeout: () =>
          const ShortLinkResolution.failure(ShortLinkFailureKind.timeout),
    );
  } finally {
    // Only dispose clients we created — a caller-supplied (mock) client is
    // theirs to manage.
    if (dio == null) client.close(force: true);
  }
}

/// PROD-4388 — hosts served by OUR backend rather than Short.io.
///
/// These cannot be resolved by following the `Location` chain, because the
/// route deliberately answers **200 with Open Graph tags** instead of a
/// redirect: a 302 would send link-preview crawlers on to the Flutter SPA
/// shell, which carries no per-subject meta — the whole bug PROD-4388 fixes.
///
/// [_follow] treats any 2xx as terminal, so it would hand back the
/// `share.soko.fyi/...` URL itself, which is not app-routable. So these hosts
/// go through the JSON resolve endpoint instead.
const Set<String> kFirstPartyShareHosts = {'share.soko.fyi'};

bool isFirstPartyShareHost(Uri uri) => kFirstPartyShareHosts.contains(uri.host);

/// Resolve a first-party share link (`share.soko.fyi/e/<slug>-<code>`) into the
/// app URL it points at, by asking the backend.
///
/// Only the trailing path segment is sent: the backend keys on the code at the
/// end and ignores the cosmetic slug, so a renamed subject still resolves. It
/// falls back to a handle lookup, which is how persona links resolve.
///
/// Note this does NOT follow the Short.io redirect. The chain would be
/// share.soko.fyi -> our Open Graph page (a 200, which [_follow] would treat as
/// terminal and hand back unroutable). Asking the backend directly is both
/// correct and one request shorter.
///
/// Uses a bare [Dio] like [resolveShortLink] — the endpoint is public and must
/// not receive the user's bearer token.
Future<ShortLinkResolution> resolveFirstPartyShareLink(
  Uri shareUri, {
  required String apiBaseUrl,
  required String webappUrl,
  Dio? dio,
}) async {
  // The branded link is one segment: `share.soko.fyi/<slug>-<code>`, or
  // `share.soko.fyi/<handle>` for a persona. The backend accepts either.
  final segments = shareUri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) {
    return const ShortLinkResolution.failure(ShortLinkFailureKind.noLocation);
  }
  final segment = segments.last;

  final client =
      dio ??
      Dio(
        BaseOptions(
          validateStatus: (_) => true,
          connectTimeout: _kBudget,
          receiveTimeout: _kBudget,
          sendTimeout: _kBudget,
        ),
      );

  try {
    final response = await client
        .getUri<Map<String, dynamic>>(
          Uri.parse('$apiBaseUrl/api/v1/app/links/$segment'),
        )
        .timeout(
          _kBudget,
          onTimeout: () => throw DioException.connectionTimeout(
            timeout: _kBudget,
            requestOptions: RequestOptions(path: ''),
          ),
        );

    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      if (kDebugMode) {
        debugPrint('[ShareLink] resolve returned $status for $shareUri');
      }
      return const ShortLinkResolution.failure(ShortLinkFailureKind.httpError);
    }

    final path = response.data?['deep_link_path'] as String?;
    if (path == null || path.isEmpty) {
      return const ShortLinkResolution.failure(ShortLinkFailureKind.noLocation);
    }
    return ShortLinkResolution.success(Uri.parse('$webappUrl$path'));
  } on DioException catch (e) {
    return ShortLinkResolution.failure(_kindForDioException(e));
  } catch (_) {
    return const ShortLinkResolution.failure(ShortLinkFailureKind.network);
  } finally {
    if (dio == null) client.close(force: true);
  }
}

Future<ShortLinkResolution> _follow(Dio client, Uri shortUri) async {
  var current = shortUri;

  for (var hop = 0; hop < _kMaxHops; hop++) {
    final Response<dynamic> response;
    try {
      response = await client.getUri(current);
    } on DioException catch (e) {
      return ShortLinkResolution.failure(_kindForDioException(e));
    }

    final status = response.statusCode ?? 0;
    final isRedirect = status >= 300 && status < 400;
    if (!isRedirect) {
      // A non-redirect response means `current` is the final URL: 2xx is the
      // destination; anything else (4xx/5xx) is a dead chain.
      if (status >= 200 && status < 300) {
        return ShortLinkResolution.success(current);
      }
      if (kDebugMode) {
        debugPrint('[ShortLink] non-redirect status $status for $current');
      }
      return const ShortLinkResolution.failure(ShortLinkFailureKind.httpError);
    }

    // Dio lowercases header names, so `location` matches any server casing.
    final location = response.headers.value('location');
    if (location == null || location.isEmpty) {
      return const ShortLinkResolution.failure(ShortLinkFailureKind.noLocation);
    }

    final Uri next;
    try {
      // Resolve relative redirects against the current URL.
      next = current.resolve(location);
    } catch (_) {
      return const ShortLinkResolution.failure(ShortLinkFailureKind.noLocation);
    }

    // Reached the canonical app destination — return without fetching the SPA.
    if (_kTerminalHosts.contains(next.host)) {
      return ShortLinkResolution.success(next);
    }

    current = next;
  }

  return const ShortLinkResolution.failure(ShortLinkFailureKind.tooManyHops);
}

String _kindForDioException(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.sendTimeout:
      return ShortLinkFailureKind.timeout;
    default:
      return ShortLinkFailureKind.network;
  }
}
