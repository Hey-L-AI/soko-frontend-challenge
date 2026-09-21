/// Typed failure modes for `InstagramShareApi.submitShare`.
sealed class InstagramShareFailure implements Exception {
  const InstagramShareFailure();
}

/// 400 — URL is unsupported (reel, TV) or malformed.
class InstagramShareInvalidUrl extends InstagramShareFailure {
  final String? detail;
  const InstagramShareInvalidUrl({this.detail});
}

/// 429 — Rate limit exceeded (10 share/profile actions per hour).
class InstagramShareRateLimited extends InstagramShareFailure {
  const InstagramShareRateLimited();
}

/// Network-level failure (no connection, timeout, etc.).
class InstagramShareNetworkError extends InstagramShareFailure {
  const InstagramShareNetworkError();
}

/// Catch-all for unexpected HTTP errors.
class InstagramShareUnknown extends InstagramShareFailure {
  final int? statusCode;
  const InstagramShareUnknown({this.statusCode});
}

/// Client-side gate: the user already has a share in flight (pending or
/// processing). Set by the notifier before any HTTP call so we don't
/// pile-on while the previous link is still being scraped/classified.
class InstagramShareWaitForPrevious extends InstagramShareFailure {
  const InstagramShareWaitForPrevious();
}
