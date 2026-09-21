import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/lists/models/search_scope.dart';
import 'auth_provider.dart';

/// User-selected city scope (country + city) shared across surfaces that
/// need a single "selected city" — Discovery shelves, the `/lists` hub, the
/// location pill on the action bar.
///
/// `null` means the user hasn't picked anything explicitly — pages fall
/// back to auto-resolution from [cityAutoScopeProvider]
/// (`user_profile.city` + IP geolocation).
///
/// Persistence: backed by `SharedPreferences` keyed by the current user's
/// ID. The on-disk key (`discovery_scope_<userId>`) is preserved verbatim
/// from the pre-rename world (PROD-1911). Legacy values without the session
/// timestamp intentionally expire on first open (PROD-3188).
///
/// The timestamped Search Center entry is removed when it expires. Other
/// per-user storage cleanup is intentionally skipped (the JSON payload is
/// < 1 KB; growth is bounded by the number of distinct users a device sees).
///
/// PROD-3188: the stored scope is a session-scoped Search Center (C), not a
/// durable user preference. Its timestamp is checked whenever the map or
/// picker opens. Once it expires, consumers fall back to the durable auto
/// location (U) instead of restoring an old explicit pick.
final cityScopeProvider = NotifierProvider<CityScopeNotifier, SearchScope?>(
  CityScopeNotifier.new,
);

/// The only expiry control for the Search Center (C). Exact equality keeps C;
/// it resets only after the elapsed time is greater than this value.
const kSearchCenterTtl = Duration(minutes: 45);

@visibleForTesting
bool shouldResetSearchCenter({
  required DateTime? lastActiveAt,
  required DateTime now,
}) => lastActiveAt == null || now.difference(lastActiveAt) > kSearchCenterTtl;

class CityScopeNotifier extends Notifier<SearchScope?> {
  // Key prefix preserved from the original `discoveryScopeProvider`
  // so existing users don't lose their saved scope on the FE rename.
  static const _keyPrefix = 'discovery_scope_';
  static const _lastActiveAtKeyPrefix = 'search_center_last_active_at_';

  String? _currentUserId;
  DateTime? _lastActiveAt;
  Future<void>? _restoreFuture;
  int _mutationVersion = 0;

  @override
  SearchScope? build() {
    final userId = ref.watch(currentUserProvider.select((u) => u?.id));
    _currentUserId = userId;

    if (userId == null) {
      return null;
    }

    // Kick off the async restore. Until it completes we publish null —
    // the action-bar pill has a sane fallback ("Localização" / auto-detect)
    // and the city-scoped shelves treat null as "use auto-resolution".
    _restoreFuture = _restore(userId);
    return null;
  }

  Future<void> _restore(String userId) async {
    final restoreVersion = _mutationVersion;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_keyPrefix$userId');
      final lastActiveAtMs = prefs.getInt('$_lastActiveAtKeyPrefix$userId');
      // The user may have switched again while we were reading.
      if (_currentUserId != userId || _mutationVersion != restoreVersion) {
        return;
      }
      final now = DateTime.now();
      final lastActiveAt = lastActiveAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastActiveAtMs);
      // Legacy persisted picks have no activity timestamp. They deliberately
      // expire here: a cold app start must not resurrect an old C.
      if (raw == null ||
          shouldResetSearchCenter(lastActiveAt: lastActiveAt, now: now)) {
        await _clearPersisted(prefs, userId);
        return;
      }
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final scope = SearchScope.fromJson(decoded);
      if (scope == null) return;
      if (_currentUserId != userId || _mutationVersion != restoreVersion) {
        return;
      }
      _lastActiveAt = now;
      state = scope;
      await _touch(prefs, userId, now);
    } catch (e) {
      debugPrint('[CityScope] restore failed for $userId: $e');
    }
  }

  /// Applies the shared first-open rule for the map and location picker.
  ///
  /// C is kept only while it is active. Expired (or legacy un-timestamped)
  /// state is cleared so callers naturally fall back to U via
  /// `cityAutoScopeProvider` / `locationProvider`.
  Future<SearchScope?> openSearchCenter() async {
    final userId = _currentUserId;
    if (userId == null) return null;

    await _restoreFuture;
    if (_currentUserId != userId || state == null) return state;

    final now = DateTime.now();
    if (shouldResetSearchCenter(lastActiveAt: _lastActiveAt, now: now)) {
      state = null;
      _lastActiveAt = null;
      final prefs = await SharedPreferences.getInstance();
      await _clearPersisted(prefs, userId);
      return null;
    }

    _lastActiveAt = now;
    try {
      final prefs = await SharedPreferences.getInstance();
      await _touch(prefs, userId, now);
    } catch (e) {
      debugPrint('[CityScope] touch failed for $userId: $e');
    }
    return state;
  }

  /// Update the active scope. Synchronously updates the in-memory state so
  /// consumers re-render immediately; persists to SharedPreferences
  /// asynchronously.
  Future<void> set(SearchScope? scope) async {
    _mutationVersion++;
    state = scope;
    final userId = _currentUserId;
    if (userId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_keyPrefix$userId';
      if (scope == null) {
        _lastActiveAt = null;
        await _clearPersisted(prefs, userId);
      } else {
        final now = DateTime.now();
        _lastActiveAt = now;
        await prefs.setString(key, jsonEncode(scope.toJson()));
        await _touch(prefs, userId, now);
      }
    } catch (e) {
      debugPrint('[CityScope] persist failed for $userId: $e');
    }
  }

  Future<void> _touch(SharedPreferences prefs, String userId, DateTime at) =>
      prefs.setInt('$_lastActiveAtKeyPrefix$userId', at.millisecondsSinceEpoch);

  Future<void> _clearPersisted(SharedPreferences prefs, String userId) async {
    await prefs.remove('$_keyPrefix$userId');
    await prefs.remove('$_lastActiveAtKeyPrefix$userId');
  }
}
