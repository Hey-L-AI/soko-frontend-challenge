import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists per-user feature-spotlight state to SharedPreferences.
///
/// Two buckets, both storing a JSON-encoded `List<String>`:
/// * `feature_spotlight_v1_seen_<userId>` — spotlights this user has
///   dismissed / CTA-tapped. Optimistic-write-through from `markSeen`.
/// * `feature_spotlight_v1_disabled_<userId>` — mirror of the server's
///   `disabled` set at last successful `_syncFromServer`. Cached across
///   sessions so cold-start eligibility decisions don't run against an
///   empty set before the network round-trip completes (would otherwise
///   race the pre-fire delay in `SpotlightTrigger` — see the notifier's
///   `build()` comment). Server remains authoritative.
///
/// Bumping the `v1` prefix naturally re-triggers every spotlight for
/// every user — use when the tooltip UX itself changes, not for
/// content-only tweaks (which should bump the individual spotlight
/// `_vN` suffix instead).
///
/// For guests, callers pass the visitor_id as `userId` so cross-session
/// dismissals stick within the browser without ever hitting the backend.
class SpotlightPersistence {
  SpotlightPersistence(this._prefs);

  static const _seenPrefix = 'feature_spotlight_v1_seen_';
  static const _disabledPrefix = 'feature_spotlight_v1_disabled_';

  final SharedPreferences _prefs;

  String _seenKey(String userId) => '$_seenPrefix$userId';
  String _disabledKey(String userId) => '$_disabledPrefix$userId';

  Set<String> readSeen(String userId) => _readSet(_seenKey(userId));

  Future<void> writeSeen(String userId, Set<String> seen) =>
      _writeSet(_seenKey(userId), seen);

  Future<void> addSeen(String userId, String featureId) async {
    final current = readSeen(userId);
    current.add(featureId);
    await writeSeen(userId, current);
  }

  Set<String> readDisabled(String userId) => _readSet(_disabledKey(userId));

  Future<void> writeDisabled(String userId, Set<String> disabled) =>
      _writeSet(_disabledKey(userId), disabled);

  Future<void> clearForUser(String userId) async {
    await _prefs.remove(_seenKey(userId));
    await _prefs.remove(_disabledKey(userId));
  }

  Set<String> _readSet(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return {};
      return decoded.whereType<String>().toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeSet(String key, Set<String> value) async {
    await _prefs.setString(key, jsonEncode(value.toList()));
  }
}
