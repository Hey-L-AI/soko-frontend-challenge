/// Typed failure modes for `VenuesApi.resolveVenueFromUrl`.
///
/// The API method throws exactly one of these on non-2xx responses so
/// callers can switch on the failure type to show specific user-facing copy.
sealed class ResolveUrlFailure implements Exception {
  const ResolveUrlFailure();
}

/// 400 — URL is not a recognizable Google Maps URL.
class ResolveUrlInvalid extends ResolveUrlFailure {
  const ResolveUrlInvalid();
}

/// 404 — URL is valid but Google Places returned no matching place.
class ResolveUrlNotFound extends ResolveUrlFailure {
  const ResolveUrlNotFound();
}

/// 422 — URL shape is unrecognized for v1 (e.g. CID, directions, My Maps).
class ResolveUrlUnrecognized extends ResolveUrlFailure {
  const ResolveUrlUnrecognized();
}

/// 429 — Google Places rate limit hit. Caller may surface a "try again in a
/// moment" message.
class ResolveUrlRateLimited extends ResolveUrlFailure {
  const ResolveUrlRateLimited();
}

/// Network-level failure (no connection, timeout, connection reset, etc.).
class ResolveUrlNetworkError extends ResolveUrlFailure {
  const ResolveUrlNetworkError();
}

/// Catch-all for other HTTP errors (500, 503, etc.) or unexpected shapes.
class ResolveUrlUnknown extends ResolveUrlFailure {
  final int? statusCode;
  const ResolveUrlUnknown({this.statusCode});
}
