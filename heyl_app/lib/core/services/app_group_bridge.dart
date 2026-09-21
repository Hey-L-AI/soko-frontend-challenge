import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bridges Flutter state into the iOS App Group `group.ai.heyl.heylApp` so the
/// iOS Share Extension can read auth, base URL, locale, and a denormalized
/// list snapshot without making network calls.
///
/// All methods are no-ops on non-iOS platforms. Method-channel failures are
/// caught and logged — never let an App Group write break the host app.
class AppGroupBridge {
  AppGroupBridge._();

  static final AppGroupBridge instance = AppGroupBridge._();

  static const MethodChannel _channel = MethodChannel(
    'ai.heyl.app_group_bridge',
  );

  bool get _enabled => !kIsWeb && Platform.isIOS;

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod(method, args);
    } catch (e) {
      debugPrint('[AppGroupBridge] $method failed: $e');
    }
  }

  Future<T?> _invokeForResult<T>(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    if (!_enabled) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (e) {
      debugPrint('[AppGroupBridge] $method failed: $e');
      return null;
    }
  }

  // ── Auth ─────────────────────────────────────────────────────────────────

  Future<void> writeAuth({required String token, DateTime? expiresAt}) =>
      _invoke('writeAuth', {
        'token': token,
        'expiresAtMs': expiresAt?.millisecondsSinceEpoch,
      });

  Future<void> clearAuth() => _invoke('clearAuth');

  // ── Environment ──────────────────────────────────────────────────────────

  Future<void> writeBaseUrl(String url) =>
      _invoke('writeBaseUrl', {'baseUrl': url});

  Future<void> writeLocale(String tag) =>
      _invoke('writeLocale', {'locale': tag});

  // ── Lists snapshot ───────────────────────────────────────────────────────

  Future<void> writeLists(List<AppGroupListSnapshot> lists) =>
      _invoke('writeLists', {
        'lists': lists.map((l) => l.toJson()).toList(),
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      });

  // ── Share-result handoff ─────────────────────────────────────────────────

  /// Returns the JSON map written by the extension at
  /// `soko.share.last_terminal.v1`, or null if no payload is present.
  Future<Map<String, dynamic>?> readShareResult() async {
    final raw = await _invokeForResult<dynamic>('readShareResult');
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return null;
  }

  /// Returns the in-flight share payload (mirrors `StorageService.loadActiveInstagramShare`)
  /// written by the extension when it hands off polling to the host app.
  Future<Map<String, dynamic>?> readShareInFlight() async {
    final raw = await _invokeForResult<dynamic>('readShareInFlight');
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return null;
  }

  /// Removes both the terminal blob and in-flight payload after the host app
  /// has consumed them.
  Future<void> clearShareKeys() => _invoke('clearShareKeys');

  // ── Wipe ─────────────────────────────────────────────────────────────────

  /// Clears every key the bridge owns. Call on logout / account deletion.
  Future<void> clearAll() => _invoke('clearAll');
}

/// Minimal denormalized list shape consumed by the Share Extension's picker.
/// Kept tiny on purpose — App Group UserDefaults has size limits and the
/// extension only needs id + display name + a flag marking backend-managed
/// lists (PROD-2725, schema v2). Backend-managed lists — IG auto-list,
/// onboarding seed, saved items, weekly bundle, user contributions — are
/// hidden from the picker since users never add to them directly. Pre-v2
/// the flag was `isFromInstagram` and only the IG auto-list was hidden.
class AppGroupListSnapshot {
  const AppGroupListSnapshot({
    required this.id,
    required this.name,
    required this.isSystemManaged,
  });

  final String id;
  final String name;
  final bool isSystemManaged;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'isSystemManaged': isSystemManaged,
  };
}

final appGroupBridgeProvider = Provider<AppGroupBridge>((ref) {
  return AppGroupBridge.instance;
});
