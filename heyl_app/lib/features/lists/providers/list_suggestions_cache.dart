import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../data/models/models.dart';

/// Persistent cache for smart-list suggestions, keyed by `listId + prompt`
/// + a scope fingerprint (PROD-2004 follow-up).
///
/// Avoids repeated ~5s `/places/search` calls when a user re-opens the same
/// list. When the prompt or the home-page city scope changes, the key
/// changes, so the old entry is naturally orphaned (cleaned up on the next
/// write that would overwrite it). The scope component prevents
/// Lisbon-fetched results from serving a user who has since switched home
/// to Porto.
class ListSuggestionsCache {
  static const String _keyPrefix = 'smart_list_suggestions_v1';
  static const Duration defaultTtl = Duration(hours: 24);

  String _key(String listId, String prompt, String scopeKey) {
    final fingerprint = sha1
        .convert(utf8.encode('$prompt|$scopeKey'))
        .toString();
    return '$_keyPrefix:$listId:$fingerprint';
  }

  /// Returns cached suggestions for `(listId, prompt, scopeKey)` if the
  /// entry exists and is younger than [ttl]. Returns `null` on miss,
  /// expiry, or malformed payload.
  Future<List<ItemSuggestion>?> read(
    String listId,
    String prompt, {
    required String scopeKey,
    Duration ttl = defaultTtl,
  }) async {
    if (prompt.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(listId, prompt, scopeKey));
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final cachedAt = DateTime.parse(decoded['cached_at'] as String);
      if (DateTime.now().difference(cachedAt) > ttl) return null;
      final items = decoded['items'] as List<dynamic>;
      return items
          .map((e) => ItemSuggestion.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ListSuggestionsCache] read failed: $e');
      return null;
    }
  }

  /// Writes the full (unfiltered) fetched suggestion list so that later reads
  /// can apply fresh `excludeIds` filtering on top of the same pool.
  Future<void> write(
    String listId,
    String prompt,
    List<ItemSuggestion> items, {
    required String scopeKey,
  }) async {
    if (prompt.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode({
      'cached_at': DateTime.now().toIso8601String(),
      'items': items.map((s) => s.toJson()).toList(),
    });
    await prefs.setString(_key(listId, prompt, scopeKey), payload);
  }

  /// Removes the cached entry for `(listId, prompt, scopeKey)`. Used by
  /// "Find more" to force a fresh backend call.
  Future<void> invalidate(
    String listId,
    String prompt, {
    required String scopeKey,
  }) async {
    if (prompt.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(listId, prompt, scopeKey));
  }
}

final listSuggestionsCacheProvider = Provider<ListSuggestionsCache>((ref) {
  return ListSuggestionsCache();
});
