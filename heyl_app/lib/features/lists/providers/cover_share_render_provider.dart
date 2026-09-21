import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../../core/router/app_router.dart';
import '../../../data/models/user_list.dart';
import '../../../providers/api_provider.dart';
import '../../share/providers/share_asset_provider.dart';
import '../utils/cover_signature.dart';
import '../utils/zine_cover_capture.dart';
import '../utils/zine_cover_recipe.dart';
import 'unified_list_provider.dart';

/// PROD-3217 — whether a cover render/upload is pending or in flight for a list.
/// The IG-Story share entry points watch this and show a disabled "Preparing
/// cover…" state while true, so a user can't share against a not-yet-updated
/// cover (the edit→immediately-share window). Correctness still rests on the
/// backend signature stale-guard; this is the UX layer on top. Flipped by
/// [CoverShareRenderService]: true when a debounced edit-render is scheduled or
/// a render is actively capturing/uploading, false once neither is outstanding.
final coverRenderInProgressProvider = StateProvider.family<bool, String>(
  (ref, listId) => false,
);

/// PROD-3217 — orchestrates capturing a list's zine cover to a PNG and
/// uploading it as `cover_share_render_url`, shared by both triggers:
///
/// * **Share** (`renderAndUpload(forShare: true)`, awaitable) — the IG-Story
///   share flow calls this before fetching the composited card. It captures
///   from a FRESH `getList` fetch and re-renders whenever the cover drifted
///   since its last upload, so the shared card is a pure function of the
///   current backend cover — never a stale/previous cover. When the stored
///   render still matches the current recipe it no-ops (PROD-3258), reusing the
///   pregen-warmed card instead of paying a redundant capture+upload+re-fetch.
/// * **Cover-save** (`scheduleRender`, debounced) — the change-cover sheet
///   calls this after every cover edit so the share stays warm in the
///   background (off the optimistic model).
///
/// Every path is best-effort: a capture/upload failure is swallowed, leaving
/// `cover_share_render_url` unchanged so the backend renders its plain
/// solid-colour fallback.
final coverShareRenderServiceProvider = Provider<CoverShareRenderService>((
  ref,
) {
  final service = CoverShareRenderService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// PROD-3258 — whether [list]'s stored share-render still matches its current
/// cover recipe, so a share can skip the redundant capture+upload+re-fetch and
/// reuse the pregen-warmed card.
///
/// True only when a render was previously uploaded ([UserList.coverShareRenderUrl]
/// present) AND the signature stamped on it ([UserList.coverShareRenderSignature])
/// equals the signature of the current recipe. This is exactly the predicate the
/// backend stale-guard applies at share time, so a match guarantees the backend
/// composites the stored render rather than the plain fallback.
@visibleForTesting
bool storedRenderMatchesCurrentCover(UserList list) {
  final url = list.coverShareRenderUrl;
  final sig = list.coverShareRenderSignature;
  return url != null &&
      url.isNotEmpty &&
      sig != null &&
      sig == computeCoverRenderSignature(list);
}

class CoverShareRenderService {
  CoverShareRenderService(this._ref);

  final Ref _ref;

  /// Per-list debounce timers so rapid successive edits collapse into a
  /// single render+upload of the final cover, and two lists don't interfere.
  final Map<String, Timer> _debounce = {};

  /// In-flight render futures per list so a share that coincides with the
  /// debounced cover-save awaits the same render instead of double-capturing.
  final Map<String, Future<bool>> _inFlight = {};

  /// Flip the shared "render in progress" flag for [listId] (drives the
  /// share-button "Preparing cover…" state). Guarded so an unchanged value
  /// doesn't churn listeners.
  void _setRendering(String listId, bool value) {
    final controller = _ref.read(
      coverRenderInProgressProvider(listId).notifier,
    );
    if (controller.state != value) controller.state = value;
  }

  /// Debounced entry point for cover edits (Trigger B). Collapses a burst of
  /// swatch/texture/photo taps into one render of the settled cover. Marks the
  /// list as "rendering" immediately so the share button disables during the
  /// debounce window (a render is expected — the user just edited).
  void scheduleRender(
    String listId, {
    Duration delay = const Duration(milliseconds: 800),
  }) {
    _setRendering(listId, true);
    _debounce[listId]?.cancel();
    _debounce[listId] = Timer(delay, () {
      _debounce.remove(listId);
      // Fire-and-forget; renderAndUpload swallows its own errors. A cover
      // edit always re-renders (onlyIfMissing:false) — the cover changed.
      unawaited(renderAndUpload(listId: listId));
    });
  }

  /// Immediate, awaitable render+upload. Owner-gated. Never throws.
  ///
  /// [listId] may be a slug or a UUID — the share flow passes the entity UUID
  /// while the list page loads state under the route slug, so the model is
  /// resolved robustly.
  ///
  /// [forShare] — the IG-Story share path. When true we ALWAYS render and we
  /// capture from a FRESH `getList` fetch (never the in-memory model, which can
  /// be stale: keyed under the route slug, or carrying an optimistic edit the
  /// backend hasn't reconciled). This makes the shared PNG a pure function of
  /// the current backend cover — no pixels-vs-signature race, no stale card.
  /// The debounced cover-save path leaves it false: a cheap background
  /// pre-warm off the optimistic model.
  ///
  /// Coalesces with any in-flight render for the same list so the share awaits
  /// the fresh result rather than racing a second capture.
  ///
  /// Returns `true` when a render was uploaded, `false` when it no-op'd (not
  /// owner / capture failed).
  Future<bool> renderAndUpload({
    required String listId,
    bool forShare = false,
  }) {
    final running = _inFlight[listId];
    if (running != null) return running;
    final future = _renderAndUpload(listId, forShare);
    _inFlight[listId] = future;
    return future.whenComplete(() {
      if (identical(_inFlight[listId], future)) _inFlight.remove(listId);
      // Clear the "rendering" flag unless a fresh edit re-armed the debounce
      // while this render was running.
      if (_debounce[listId] == null) _setRendering(listId, false);
    });
  }

  Future<bool> _renderAndUpload(String listId, bool forShare) async {
    try {
      // We're rendering now — supersede any pending debounced render.
      _debounce.remove(listId)?.cancel();

      // Resolve the recipe. The share path ALWAYS captures from a FRESH backend
      // fetch so the pixels reflect the CURRENT cover; the in-memory model can
      // be stale (keyed under the route slug, or an optimistic edit not yet
      // reconciled with the server-resolved fields, e.g. cover_item_image_url).
      // The background edit-render can trust the optimistic model (fast, and it
      // carries the edit the user just made).
      final list = forShare
          ? await _ref.read(listsApiProvider).getList(listId)
          : (_ref.read(unifiedListProvider(listId)).list ??
                await _ref.read(listsApiProvider).getList(listId));

      if (!list.isOwner) {
        _breadcrumb(
          'skip: not owner',
          level: SentryLevel.debug,
          listId: listId,
        );
        return false;
      }

      // PROD-3258 — if the stored render already matches the CURRENT cover,
      // skip the capture+upload entirely. The fresh `getList` above is
      // authoritative: when its recipe signature equals the signature stamped
      // on the stored render, the backend will composite that stored render
      // (its stale-guard passes) and the upload-time pregen already has the
      // IG-Story card warm in cache — so the share is a hit instead of a full
      // re-render + re-upload + re-fetch. We only re-render when the cover
      // actually drifted since its last upload (or none exists yet). Returning
      // false here means "no change": the caller keeps the sheet's prefetched
      // (warm) asset instead of invalidating it. Correctness still rests on the
      // backend signature guard — a rare skip that turns out stale composites
      // the plain fallback, never a wrong cover.
      if (forShare && storedRenderMatchesCurrentCover(list)) {
        _breadcrumb(
          'skip: cover unchanged since last upload (signature match)',
          listId: listId,
        );
        return false;
      }

      // A render is happening; disable the share button.
      _setRendering(listId, true);

      // The root navigator's OverlayState — mount target for the offscreen
      // capture. Use `.currentState.overlay` directly, NOT
      // `Overlay.of(currentContext)`: the navigator's context is above its
      // overlay, so an ancestor lookup returns null and the capture no-ops.
      final overlay = _ref
          .read(appRouterProvider)
          .routerDelegate
          .navigatorKey
          .currentState
          ?.overlay;
      if (overlay == null) {
        _breadcrumb(
          'skip: no overlay',
          level: SentryLevel.warning,
          listId: listId,
        );
        return false;
      }

      // Build the recipe from the model alone — no items collection needed;
      // `item_image` covers resolve their photo via the server-set
      // `coverItemImageUrl` (PROD-1932).
      final recipe = ZineCoverRecipe.fromUserList(list);
      _breadcrumb('rendering cover (${recipe.type.name})', listId: listId);

      final png = await captureZineCoverPng(
        overlay: overlay,
        recipe: recipe,
        title: list.name,
      );
      if (png == null) {
        // Capture failed (e.g. a cover photo that never loaded). Skip the
        // upload rather than store a photoless render — the backend stale-guard
        // then shows the plain fallback, never a stale/wrong cover.
        _breadcrumb(
          'capture returned null (skip upload → BE plain fallback)',
          level: SentryLevel.warning,
          listId: listId,
        );
        return false;
      }

      final updated = await _ref
          .read(listsApiProvider)
          .uploadListCoverShareRender(listId, png);
      _breadcrumb(
        'uploaded ${png.length}B (forShare=$forShare)',
        listId: listId,
      );

      // Push the fresh cover_share_render_url back into state if the list is
      // loaded under [listId] (best-effort; the backend is the source of
      // truth for the next share regardless).
      _ref
          .read(unifiedListProvider(listId).notifier)
          .mergeServerRenderUrl(updated);

      // PROD-3217 — the cover changed, so any IG-Story card the share sheet
      // prefetched (or a previous share cached) is now stale. Invalidate the
      // asset provider keyed by the CANONICAL list id so the preview tile
      // re-fetches AND the next share composites the fresh cover. Use
      // `updated.id` (UUID) — the share sheet keys on the list's UUID, which
      // may differ from the slug/route id passed in as [listId].
      _ref.invalidate(
        instagramStoryAssetProvider((
          shareContext: 'list',
          entityId: updated.id,
        )),
      );
      return true;
    } catch (e) {
      _breadcrumb('failed: $e', level: SentryLevel.error, listId: listId);
      debugPrint('[cover-share-render] renderAndUpload($listId) failed: $e');
      return false;
    }
  }

  void _breadcrumb(
    String message, {
    SentryLevel level = SentryLevel.info,
    required String listId,
  }) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: message,
        category: 'cover_share_render',
        level: level,
        data: {'list_id': listId},
      ),
    );
  }

  void dispose() {
    for (final timer in _debounce.values) {
      timer.cancel();
    }
    _debounce.clear();
  }
}
