import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/locale_info.dart';
import '../../data/models/location_snapshot.dart';
import '../../data/models/message_starter.dart';
import '../../data/models/saved_item.dart';
import '../../data/models/user_list.dart';
import '../../data/models/user_profile.dart';
import 'app_group_bridge.dart';

/// Keys for storage
class StorageKeys {
  StorageKeys._();

  static const String accessToken = 'access_token';
  static const String tokenExpiresAt = 'token_expires_at';
  static const String refreshToken = 'refresh_token';

  /// PROD-2168 Phase 2 — monotonic generation counter incremented on every
  /// successful rotation. Written LAST inside [StorageService.saveRotatedTokens]
  /// as the commit marker; followers gate on this to decide whether the
  /// in-memory cache + secure-storage tokens it just observed are consistent.
  static const String tokenGeneration = 'token_generation';

  /// PROD-2168 Phase 2 — origin-wide transient cooldown timestamp (millis since
  /// epoch). When set and within the cooldown window, any tab attempting a
  /// refresh returns [RefreshTransient] without POSTing. Stored in
  /// SharedPreferences so it survives tab close but not browser restart.
  static const String lastRefreshTransientAt = 'last_refresh_transient_at';

  /// PROD-2168 Phase 2 Codex [P2] fix — secure-storage web prefix.
  ///
  /// `flutter_secure_storage` web backend prepends this prefix (from
  /// `WebOptions.publicKey` configured in [secureStorageProvider] below
  /// — kept in sync) to every key it writes to localStorage. Cross-tab
  /// `storage` event listeners need the FULL prefixed key to receive
  /// events; bare `token_generation` never matches anything.
  static const String secureStorageWebPrefix = 'heyl_app_key.';

  /// Convenience: the actual localStorage key under which
  /// [tokenGeneration] is written on web. Use this when subscribing to
  /// the browser `storage` event for cross-tab generation changes.
  static const String tokenGenerationStorageKey =
      '$secureStorageWebPrefix$tokenGeneration';

  static const String savedItems = 'saved_items';
  static const String userLists = 'user_lists';
  static const String messageStarters = 'message_starters';
  static const String messageStartersLastFetch = 'message_starters_last_fetch';
  static const String pendingPhoneVerification = 'pending_phone_verification';
  static const String pendingPhoneVerificationTimestamp =
      'pending_phone_verification_timestamp';
  static const String pendingReferralSlug = 'pending_referral_slug';
  static const String pendingReferralSearch = 'pending_referral_search';
  static const String cachedLocales = 'cached_locales';
  static const String activeSessionId = 'active_session_id';
  static const String cachedUserProfile = 'cached_user_profile';
  static const String cachedLocation = 'cached_location';
  static const String cachedLocationTimestamp = 'cached_location_timestamp';
  static const String oauthReturnUrl = 'oauth_return_url';
  static const String pendingVenueClaimVenueId = 'pending_venue_claim_venue_id';
  static const String businessConnectReturnPath =
      'business_connect_return_path';
  static const String locationSharingDisabled = 'location_sharing_disabled';
  static const String locationSuggestionDismissedAt =
      'location_suggestion_dismissed_at';
  static const String loginTimestamp = 'login_timestamp';
  static const String loginMethod = 'login_method';
  static const String activeImportJob = 'active_import_job';
  static const String discoverSections = 'discover_sections';
  static const String activeInstagramShare = 'active_instagram_share';
  static const String activeContribution = 'active_contribution';

  /// Guest chat usage cap (see `features/guest/guest_limits.dart`). Tracks the
  /// visitor the counters belong to, the one session that visitor has used,
  /// and how many user-initiated messages they've sent in it.
  static const String guestQuotaVisitorId = 'guest_quota_visitor_id';
  static const String guestQuotaSessionId = 'guest_quota_session_id';
  static const String guestQuotaMessageCount = 'guest_quota_message_count';
}

/// Thrown by [StorageService.saveRotatedTokens] when the caller's observed
/// generation is older than the currently-stored generation. Indicates
/// another tab rotated between the caller's read and write — the cross-tab
/// lock should have prevented this in production, so the call is rejected
/// and Sentry is notified.
///
/// Made public (PROD-2168 Phase 2 followup) so callers can catch it
/// specifically and avoid the legacy-write fallback path that would
/// clobber the newer state.
class StaleRotationWriteException implements Exception {
  final int incomingGeneration;
  final int storedGeneration;
  StaleRotationWriteException({
    required this.incomingGeneration,
    required this.storedGeneration,
  });
  @override
  String toString() =>
      'StaleRotationWriteException(incoming=$incomingGeneration, stored=$storedGeneration)';
}

/// Service for persisting data locally on device
class StorageService {
  final FlutterSecureStorage _secureStorage;
  final SharedPreferences _prefs;

  /// In-memory cache for access token to avoid repeated secure storage reads
  String? _cachedToken;

  /// In-memory cache for token expiry timestamp
  DateTime? _cachedTokenExpiresAt;

  /// In-memory cache for the monotonic rotation generation counter.
  /// Mirrors [StorageKeys.tokenGeneration] in secure storage. Read by the
  /// cross-tab sync layer to decide whether a follower's cache is stale.
  int? _cachedTokenGeneration;

  StorageService({
    required FlutterSecureStorage secureStorage,
    required SharedPreferences prefs,
  }) : _secureStorage = secureStorage,
       _prefs = prefs;

  // ============ Auth Token (Secure Storage) ============

  /// Save access token securely with optional expiry information
  Future<void> saveAccessToken(String token, {DateTime? expiresAt}) async {
    try {
      _cachedToken = token; // Update cache
      _cachedTokenExpiresAt = expiresAt; // Update expiry cache
      await _secureStorage.write(key: StorageKeys.accessToken, value: token);
      if (expiresAt != null) {
        await _secureStorage.write(
          key: StorageKeys.tokenExpiresAt,
          value: expiresAt.toIso8601String(),
        );
      }
      print(
        '[StorageService] Token saved successfully (length: ${token.length}, expires: $expiresAt)',
      );
      // Mirror to App Group so the iOS Share Extension can read it. iOS-only;
      // never let bridge failures break auth.
      unawaited(
        AppGroupBridge.instance.writeAuth(token: token, expiresAt: expiresAt),
      );
    } catch (e) {
      print('[StorageService] ERROR saving token: $e');
      rethrow;
    }
  }

  /// Get access token (returns from cache if available)
  Future<String?> getAccessToken() async {
    // Return cached token if available (avoids slow secure storage read)
    if (_cachedToken != null) {
      return _cachedToken;
    }

    try {
      final token = await _secureStorage.read(key: StorageKeys.accessToken);
      // PROD-2580 — TOCTOU guard. A concurrent `saveAccessToken()` (e.g. the
      // web Google OAuth callback's `completeGoogleLogin`, which runs one
      // frame after the constructor's fire-and-forget `_initializeFromStorage`)
      // may have populated `_cachedToken` with the real token while we awaited
      // this now-stale secure-storage read. Re-check before caching so the
      // stale read can't clobber the fresher cached value back to the
      // pre-login guest token — otherwise the auth interceptor serves the
      // guest token to every real-user endpoint and they all 401.
      if (_cachedToken != null) {
        return _cachedToken;
      }
      print(
        '[StorageService] Token read: ${token != null ? "exists (length: ${token.length})" : "null"}',
      );
      if (token != null) {
        _cachedToken = token; // Cache for subsequent calls
      }
      return token;
    } catch (e) {
      print('[StorageService] ERROR reading token: $e');
      return null;
    }
  }

  /// Get token expiry time (returns from cache if available)
  Future<DateTime?> getTokenExpiresAt() async {
    // Return cached expiry if available
    if (_cachedTokenExpiresAt != null) {
      return _cachedTokenExpiresAt;
    }

    try {
      final expiresAtStr = await _secureStorage.read(
        key: StorageKeys.tokenExpiresAt,
      );
      if (expiresAtStr != null) {
        _cachedTokenExpiresAt = DateTime.parse(expiresAtStr);
      }
      return _cachedTokenExpiresAt;
    } catch (e) {
      print('[StorageService] ERROR reading token expiry: $e');
      return null;
    }
  }

  /// Delete access token and expiry
  Future<void> deleteAccessToken() async {
    try {
      _cachedToken = null; // Invalidate cache
      _cachedTokenExpiresAt = null; // Invalidate expiry cache
      // Generation cache is intentionally NOT cleared here — it stays a
      // monotonic counter across token churn so other tabs can detect
      // out-of-order writes vs in-order deletes.
      await _secureStorage.delete(key: StorageKeys.accessToken);
      await _secureStorage.delete(key: StorageKeys.tokenExpiresAt);
      print('[StorageService] Token and expiry deleted');
      unawaited(AppGroupBridge.instance.clearAuth());
    } catch (e) {
      print('[StorageService] ERROR deleting token: $e');
    }
  }

  // ============ PROD-2168 Phase 2 — atomic rotation + generation ============

  /// Read the current rotation generation counter. Returns from cache when
  /// available; reads secure storage otherwise. Returns `0` when not set yet
  /// (treats "no generation" as the lowest possible generation).
  Future<int> getTokenGeneration() async {
    if (_cachedTokenGeneration != null) {
      return _cachedTokenGeneration!;
    }
    try {
      final raw = await _secureStorage.read(key: StorageKeys.tokenGeneration);
      final parsed = raw == null ? 0 : (int.tryParse(raw) ?? 0);
      _cachedTokenGeneration = parsed;
      return parsed;
    } catch (e) {
      print('[StorageService] ERROR reading token_generation: $e');
      return 0;
    }
  }

  /// Invalidate the in-memory token caches. Called BOTH after a local
  /// rotation write AND when another tab signals a rotation (via
  /// BroadcastChannel or the `storage` event on token_generation). Without
  /// this, [getAccessToken] / [getTokenExpiresAt] would keep serving the
  /// pre-rotation values from `_cachedToken` / `_cachedTokenExpiresAt` even
  /// after the source-of-truth in secure storage has moved on.
  ///
  /// [reason] is recorded so cross-tab-sync diagnostics can distinguish
  /// the trigger (`local_write`, `cross_tab_complete`, `storage_event`,
  /// `manual`, etc.) in Sentry breadcrumbs.
  void invalidateAccessTokenCache({required String reason}) {
    _cachedToken = null;
    _cachedTokenExpiresAt = null;
    _cachedTokenGeneration = null;
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'access_token_cache_invalidated',
        category: 'auth.storage',
        type: 'info',
        data: {'reason': reason},
      ),
    );
  }

  /// PROD-2168 Phase 2 — atomic-by-convention rotation write.
  ///
  /// Writes the rotated tokens in the order
  ///
  ///     access_token → token_expires_at → refresh_token (if present)
  ///     → token_generation
  ///
  /// `token_generation` is written LAST as the commit marker. Followers in
  /// other tabs read it before trusting any of the other fields they
  /// observed — if the writer was interrupted mid-rotation, the older
  /// generation stays in place and the partial write is ignored.
  ///
  /// [expectedGeneration] is the value the caller observed before deciding
  /// to write. If it's lower than the currently-stored generation, the
  /// write is rejected (another tab beat us to the rotation) and an
  /// `auth.storage.stale_write_rejected` Sentry event is fired. Pass
  /// `null` to skip the stale-write guard — callers should pass `null`
  /// only when they're the lock-holder and have just performed a fresh
  /// `getTokenGeneration()` themselves.
  ///
  /// Returns the new generation on success. Throws on stale write.
  Future<int> saveRotatedTokens({
    required String accessToken,
    required DateTime expiresAt,
    String? refreshToken,
    int? expectedGeneration,
    String caller = 'unknown',
  }) async {
    // Stale-write guard. Must read fresh from secure storage (not the
    // in-memory cache) because another tab may have just rotated.
    final currentRaw = await _secureStorage.read(
      key: StorageKeys.tokenGeneration,
    );
    final currentGeneration = currentRaw == null
        ? 0
        : (int.tryParse(currentRaw) ?? 0);

    if (expectedGeneration != null && expectedGeneration < currentGeneration) {
      // Another tab rotated between our read and our write attempt. Do
      // NOT clobber the newer state — the lock should have prevented this.
      // Fire the Sentry alert so we know something bypassed the lock.
      unawaited(
        Sentry.captureMessage(
          'auth.storage.stale_write_rejected',
          level: SentryLevel.warning,
          withScope: (scope) {
            scope.setTag('storage.op', 'save_rotated_tokens');
            scope.setExtra('caller', caller);
            scope.setExtra('incoming_generation', expectedGeneration);
            scope.setExtra('stored_generation', currentGeneration);
          },
        ),
      );
      throw StaleRotationWriteException(
        incomingGeneration: expectedGeneration,
        storedGeneration: currentGeneration,
      );
    }

    final nextGeneration = currentGeneration + 1;

    try {
      // Order is load-bearing: token_generation is written LAST so that
      // a follower reading "new generation" can trust all preceding writes
      // completed.
      await _secureStorage.write(
        key: StorageKeys.accessToken,
        value: accessToken,
      );
      await _secureStorage.write(
        key: StorageKeys.tokenExpiresAt,
        value: expiresAt.toIso8601String(),
      );
      var refreshTokenWriteFailed = false;
      if (refreshToken != null) {
        try {
          await _secureStorage.write(
            key: StorageKeys.refreshToken,
            value: refreshToken,
          );
        } catch (e, stackTrace) {
          // Capture-and-continue for THIS tab (the BE accepted the
          // rotation; access_token is in our in-memory cache so this
          // session can keep operating). But the commit-marker MUST NOT
          // advance: other tabs read `token_generation` as proof that
          // all preceding writes (including refresh_token) landed. If
          // we advance the marker now, followers will trust storage's
          // refresh_token is the rotated one and force-logout on their
          // next body-based refresh (e.g. Safari / cookie-blocked).
          refreshTokenWriteFailed = true;
          print('[StorageService] ERROR saving refresh token: $e');
          unawaited(
            Sentry.captureException(
              e,
              stackTrace: stackTrace,
              withScope: (scope) {
                scope.level = SentryLevel.error;
                scope.setTag('storage.op', 'save_refresh_token_in_rotation');
                scope.setTag('storage.marker_advanced', 'false');
                scope.setExtra('caller', caller);
                scope.setExtra('current_generation', currentGeneration);
              },
            ),
          );
        }
      }

      if (refreshTokenWriteFailed) {
        // PR-599-followup Codex [P1] — preserve atomic-by-convention
        // semantics: don't advance the marker on partial rotation.
        // This tab's in-memory cache still picks up the new access
        // token so the current session can keep operating; other tabs
        // will see the same generation they already have and proceed
        // to refresh themselves (their cookie path carries the latest
        // refresh token even when our body write to local storage
        // failed).
        _cachedToken = accessToken;
        _cachedTokenExpiresAt = expiresAt;
        // _cachedTokenGeneration is intentionally NOT updated — we
        // didn't write the marker, so the in-memory cache must stay
        // in sync with what's on disk for the next stale-write guard
        // check to behave correctly.
        unawaited(
          AppGroupBridge.instance.writeAuth(
            token: accessToken,
            expiresAt: expiresAt,
          ),
        );
        return currentGeneration;
      }

      // Commit marker. After this write, followers in other tabs will see
      // the new generation and trust the preceding writes.
      await _secureStorage.write(
        key: StorageKeys.tokenGeneration,
        value: '$nextGeneration',
      );

      // Update in-memory caches for THIS tab so the very next read in this
      // event-loop turn sees the new state without a secure-storage round
      // trip. Other tabs invalidate via BroadcastChannel / storage event.
      _cachedToken = accessToken;
      _cachedTokenExpiresAt = expiresAt;
      _cachedTokenGeneration = nextGeneration;

      print(
        '[StorageService] Atomic rotation written (gen $currentGeneration → $nextGeneration, caller=$caller, length=${accessToken.length})',
      );
      unawaited(
        AppGroupBridge.instance.writeAuth(
          token: accessToken,
          expiresAt: expiresAt,
        ),
      );

      return nextGeneration;
    } catch (e, stackTrace) {
      print('[StorageService] ERROR in saveRotatedTokens: $e');
      unawaited(
        Sentry.captureException(
          e,
          stackTrace: stackTrace,
          withScope: (scope) {
            scope.setTag('storage.op', 'save_rotated_tokens');
            scope.setExtra('caller', caller);
          },
        ),
      );
      rethrow;
    }
  }

  // ============ PROD-2168 Phase 2 — origin-wide transient cooldown ============

  /// Set the origin-wide cooldown marker. After a transient `/auth/refresh`
  /// failure (BE 5xx, network timeout), any tab attempting refresh within
  /// the next [_refreshTransientCooldown] window returns [RefreshTransient]
  /// without POSTing. Prevents N tabs from immediately retrying when the
  /// BE is already known to be sad.
  ///
  /// Stored in SharedPreferences so it's visible to all same-origin tabs
  /// (via the `storage` event) without going through BroadcastChannel.
  Future<void> setRefreshTransientCooldownAt(DateTime when) async {
    await _prefs.setInt(
      StorageKeys.lastRefreshTransientAt,
      when.millisecondsSinceEpoch,
    );
  }

  /// Read the origin-wide cooldown marker. Returns null when not set or
  /// when the stored value is older than the cooldown window.
  DateTime? getRefreshTransientCooldownAt() {
    final ms = _prefs.getInt(StorageKeys.lastRefreshTransientAt);
    if (ms == null) return null;
    final ts = DateTime.fromMillisecondsSinceEpoch(ms);
    if (DateTime.now().difference(ts) > _refreshTransientCooldown) {
      return null;
    }
    return ts;
  }

  /// Clear the cooldown explicitly (e.g. on a successful refresh).
  Future<void> clearRefreshTransientCooldown() async {
    await _prefs.remove(StorageKeys.lastRefreshTransientAt);
  }

  /// PROD-2168 Phase 2 — origin-wide cooldown window. 10s is the conservative
  /// pick from the 5-15s range in § 6 of the context doc: long enough to
  /// debounce a multi-tab thundering herd against a flaky BE, short enough
  /// that a real recovery doesn't keep users waiting.
  static const Duration _refreshTransientCooldown = Duration(seconds: 10);

  /// Public accessor so RefreshCoordinator can include the window in
  /// breadcrumbs without leaking the constant.
  Duration get refreshTransientCooldownWindow => _refreshTransientCooldown;

  // ============ Refresh Token (Secure Storage) ============

  /// Save refresh token securely.
  Future<void> saveRefreshToken(String token) async {
    try {
      await _secureStorage.write(key: StorageKeys.refreshToken, value: token);
      print('[StorageService] Refresh token saved (length: ${token.length})');
    } catch (e, stackTrace) {
      // PROD-2168 — surface IndexedDB / Keychain write failures to Sentry
      // instead of swallowing them. Capture-and-continue keeps the
      // rotation flow alive (failing it would be worse than the current
      // behavior) while turning a silent failure mode into a measurable
      // one.
      print('[StorageService] ERROR saving refresh token: $e');
      unawaited(
        Sentry.captureException(
          e,
          stackTrace: stackTrace,
          withScope: (scope) {
            scope.setTag('storage.op', 'save_refresh_token');
          },
        ),
      );
    }
  }

  /// Get refresh token.
  Future<String?> getRefreshToken() async {
    try {
      return await _secureStorage.read(key: StorageKeys.refreshToken);
    } catch (e) {
      print('[StorageService] ERROR reading refresh token: $e');
      return null;
    }
  }

  /// Delete refresh token.
  Future<void> deleteRefreshToken() async {
    try {
      await _secureStorage.delete(key: StorageKeys.refreshToken);
      print('[StorageService] Refresh token deleted');
    } catch (e) {
      print('[StorageService] ERROR deleting refresh token: $e');
    }
  }

  // ============ Saved Items (SharedPreferences) ============

  /// Save items list to local storage
  Future<void> saveSavedItems(List<SavedItem> items) async {
    final jsonList = items.map((item) => item.toJson()).toList();
    await _prefs.setString(StorageKeys.savedItems, jsonEncode(jsonList));
  }

  /// Load saved items from local storage
  List<SavedItem> loadSavedItems() {
    final jsonString = _prefs.getString(StorageKeys.savedItems);
    if (jsonString == null) return [];

    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList
          .map((json) => SavedItem.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// Clear saved items
  Future<void> clearSavedItems() async {
    await _prefs.remove(StorageKeys.savedItems);
  }

  // ============ User Lists (SharedPreferences) ============

  /// Save user lists to local storage
  Future<void> saveUserLists(List<UserList> lists) async {
    final jsonList = lists.map((list) => list.toJson()).toList();
    await _prefs.setString(StorageKeys.userLists, jsonEncode(jsonList));
  }

  /// Load user lists from local storage
  List<UserList> loadUserLists() {
    final jsonString = _prefs.getString(StorageKeys.userLists);
    if (jsonString == null) return [];

    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList
          .map((json) => UserList.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// Clear user lists
  Future<void> clearUserLists() async {
    await _prefs.remove(StorageKeys.userLists);
  }

  // ============ Discover Sections Cache (SharedPreferences) ============

  /// Save discover sections (curated, following, recommended) to local storage.
  /// Refreshed on every Lists tab visit; cleared on logout/account deletion.
  Future<void> saveDiscoverSections({
    required List<UserList> curated,
    required List<UserList> following,
    required List<UserList> recommended,
  }) async {
    final json = {
      'curated': curated.map((l) => l.toJson()).toList(),
      'following': following.map((l) => l.toJson()).toList(),
      'recommended': recommended.map((l) => l.toJson()).toList(),
    };
    await _prefs.setString(StorageKeys.discoverSections, jsonEncode(json));
  }

  /// Load cached discover sections. Returns null if no cache exists.
  ({
    List<UserList> curated,
    List<UserList> following,
    List<UserList> recommended,
  })?
  loadDiscoverSections() {
    final jsonString = _prefs.getString(StorageKeys.discoverSections);
    if (jsonString == null) return null;

    try {
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return (
        curated: (json['curated'] as List<dynamic>)
            .map((e) => UserList.fromJson(e as Map<String, dynamic>))
            .toList(),
        following: (json['following'] as List<dynamic>)
            .map((e) => UserList.fromJson(e as Map<String, dynamic>))
            .toList(),
        recommended: (json['recommended'] as List<dynamic>)
            .map((e) => UserList.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    } catch (e) {
      return null;
    }
  }

  /// Clear discover sections cache
  Future<void> clearDiscoverSections() async {
    await _prefs.remove(StorageKeys.discoverSections);
  }

  // ============ Message Starters (SharedPreferences) ============

  /// Save message starters to local storage with timestamp
  Future<void> saveMessageStarters(List<MessageStarter> starters) async {
    final jsonList = starters.map((s) => s.toJson()).toList();
    await _prefs.setString(StorageKeys.messageStarters, jsonEncode(jsonList));
    await _prefs.setInt(
      StorageKeys.messageStartersLastFetch,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Load message starters from local storage
  List<MessageStarter> loadMessageStarters() {
    final jsonString = _prefs.getString(StorageKeys.messageStarters);
    if (jsonString == null) return [];

    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList
          .map((json) => MessageStarter.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// Get the timestamp of the last message starters fetch
  DateTime? getMessageStartersLastFetch() {
    final timestamp = _prefs.getInt(StorageKeys.messageStartersLastFetch);
    if (timestamp == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  /// Check if message starters cache is stale (older than 24 hours or different day)
  bool isMessageStartersCacheStale() {
    final lastFetch = getMessageStartersLastFetch();
    if (lastFetch == null) return true;

    final now = DateTime.now();
    // Stale if it's a different day or more than 24 hours old
    final isDifferentDay =
        lastFetch.day != now.day ||
        lastFetch.month != now.month ||
        lastFetch.year != now.year;
    final isOlderThan24Hours = now.difference(lastFetch).inHours >= 24;

    return isDifferentDay || isOlderThan24Hours;
  }

  /// Clear message starters cache
  Future<void> clearMessageStarters() async {
    await _prefs.remove(StorageKeys.messageStarters);
    await _prefs.remove(StorageKeys.messageStartersLastFetch);
  }

  // ============ Pending Phone Verification (SharedPreferences) ============

  /// OTP expiry duration (10 minutes)
  static const Duration _otpExpiryDuration = Duration(minutes: 10);

  /// Save pending phone verification (when OTP is requested)
  Future<void> savePendingPhoneVerification(String phone) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    await _prefs.setString(StorageKeys.pendingPhoneVerification, phone);
    await _prefs.setInt(
      StorageKeys.pendingPhoneVerificationTimestamp,
      timestamp,
    );
  }

  /// Get pending phone verification
  String? getPendingPhoneVerification() {
    return _prefs.getString(StorageKeys.pendingPhoneVerification);
  }

  /// Clear pending phone verification (after successful verification or cancellation)
  Future<void> clearPendingPhoneVerification() async {
    await _prefs.remove(StorageKeys.pendingPhoneVerification);
    await _prefs.remove(StorageKeys.pendingPhoneVerificationTimestamp);
  }

  /// Check if pending phone verification has expired (OTPs expire after 10 minutes)
  bool isPendingPhoneVerificationExpired() {
    final timestamp = _prefs.getInt(
      StorageKeys.pendingPhoneVerificationTimestamp,
    );
    if (timestamp == null) {
      return true;
    }

    final requestedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final elapsed = DateTime.now().difference(requestedAt);
    return elapsed > _otpExpiryDuration;
  }

  // ============ Pending Referral (SharedPreferences) ============

  /// Save pending referral slug (survives app restarts and OAuth redirects)
  Future<void> savePendingReferral(String slug, {String? searchQuery}) async {
    await _prefs.setString(StorageKeys.pendingReferralSlug, slug);
    if (searchQuery != null) {
      await _prefs.setString(StorageKeys.pendingReferralSearch, searchQuery);
    }
  }

  /// Get pending referral slug
  String? getPendingReferralSlug() {
    return _prefs.getString(StorageKeys.pendingReferralSlug);
  }

  /// Get pending referral search query (fallback if API call fails)
  String? getPendingReferralSearch() {
    return _prefs.getString(StorageKeys.pendingReferralSearch);
  }

  /// Clear pending referral (after processing or on failure)
  Future<void> clearPendingReferral() async {
    await _prefs.remove(StorageKeys.pendingReferralSlug);
    await _prefs.remove(StorageKeys.pendingReferralSearch);
  }

  /// Check if there's a pending referral
  bool hasPendingReferral() {
    return _prefs.getString(StorageKeys.pendingReferralSlug) != null;
  }

  // ============ Cached Locales (SharedPreferences) ============

  /// Save locales to local cache (locales rarely change, so we cache indefinitely)
  Future<void> saveCachedLocales(List<LocaleInfo> locales) async {
    final jsonList = locales.map((l) => l.toJson()).toList();
    await _prefs.setString(StorageKeys.cachedLocales, jsonEncode(jsonList));
  }

  /// Load cached locales from local storage
  List<LocaleInfo>? loadCachedLocales() {
    final jsonString = _prefs.getString(StorageKeys.cachedLocales);
    if (jsonString == null) return null;

    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList
          .map((json) => LocaleInfo.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return null;
    }
  }

  /// Check if locales are cached
  bool hasLocalesCache() {
    return _prefs.getString(StorageKeys.cachedLocales) != null;
  }

  // ============ Active Session (SharedPreferences) ============

  /// Save active session ID (persists across page refreshes)
  Future<void> saveActiveSessionId(String? sessionId) async {
    if (sessionId == null) {
      await _prefs.remove(StorageKeys.activeSessionId);
    } else {
      await _prefs.setString(StorageKeys.activeSessionId, sessionId);
    }
  }

  /// Get active session ID
  String? getActiveSessionId() {
    return _prefs.getString(StorageKeys.activeSessionId);
  }

  /// Clear active session ID
  Future<void> clearActiveSessionId() async {
    await _prefs.remove(StorageKeys.activeSessionId);
  }

  // ============ Guest Chat Quota (SharedPreferences) ============

  /// Persist the guest's current chat-usage counters. `visitorId` scopes the
  /// counters so a fresh visitor (new attribution ID) starts at zero.
  /// `sessionId` is null until the guest's one allowed session has been
  /// created; `messageCount` increments on each successful user-initiated
  /// send. See [GuestQuotaNotifier] for the read path.
  Future<void> saveGuestQuota({
    required String visitorId,
    required String? sessionId,
    required int messageCount,
  }) async {
    await _prefs.setString(StorageKeys.guestQuotaVisitorId, visitorId);
    if (sessionId == null) {
      await _prefs.remove(StorageKeys.guestQuotaSessionId);
    } else {
      await _prefs.setString(StorageKeys.guestQuotaSessionId, sessionId);
    }
    await _prefs.setInt(StorageKeys.guestQuotaMessageCount, messageCount);
  }

  String? getGuestQuotaVisitorId() {
    return _prefs.getString(StorageKeys.guestQuotaVisitorId);
  }

  String? getGuestQuotaSessionId() {
    return _prefs.getString(StorageKeys.guestQuotaSessionId);
  }

  int getGuestQuotaMessageCount() {
    return _prefs.getInt(StorageKeys.guestQuotaMessageCount) ?? 0;
  }

  Future<void> clearGuestQuota() async {
    await _prefs.remove(StorageKeys.guestQuotaVisitorId);
    await _prefs.remove(StorageKeys.guestQuotaSessionId);
    await _prefs.remove(StorageKeys.guestQuotaMessageCount);
  }

  // ============ Cached User Profile (SharedPreferences) ============

  /// Save user profile to cache (for instant display on refresh)
  Future<void> saveCachedUserProfile(UserProfile profile) async {
    await _prefs.setString(
      StorageKeys.cachedUserProfile,
      jsonEncode(profile.toJson()),
    );
  }

  /// Load cached user profile
  UserProfile? loadCachedUserProfile() {
    final jsonString = _prefs.getString(StorageKeys.cachedUserProfile);
    if (jsonString == null) return null;

    try {
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return UserProfile.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  /// Clear cached user profile
  Future<void> clearCachedUserProfile() async {
    await _prefs.remove(StorageKeys.cachedUserProfile);
  }

  // ============ Cached Location (SharedPreferences) ============

  /// Cache duration for location (1 hour - after this we should get fresh GPS)
  static const Duration _locationCacheMaxAge = Duration(hours: 1);

  /// Get the age of the cached location (null if no cache)
  Duration? getCachedLocationAge() {
    final timestamp = _prefs.getInt(StorageKeys.cachedLocationTimestamp);
    if (timestamp == null) return null;
    final cachedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return DateTime.now().difference(cachedAt);
  }

  /// Save location to cache (for instant map display on web refresh)
  Future<void> saveCachedLocation(LocationSnapshot location) async {
    await _prefs.setString(
      StorageKeys.cachedLocation,
      jsonEncode(location.toJson()),
    );
    await _prefs.setInt(
      StorageKeys.cachedLocationTimestamp,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Load cached location from storage
  /// Returns null if no cache exists or cache is too old
  LocationSnapshot? loadCachedLocation() {
    final jsonString = _prefs.getString(StorageKeys.cachedLocation);
    if (jsonString == null) return null;

    // Check if cache is too old
    final timestamp = _prefs.getInt(StorageKeys.cachedLocationTimestamp);
    if (timestamp != null) {
      final cachedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
      final age = DateTime.now().difference(cachedAt);
      if (age > _locationCacheMaxAge) {
        // Cache too old, clear it
        _prefs.remove(StorageKeys.cachedLocation);
        _prefs.remove(StorageKeys.cachedLocationTimestamp);
        return null;
      }
    }

    try {
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return LocationSnapshot.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  /// Clear cached location
  Future<void> clearCachedLocation() async {
    await _prefs.remove(StorageKeys.cachedLocation);
    await _prefs.remove(StorageKeys.cachedLocationTimestamp);
  }

  // ============ Location Sharing Preference (SharedPreferences) ============

  /// Save whether the user has disabled location sharing via in-app toggle
  Future<void> saveLocationSharingDisabled(bool disabled) async {
    await _prefs.setBool(StorageKeys.locationSharingDisabled, disabled);
  }

  /// Check if user has disabled location sharing (defaults to false)
  bool isLocationSharingDisabled() {
    return _prefs.getBool(StorageKeys.locationSharingDisabled) ?? false;
  }

  /// Clear the location sharing disabled flag
  Future<void> clearLocationSharingDisabled() async {
    await _prefs.remove(StorageKeys.locationSharingDisabled);
  }

  // ============ Location Suggestion Dismissal (SharedPreferences) ============

  /// Cooldown duration for location suggestion card (7 days)
  static const Duration _locationSuggestionCooldown = Duration(days: 7);

  /// Save that the user dismissed the location suggestion card
  Future<void> saveLocationSuggestionDismissed() async {
    await _prefs.setInt(
      StorageKeys.locationSuggestionDismissedAt,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Check if the location suggestion card was dismissed within the cooldown period
  bool isLocationSuggestionDismissed() {
    final timestamp = _prefs.getInt(StorageKeys.locationSuggestionDismissedAt);
    if (timestamp == null) return false;

    final dismissedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final elapsed = DateTime.now().difference(dismissedAt);
    return elapsed < _locationSuggestionCooldown;
  }

  /// Clear the location suggestion dismissed flag (for testing/reset)
  Future<void> clearLocationSuggestionDismissed() async {
    await _prefs.remove(StorageKeys.locationSuggestionDismissedAt);
  }

  // ============ Login History (SharedPreferences) ============

  /// Mark that the user has logged in at least once (persists across logouts)
  Future<void> setHasEverLoggedIn() async {
    await _prefs.setBool('has_ever_logged_in', true);
  }

  // ============ Login Metadata (SharedPreferences) ============

  /// Save login timestamp and method (for diagnostics — no sensitive data)
  Future<void> saveLoginMetadata(String method) async {
    await _prefs.setString(
      StorageKeys.loginTimestamp,
      DateTime.now().toIso8601String(),
    );
    await _prefs.setString(StorageKeys.loginMethod, method);
  }

  /// Get login timestamp
  DateTime? getLoginTimestamp() {
    final str = _prefs.getString(StorageKeys.loginTimestamp);
    if (str == null) return null;
    try {
      return DateTime.parse(str);
    } catch (_) {
      return null;
    }
  }

  /// Get login method ("google", "phone", "email", "apple")
  String? getLoginMethod() {
    return _prefs.getString(StorageKeys.loginMethod);
  }

  /// Clear login metadata
  Future<void> clearLoginMetadata() async {
    await _prefs.remove(StorageKeys.loginTimestamp);
    await _prefs.remove(StorageKeys.loginMethod);
  }

  // ============ OAuth Return URL (SharedPreferences) ============

  /// Save return URL before OAuth redirect (survives page navigation on web)
  Future<void> saveOAuthReturnUrl(String path) async {
    await _prefs.setString(StorageKeys.oauthReturnUrl, path);
  }

  /// Get persisted OAuth return URL
  String? getOAuthReturnUrl() {
    return _prefs.getString(StorageKeys.oauthReturnUrl);
  }

  /// Clear OAuth return URL (after restoring or on login complete)
  Future<void> clearOAuthReturnUrl() async {
    await _prefs.remove(StorageKeys.oauthReturnUrl);
  }

  // ============ Pending Venue Claim (SharedPreferences) ============

  /// Saves the venue that initiated an Instagram ownership claim. The OAuth
  /// callback can arrive after a full web reload or an external-browser return,
  /// so this must survive the in-memory navigation state.
  Future<void> savePendingVenueClaimVenueId(String venueId) async {
    await _prefs.setString(StorageKeys.pendingVenueClaimVenueId, venueId);
  }

  /// Gets the venue to restore after an Instagram ownership claim callback.
  String? getPendingVenueClaimVenueId() {
    return _prefs.getString(StorageKeys.pendingVenueClaimVenueId);
  }

  /// Clears the one-shot venue claim destination once the callback consumes it.
  Future<void> clearPendingVenueClaimVenueId() async {
    await _prefs.remove(StorageKeys.pendingVenueClaimVenueId);
  }

  // ============ Business Connect Return (SharedPreferences) ============

  /// Saves where to return after an Instagram connect started from the Business
  /// Connect portal. The OAuth callback arrives after a full web reload that
  /// wipes in-memory state (including `businessSessionActiveProvider`), so the
  /// business-return intent must survive here — otherwise the owner is routed
  /// to `/home` and swept into consumer onboarding instead of back to the
  /// portal (PROD-4040).
  Future<void> saveBusinessConnectReturnPath(String path) async {
    await _prefs.setString(StorageKeys.businessConnectReturnPath, path);
  }

  /// Gets the Business Connect return path to restore after the IG callback.
  String? getBusinessConnectReturnPath() {
    return _prefs.getString(StorageKeys.businessConnectReturnPath);
  }

  /// Clears the one-shot Business Connect return path once consumed.
  Future<void> clearBusinessConnectReturnPath() async {
    await _prefs.remove(StorageKeys.businessConnectReturnPath);
  }

  // ============ Active Import Job (SharedPreferences) ============

  /// Save active import job data (persists across page refreshes)
  Future<void> saveActiveImportJob({
    required String jobId,
    required String url,
    String? listName,
  }) async {
    final data = {
      'jobId': jobId,
      'url': url,
      if (listName != null) 'listName': listName,
    };
    await _prefs.setString(StorageKeys.activeImportJob, jsonEncode(data));
  }

  /// Load active import job data (null if no job stored)
  Map<String, String?>? loadActiveImportJob() {
    final jsonString = _prefs.getString(StorageKeys.activeImportJob);
    if (jsonString == null) return null;

    try {
      final data = jsonDecode(jsonString) as Map<String, dynamic>;
      return {
        'jobId': data['jobId'] as String?,
        'url': data['url'] as String?,
        'listName': data['listName'] as String?,
      };
    } catch (e) {
      return null;
    }
  }

  /// Clear active import job data
  Future<void> clearActiveImportJob() async {
    await _prefs.remove(StorageKeys.activeImportJob);
  }

  // ============ Active Instagram Share (SharedPreferences) ============

  /// Persist the in-flight Instagram share so the processing banner can be
  /// rehydrated after a page refresh / app restart.
  Future<void> saveActiveInstagramShare({
    required String sharedPostId,
    String? listId,
  }) async {
    final data = {
      'sharedPostId': sharedPostId,
      if (listId != null) 'listId': listId,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
    };
    await _prefs.setString(StorageKeys.activeInstagramShare, jsonEncode(data));
  }

  /// Load the persisted in-flight Instagram share, if any.
  ({String sharedPostId, String? listId, DateTime savedAt})?
  loadActiveInstagramShare() {
    final jsonString = _prefs.getString(StorageKeys.activeInstagramShare);
    if (jsonString == null) return null;

    try {
      final data = jsonDecode(jsonString) as Map<String, dynamic>;
      final sharedPostId = data['sharedPostId'] as String?;
      if (sharedPostId == null) return null;
      final savedAtMs = data['savedAt'] as int?;
      return (
        sharedPostId: sharedPostId,
        listId: data['listId'] as String?,
        savedAt: savedAtMs != null
            ? DateTime.fromMillisecondsSinceEpoch(savedAtMs)
            : DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Clear the persisted Instagram share (after dismiss / auto-dismiss).
  Future<void> clearActiveInstagramShare() async {
    await _prefs.remove(StorageKeys.activeInstagramShare);
  }

  // ============ Active Contribution (SharedPreferences) ============
  //
  // PROD-2404 — mirror of the IG-share persistence above, scoped to the
  // photo→event contribution flow. Each flow uses a distinct key so an
  // in-flight share and an in-flight contribution can coexist after a
  // browser refresh / app restart without one overwriting the other.

  /// Persist the in-flight contribution so the processing banner can be
  /// rehydrated after a page refresh / app restart.
  Future<void> saveActiveContribution({required String contributionId}) async {
    final data = {
      'contributionId': contributionId,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
    };
    await _prefs.setString(StorageKeys.activeContribution, jsonEncode(data));
  }

  /// Load the persisted in-flight contribution, if any.
  ({String contributionId, DateTime savedAt})? loadActiveContribution() {
    final jsonString = _prefs.getString(StorageKeys.activeContribution);
    if (jsonString == null) return null;

    try {
      final data = jsonDecode(jsonString) as Map<String, dynamic>;
      final contributionId = data['contributionId'] as String?;
      if (contributionId == null) return null;
      final savedAtMs = data['savedAt'] as int?;
      return (
        contributionId: contributionId,
        savedAt: savedAtMs != null
            ? DateTime.fromMillisecondsSinceEpoch(savedAtMs)
            : DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Clear the persisted contribution (after dismiss / auto-dismiss).
  Future<void> clearActiveContribution() async {
    await _prefs.remove(StorageKeys.activeContribution);
  }

  // ============ Clear All ============

  /// Clear all stored data (for logout)
  Future<void> clearAll() async {
    await _secureStorage.deleteAll();
    await _prefs.clear();
    unawaited(AppGroupBridge.instance.clearAll());
  }
}

/// Provider for SharedPreferences instance
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('Initialize in main.dart');
});

/// Provider for FlutterSecureStorage instance
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    webOptions: WebOptions(
      dbName: 'heyl_secure_storage',
      publicKey: 'heyl_app_key',
    ),
  );
});

/// Provider for StorageService
final storageServiceProvider = Provider<StorageService>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  final secureStorage = ref.watch(secureStorageProvider);
  return StorageService(secureStorage: secureStorage, prefs: prefs);
});
