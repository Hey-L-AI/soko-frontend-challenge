/// PROD-2785 — typed failure modes for [SharesApi] + [ShareController].
///
/// Pattern mirrors `InstagramShareFailure` (inbound IG share) so the
/// surrounding error-handling style stays consistent across share flows.
sealed class ShareFailure implements Exception {
  const ShareFailure();
}

/// 403 — backend says this entity isn't shareable (system-managed list,
/// private content, owner-only persona for another user). Sheet should
/// either hide upstream or show a "this isn't shareable" toast.
class ShareNotShareable extends ShareFailure {
  const ShareNotShareable({this.detail});
  final String? detail;
}

/// 429 — backend rate-limited the share-asset render endpoint.
class ShareRateLimited extends ShareFailure {
  const ShareRateLimited();
}

/// Network-level failure (no connection, timeout, etc.).
class ShareNetworkError extends ShareFailure {
  const ShareNetworkError();
}

/// Catch-all for unexpected HTTP / I/O errors.
class ShareUnknown extends ShareFailure {
  const ShareUnknown({this.statusCode, this.message});
  final int? statusCode;
  final String? message;
}
