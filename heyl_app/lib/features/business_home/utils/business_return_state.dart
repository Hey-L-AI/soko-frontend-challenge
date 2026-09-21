/// Business Connect return-state helpers (PROD-4040 T2.4).
///
/// An owner can arrive from a public business link that carries return-state
/// (`return_to` / `claim_intent` / `utm_*`). We thread those onto the auth
/// requests so the backend can validate + attribute them and echo back a
/// signed, allowlisted `business_return_to`; the client then navigates there
/// once it holds the tokens.

const List<String> _passThroughKeys = [
  'claim_intent',
  'utm_source',
  'utm_medium',
  'utm_campaign',
  'utm_term',
  'utm_content',
];

/// App web origins whose absolute `business_return_to` URLs are safe to route
/// in-app. Relative paths are always safe; anything else is dropped so a login
/// response can never send the app to an external URL.
bool _isAppHost(String host) {
  if (host == 'localhost' || host == '127.0.0.1') return true;
  if (host.endsWith('.onrender.com')) return true;
  return host == 'app.soko.fyi' || host == 'soko.fyi' || host == 'www.soko.fyi';
}

/// Reduce a `business_return_to` value (relative path or same-app absolute URL)
/// to a routable in-app path, or null if it isn't safely routable.
String? routableBusinessReturn(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('/')) return trimmed;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasAuthority || !_isAppHost(uri.host)) return null;
  return uri.path + (uri.hasQuery ? '?${uri.query}' : '');
}

/// Build the return-state query suffix (leading `&`) for the Google-login auth
/// URL: a `return_to` from [returnTo] plus any `claim_intent` / `utm_*` present
/// on the current page URL ([incoming], defaults to `Uri.base`). Empty when
/// there's nothing to thread.
String businessReturnStateQuery({String? returnTo, Uri? incoming}) {
  final params = <String, String>{};
  final routableReturn = routableBusinessReturn(returnTo);
  if (routableReturn != null) params['return_to'] = routableReturn;

  final source = (incoming ?? Uri.base).queryParameters;
  for (final key in _passThroughKeys) {
    final value = source[key];
    if (value != null && value.isNotEmpty) params[key] = value;
  }

  if (params.isEmpty) return '';
  return '&${params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
}
