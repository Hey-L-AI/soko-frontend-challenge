import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';

/// How many entries the panel shows — mirrors the server's serve cap
/// (Decision #31; the server may retain more than it serves).
const int kMapSearchHistoryDisplayCap = 10;

/// Owns the past-searches list for the map search bar's 0-chars state
/// (PROD-3499). Reads via [MapSearchHistoryApi]; deletes optimistically
/// (prune locally first, restore truth by re-fetching on server error).
///
/// Guests never fetch: the server answers 401 for guest tokens
/// (Decision #32), so `build()` short-circuits to an empty list — the panel
/// gates on auth separately to show the login explainer instead.
class MapSearchHistoryNotifier
    extends AutoDisposeAsyncNotifier<List<MapSearchHistoryEntry>> {
  // Riverpod 2.6.x doesn't expose `ref.mounted` on autoDispose notifiers;
  // this flag is the equivalent post-await guard (same workaround as
  // `yours_shelf_provider.dart`).
  bool _disposed = false;

  /// Bumped per [build]. Answers "was I superseded?", which [_disposed] does
  /// NOT — that one answers "is there a provider left to write to".
  ///
  /// This notifier watches [isAuthenticatedProvider], so a login or a logout
  /// rebuilds it, and a `list()` / `record()` already in the air belongs to the
  /// PREVIOUS identity. Without this token the response lands on the rebuilt
  /// state and shows the signed-out (or newly signed-in) reader the previous
  /// account's search history. The paged shelves have carried the same pair
  /// since PROD-2091; this provider copied only half of it.
  int _generation = 0;

  @override
  Future<List<MapSearchHistoryEntry>> build() async {
    // Riverpod runs the PREVIOUS build's `onDispose` before a rebuild, not
    // only on a real teardown, and preserves this notifier instance across
    // builds — so without clearing it here the flag latches on the first
    // rebuild (a login, here) and every guard below silently wins forever,
    // turning `silentRefresh` into a permanent no-op.
    _disposed = false;
    final generation = ++_generation;
    ref.onDispose(() {
      _disposed = true;
    });
    // Watched so a login while the map is open flips straight to a fetch
    // (guest CTA → login → return preserves the route).
    if (!ref.watch(isAuthenticatedProvider)) return const [];
    final rows = await ref.read(mapSearchHistoryApiProvider).list();
    // Riverpod discards a superseded build's VALUE, but an identity change
    // mid-fetch is worth being explicit about: return nothing rather than the
    // previous reader's rows.
    if (generation != _generation) return const [];
    return rows;
  }

  /// Re-fetch without a loading state — current rows stay on screen; on
  /// transient failure the last good list is kept.
  Future<void> silentRefresh() async {
    final generation = _generation;
    try {
      final fresh = await ref.read(mapSearchHistoryApiProvider).list();
      if (_disposed || generation != _generation) return;
      state = AsyncData(fresh);
    } catch (_) {
      // Keep the last good list.
    }
  }

  /// Per-row delete (Decision #31). Optimistic; a 404 means already gone
  /// (keep the prune), any other failure re-fetches to restore truth.
  Future<void> removeEntry(String entryId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData([
      for (final e in current)
        if (e.id != entryId) e,
    ]);
    try {
      await ref.read(mapSearchHistoryApiProvider).deleteEntry(entryId);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return;
      await silentRefresh();
    } catch (_) {
      await silentRefresh();
    }
  }

  /// Clear-all (Decision #31). Optimistic; returns false when the server
  /// call failed (list restored) so the confirm sheet can stay honest.
  Future<bool> clearAll() async {
    final current = state.valueOrNull;
    if (current == null) return false;
    state = const AsyncData([]);
    try {
      await ref.read(mapSearchHistoryApiProvider).clearAll();
      return true;
    } catch (_) {
      await silentRefresh();
      return false;
    }
  }

  /// Record an executed selection and bump it to the top locally (D6:
  /// re-selection bumps recency; the server upserts by `(type, target)`).
  ///
  /// Used by history-row re-execution now; PROD-3498 routes fresh dropdown
  /// selections through this too. Failures are swallowed — recording must
  /// never break the execution the user asked for.
  Future<void> recordSelection({
    required MapSearchHistoryType type,
    String? targetId,
    String? queryText,
    required String displayLabel,
    String? imageUrl,
  }) async {
    final generation = _generation;
    try {
      final entry = await ref
          .read(mapSearchHistoryApiProvider)
          .record(
            type: type,
            targetId: targetId,
            queryText: queryText,
            displayLabel: displayLabel,
            imageUrl: imageUrl,
          );
      if (_disposed || generation != _generation) return;
      final current = state.valueOrNull;
      if (current == null) return;
      state = AsyncData(
        [
          entry,
          for (final e in current)
            if (e.id != entry.id) e,
        ].take(kMapSearchHistoryDisplayCap).toList(),
      );
    } catch (e) {
      debugPrint('map search history record failed: $e');
    }
  }

  /// Remove an entry whose target failed to resolve on tap (Decision #21).
  /// Prunes locally AND deletes server-side — a dead target must not
  /// resurrect on the next fetch. Best-effort: the row is gone for this
  /// session either way, so server failures are swallowed.
  Future<void> removeStale(String entryId) async {
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData([
        for (final e in current)
          if (e.id != entryId) e,
      ]);
    }
    try {
      await ref.read(mapSearchHistoryApiProvider).deleteEntry(entryId);
    } catch (_) {
      // Best-effort cleanup; 404 or transient failure both fine.
    }
  }
}

/// autoDispose matches the map page's per-visit provider lifecycle
/// (`mapSearchProvider` etc.) — leaving `/map` resets it; the next focus
/// fetches fresh.
final mapSearchHistoryProvider =
    AsyncNotifierProvider.autoDispose<
      MapSearchHistoryNotifier,
      List<MapSearchHistoryEntry>
    >(MapSearchHistoryNotifier.new);
