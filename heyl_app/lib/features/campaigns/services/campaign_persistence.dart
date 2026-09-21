import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists per-user fake-door-campaign response state to
/// SharedPreferences.
///
/// One bucket, storing a JSON-encoded `List<String>`:
/// * `campaign_v1_responded_<userId>` — campaign keys this user has already
///   responded to (submitted or dismissed). Optimistic-write-through from
///   `CampaignNotifier.markResponded`.
///
/// Mirrors `SpotlightPersistence` (PROD-2808) — server is authoritative for
/// "has this user responded", this is a read-through cache for instant
/// first-paint gating decisions.
///
/// For guests, callers pass the visitor_id as `userId` so cross-session
/// dismissals stick within the browser without ever hitting the backend.
class CampaignPersistence {
  CampaignPersistence(this._prefs);

  static const _respondedPrefix = 'campaign_v1_responded_';

  /// Global (not per-user) admin toggle for the Discovery warm-up
  /// auto-surfacing. Defaults on; an admin can flip it off from the menu to
  /// stop campaigns auto-popping while testing.
  static const _warmupEnabledKey = 'campaign_v1_warmup_enabled';

  final SharedPreferences _prefs;

  String _respondedKey(String userId) => '$_respondedPrefix$userId';

  /// Whether the Discovery warm-up auto-surfacing is enabled. Defaults to
  /// true when unset, so behaviour is unchanged until an admin flips it.
  bool readWarmupEnabled() => _prefs.getBool(_warmupEnabledKey) ?? true;

  Future<void> writeWarmupEnabled(bool enabled) =>
      _prefs.setBool(_warmupEnabledKey, enabled);

  Set<String> readResponded(String userId) => _readSet(_respondedKey(userId));

  Future<void> writeResponded(String userId, Set<String> responded) =>
      _writeSet(_respondedKey(userId), responded);

  Future<void> addResponded(String userId, String campaignKey) async {
    final current = readResponded(userId);
    current.add(campaignKey);
    await writeResponded(userId, current);
  }

  Future<void> clearForUser(String userId) async {
    await _prefs.remove(_respondedKey(userId));
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
