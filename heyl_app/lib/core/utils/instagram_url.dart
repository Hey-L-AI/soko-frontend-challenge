/// Instagram URL type detected from user input.
enum InstagramUrlType { post, story, profile, reel, tv }

/// Client-side Instagram URL classification.
///
/// Mirrors the backend URL routing in `POST /api/v1/app/instagram/share`
/// so we can show appropriate UI before hitting the server.
class InstagramUrl {
  InstagramUrl._();

  // Post: /p/<shortcode>/
  static final _postPattern = RegExp(
    r'https?://(?:www\.)?instagram\.com/p/[A-Za-z0-9_-]+',
    caseSensitive: false,
  );

  // Story: /stories/<username>/<id>/
  static final _storyPattern = RegExp(
    r'https?://(?:www\.)?instagram\.com/stories/[A-Za-z0-9_.]+/\d+',
    caseSensitive: false,
  );

  // Reel: /reel/<shortcode>/ or /reels/<shortcode>/
  static final _reelPattern = RegExp(
    r'https?://(?:www\.)?instagram\.com/reels?/[A-Za-z0-9_-]+',
    caseSensitive: false,
  );

  // TV: /tv/<shortcode>/
  static final _tvPattern = RegExp(
    r'https?://(?:www\.)?instagram\.com/tv/[A-Za-z0-9_-]+',
    caseSensitive: false,
  );

  // Profile: /<username>/ — must come last (most permissive).
  // Usernames: 1-30 chars, letters/digits/periods/underscores.
  // Exclude known path prefixes to avoid false positives.
  static final _profilePattern = RegExp(
    r'https?://(?:www\.)?instagram\.com/([A-Za-z0-9_.]{1,30})/?(?:\?.*)?$',
    caseSensitive: false,
  );

  // Path prefixes that are NOT usernames.
  static const _reservedPaths = {
    'p',
    'reel',
    'reels',
    'tv',
    'stories',
    'explore',
    'accounts',
    'about',
    'legal',
    'developer',
    'directory',
    'direct',
    'lite',
  };

  /// Returns true when [input] contains a recognized Instagram URL.
  static bool looksLike(String input) {
    return extract(input) != null;
  }

  /// Extracts the first recognized Instagram URL from [input] and classifies
  /// its type. Returns null when no pattern matches.
  static ({String url, InstagramUrlType type})? extract(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    // Check specific patterns first (more restrictive → less restrictive).
    final postMatch = _postPattern.firstMatch(trimmed);
    if (postMatch != null) {
      return (url: postMatch.group(0)!, type: InstagramUrlType.post);
    }

    final storyMatch = _storyPattern.firstMatch(trimmed);
    if (storyMatch != null) {
      return (url: storyMatch.group(0)!, type: InstagramUrlType.story);
    }

    final reelMatch = _reelPattern.firstMatch(trimmed);
    if (reelMatch != null) {
      return (url: reelMatch.group(0)!, type: InstagramUrlType.reel);
    }

    final tvMatch = _tvPattern.firstMatch(trimmed);
    if (tvMatch != null) {
      return (url: tvMatch.group(0)!, type: InstagramUrlType.tv);
    }

    // Profile: last because it's the most permissive.
    final profileMatch = _profilePattern.firstMatch(trimmed);
    if (profileMatch != null) {
      final username = profileMatch.group(1)!.toLowerCase();
      if (!_reservedPaths.contains(username)) {
        return (url: profileMatch.group(0)!, type: InstagramUrlType.profile);
      }
    }

    return null;
  }

  /// Returns true if the URL type should be submitted to the backend.
  /// Reels are gated server-side by `INSTAGRAM_SHARE_REELS_ENABLED` — we
  /// submit them and let the API's 400 (when the flag is off) drive the
  /// error copy, rather than pre-rejecting client-side and going stale the
  /// moment the backend flips the flag. TV has no backend support planned,
  /// so it stays blocked here.
  static bool isSupported(InstagramUrlType type) {
    return type == InstagramUrlType.post ||
        type == InstagramUrlType.story ||
        type == InstagramUrlType.profile ||
        type == InstagramUrlType.reel;
  }
}
