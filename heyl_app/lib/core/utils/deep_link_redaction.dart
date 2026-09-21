/// Sanitises deep-link URLs before they hit analytics, logs, Sentry
/// breadcrumbs, Klaviyo tracking, or any other observability sink.
///
/// **Why:** several deep-link paths carry single-use secrets in their query
/// string — password-reset tokens (`/auth/reset-password?token=...`),
/// activation tokens (`/activate?token=...`), and OAuth access tokens
/// (`/auth/callback?access_token=...`). Logging the raw URL would expose
/// those tokens to analytics dashboards, debugging consoles, and any
/// third-party SDK that ingests events. See PROD-2054 Finding 20 and
/// Decision 29.
///
/// Use [redactDeepLinkForLogging] anywhere a deep-link URL is about to be
/// emitted into analytics or logs. UTM params and non-sensitive query
/// strings on entity paths (`/venues/abc?utm_source=push`) are preserved
/// unchanged.
library;

/// Path prefixes that carry sensitive tokens in their query string OR
/// fragment.
///
/// Matching is path-segment-aware: `/activate` matches `/activate` and
/// `/activate/foo` but NOT `/activate-injection`. Mirrors the AASA paths
/// list — every claimed auth path is treated as sensitive.
///
/// `/login` is included because the backend may redirect there with
/// `?access_token=...&refresh_token=...` (handled as an OAuth callback at
/// `app_router.dart:872-890`).
const Set<String> _sensitivePathPrefixes = {
  '/auth/callback',
  '/auth/activate',
  '/auth/reset-password',
  '/activate',
  '/reset-password',
  '/login',
};

bool _isSensitivePath(String path) {
  for (final prefix in _sensitivePathPrefixes) {
    if (path == prefix || path.startsWith('$prefix/')) {
      return true;
    }
  }
  return false;
}

/// Query parameter keys that carry long-lived secrets regardless of which
/// path they appear on. An attacker-crafted (or accidentally constructed)
/// URL like `/venues/abc?access_token=...` shouldn't bypass redaction
/// just because the path itself isn't on the sensitive list.
///
/// `code` is intentionally NOT here — it's a single-use OAuth grant code
/// that gets exchanged immediately, and the Instagram OAuth callback
/// (`/integrations/instagram?code=…&state=…`) is a legitimate observability
/// flow we want to keep visible.
const Set<String> _sensitiveQueryKeys = {
  'access_token',
  'refresh_token',
  'id_token',
  'token',
};

bool _hasSensitiveQueryKey(Uri uri) {
  if (uri.query.isEmpty) return false;
  return uri.queryParametersAll.keys.any(_sensitiveQueryKeys.contains);
}

/// For custom-scheme deep links (`soko://auth/callback`, `heyl://...`) the
/// host carries what HTTPS would call the first path segment. Normalise
/// so `_isSensitivePath` sees `/auth/callback` regardless of scheme.
String _effectivePath(Uri uri) {
  if (uri.scheme == 'soko' || uri.scheme == 'heyl') {
    final host = uri.host;
    final path = uri.path;
    return host.isEmpty ? path : '/$host$path';
  }
  return uri.path;
}

/// Returns a representation of [uri] safe to log OR safe to persist as
/// `returnUrlProvider`.
///
/// - Non-sensitive paths with no sensitive query keys (`/venues/...`,
///   `/lists/...`, `/integrations/...`) are returned unchanged (UTM params
///   + fragments preserved).
/// - Sensitive paths (auth/activate/reset/callback/login) keep their path,
///   scheme, and host but have BOTH the query string AND the fragment
///   replaced with `[redacted]`. OAuth's implicit-grant flow puts tokens
///   in `#access_token=…` fragments, so naïve fragment preservation would
///   leak credentials.
/// - Non-sensitive paths that nonetheless carry a sensitive query key
///   (`/venues/abc?access_token=…`) also get their query redacted —
///   tokens shouldn't leak just because the path looks innocuous.
/// - If the URL has nothing sensitive at all, the URL is returned unchanged.
///
/// Pass the result directly to analytics OR to `returnUrlProvider` /
/// `saveOAuthReturnUrl` — never `uri.toString()`.
String redactDeepLinkForLogging(Uri uri) {
  final pathHit = _isSensitivePath(_effectivePath(uri));
  final queryHit = _hasSensitiveQueryKey(uri);
  if (!pathHit && !queryHit) {
    return uri.toString();
  }
  if (uri.query.isEmpty && !uri.hasFragment) {
    return uri.toString();
  }

  final buf = StringBuffer();
  if (uri.hasScheme) {
    buf.write(uri.scheme);
    buf.write('://');
    if (uri.host.isNotEmpty) {
      buf.write(uri.host);
      if (uri.hasPort) {
        buf.write(':');
        buf.write(uri.port);
      }
    }
  }
  buf.write(uri.path);
  if (uri.query.isNotEmpty) {
    buf.write('?[redacted]');
  }
  // Fragments are only redacted on sensitive PATHS (OAuth implicit-grant
  // landing). A non-sensitive path that hits the query-key heuristic keeps
  // its fragment — the heuristic doesn't apply to fragments.
  if (uri.hasFragment) {
    if (pathHit) {
      buf.write('#[redacted]');
    } else {
      buf.write('#');
      buf.write(uri.fragment);
    }
  }
  return buf.toString();
}

/// Convenience overload for string inputs. Returns `[invalid-uri]` if the
/// input can't be parsed (defensive — analytics should never crash).
String redactDeepLinkStringForLogging(String input) {
  try {
    return redactDeepLinkForLogging(Uri.parse(input));
  } catch (_) {
    return '[invalid-uri]';
  }
}
