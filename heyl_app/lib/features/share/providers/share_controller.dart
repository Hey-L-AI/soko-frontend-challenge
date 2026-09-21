import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart' show Share;
import 'package:social_share/social_share.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:heyl_app/core/services/instagram_story_handoff.dart';
import 'package:heyl_app/core/services/unified_analytics_service.dart';
import 'package:heyl_app/data/datasources/api/share_failure.dart';
import 'package:heyl_app/data/datasources/api/shares_api.dart';
import 'package:heyl_app/data/models/share_asset.dart';
import 'package:heyl_app/features/lists/providers/cover_share_render_provider.dart';
import 'package:heyl_app/features/share/models/share_channel.dart';
import 'package:heyl_app/features/share/providers/share_asset_provider.dart';
import 'package:heyl_app/features/share/utils/save_image_helper.dart';
import 'package:heyl_app/providers/api_provider.dart';

// ---------- State machine ----------

/// PROD-2785 — sealed state for [ShareController]. UI selects on this to
/// show idle / loading / handoff / success / error chrome.
sealed class ShareState {
  const ShareState();
}

class ShareIdle extends ShareState {
  const ShareIdle();
}

/// Fetching the channel asset from the backend (only IG Story today —
/// other channels short-circuit straight to handoff).
class ShareLoading extends ShareState {
  const ShareLoading();
}

/// Asset in hand; invoking the native handoff (IG Stories deeplink,
/// share_plus, SocialShare.shareWhatsapp, or the system share sheet).
class ShareHandingOff extends ShareState {
  const ShareHandingOff({required this.channel});
  final ShareChannel channel;
}

/// Channel handoff dispatched. UI shows a toast and resets after a delay
/// (callers can also `reset()` immediately if they pop the sheet).
class ShareSuccess extends ShareState {
  const ShareSuccess({required this.channel});
  final ShareChannel channel;
}

/// Copy-link variant of success — UI shows "Link copied" toast instead of
/// the generic "Shared" toast.
class ShareLinkCopied extends ShareState {
  const ShareLinkCopied();
}

/// Save-image variant of success — UI shows an "Image saved" toast
/// (native: "saved to Photos", web: "downloaded").
class ShareImageSaved extends ShareState {
  const ShareImageSaved();
}

/// IG Story handoff returned `false` — Instagram is not installed. UI
/// should show "Install Instagram to share to your Story" + an optional
/// "Save image" fallback (Phase 5).
class ShareIgNotInstalled extends ShareState {
  const ShareIgNotInstalled();
}

/// WhatsApp handoff returned `"error"` — WhatsApp is not installed (or
/// the URL scheme is blocked). Peer of [ShareIgNotInstalled]. UI shows
/// an "Install WhatsApp to share" info toast.
class ShareWhatsappNotInstalled extends ShareState {
  const ShareWhatsappNotInstalled();
}

/// Typed backend / native failure. UI maps to a localised toast.
class ShareError extends ShareState {
  const ShareError({required this.failure});
  final ShareFailure failure;
}

// ---------- Family parameter ----------

/// Record-keyed family parameter. Dart records have structural equality,
/// which is what Riverpod families need to dedupe state between rebuilds.
typedef ShareControllerKey = ({String shareContext, String entityId});

// ---------- Side-effect adapter ----------

/// Injectable platform side-effects so tests can stub them out without
/// mocking the static [Clipboard] / [Share] / [SocialShare] APIs. The
/// real implementation is wired by [shareSideEffectsProvider] below;
/// tests override the provider with mocks.
class ShareSideEffects {
  const ShareSideEffects({
    required this.copyToClipboard,
    required this.shareViaSystem,
    required this.shareViaWhatsapp,
    required this.saveImageToLibrary,
    required this.trackIntent,
    required this.trackCompleted,
  });

  final Future<void> Function(String text) copyToClipboard;
  final Future<String?> Function(String text, {Rect? sharePositionOrigin})
  shareViaSystem;
  final Future<String?> Function(String text) shareViaWhatsapp;
  final Future<void> Function(Uint8List bytes, {required String filename})
  saveImageToLibrary;
  final void Function({
    required ShareChannel channel,
    required String context,
    required String id,
    String? entryPoint,
  })
  trackIntent;
  final void Function({
    required ShareChannel channel,
    required String context,
    required String id,
    required String status,
    int? latencyMs,
    String? errorCode,
  })
  trackCompleted;
}

// ---------- Providers ----------

/// Default side-effects: wire to real Clipboard / share_plus /
/// SocialShare. Analytics callbacks fire `share_intent_fired` and
/// `share_completed` into [UnifiedAnalyticsService] — the client half
/// of the PROD-2784/2785 outbound share funnel (server emits
/// `share_descriptor_resolved` + `share_channel_asset_generated`).
final shareSideEffectsProvider = Provider<ShareSideEffects>((ref) {
  final analytics = ref.watch(unifiedAnalyticsProvider);
  return ShareSideEffects(
    copyToClipboard: (text) async {
      await Clipboard.setData(ClipboardData(text: text));
    },
    shareViaSystem: (text, {Rect? sharePositionOrigin}) async {
      // `Share.share` returns Future<void>; success is implicit (no throw).
      // The shareWithResult variant returns ShareResult.status, which we
      // don't need at this layer — the OS picker outcome doesn't affect
      // our state machine (we always emit ShareSuccess on no-throw).
      //
      // `sharePositionOrigin` is REQUIRED on iOS — share_plus throws
      // `PlatformException(sharePositionOrigin: argument must be set,
      // {{0,0},{0,0}} must be non-zero and within coordinate space of
      // source view)` when the argument is omitted or Rect.zero. The
      // caller (SokoShareSheet) computes the More tile's global rect
      // from its RenderBox and passes it here so iOS has a valid anchor
      // for the popover on iPad and a valid source frame on iPhone.
      await Share.share(text, sharePositionOrigin: sharePositionOrigin);
      return null;
    },
    shareViaWhatsapp: (text) async {
      // WhatsApp's official universal deep link. Prefer this over
      // `social_share.shareWhatsapp` (which uses the deprecated
      // `whatsapp://send?text=` scheme with a broken URL encoder —
      // `stringByAddingPercentEscapesUsingEncoding` doesn't percent-
      // encode `?`, `&`, or `=`, so a UTM-heavy share URL gets its
      // query string re-interpreted as WhatsApp URL params and the
      // message body is truncated; on iOS 10+ it also relies on the
      // deprecated `openURL:` variant which returns unreliably).
      //
      // `wa.me` handles installed-app deep-link handoff on both iOS
      // and Android (Universal Links / App Links), and falls back to
      // WhatsApp Web when the app isn't installed. `Uri.encodeQuery-
      // Component` guarantees the URL body survives WhatsApp's
      // parser intact.
      final uri = Uri.parse(
        'https://wa.me/?text=${Uri.encodeQueryComponent(text)}',
      );
      try {
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        return ok ? 'success' : 'error';
      } catch (_) {
        return 'error';
      }
    },
    saveImageToLibrary: (bytes, {required filename}) async {
      // `gal` on native, browser download on web — see
      // `save_image_helper.dart` for the conditional wiring.
      await SaveImageHelper().saveImageBytes(bytes, filename: filename);
    },
    trackIntent:
        ({required channel, required context, required id, entryPoint}) {
          analytics.trackShareIntent(
            context: context,
            subjectId: id,
            channel: channel.analyticsName,
            // Explicit entry point (e.g. `deep_link` for the PROD-3319
            // ?share= auto-present) wins; otherwise derive from the channel —
            // direct button uses the dedicated `instagramStoryDirect` channel,
            // every other channel comes from the picker sheet.
            entryPoint:
                entryPoint ??
                (channel == ShareChannel.instagramStoryDirect
                    ? 'direct_button'
                    : 'share_sheet'),
          );
        },
    trackCompleted:
        ({
          required channel,
          required context,
          required id,
          required status,
          int? latencyMs,
          String? errorCode,
        }) {
          analytics.trackShareCompleted(
            context: context,
            subjectId: id,
            channel: channel.analyticsName,
            status: status,
            latencyMs: latencyMs,
            errorCode: errorCode,
          );
        },
  );
});

/// Default [InstagramStoryHandoff] — uses the compile-time `FB_APP_ID`
/// dart-define (falls back to the staging app id baked into the wrapper).
final instagramStoryHandoffProvider = Provider<InstagramStoryHandoff>((ref) {
  return const InstagramStoryHandoff();
});

/// PROD-2785 — Riverpod family controller. One instance per
/// `(shareContext, entityId)` so two surfaces sharing different entities
/// at once don't stomp on each other's state.
final shareControllerProvider =
    StateNotifierProvider.family<
      ShareController,
      ShareState,
      ShareControllerKey
    >((ref, key) {
      return ShareController(
        key: key,
        sharesApi: ref.watch(sharesApiProvider),
        handoff: ref.watch(instagramStoryHandoffProvider),
        sideEffects: ref.watch(shareSideEffectsProvider),
        // Closure (not a stored Ref) so the controller can reuse the
        // share-sheet's pre-fetched asset without holding a Ref reference.
        fetchInstagramStoryAsset: () =>
            ref.read(instagramStoryAssetProvider(key).future),
        // PROD-3217 — share-if-missing. Only list shares carry a zine cover;
        // if the owner hasn't produced a render yet, capture+upload it before
        // the backend composites the card. Non-owners / already-rendered
        // lists / non-list contexts no-op. Kept as a closure so the
        // controller stays context/model-free and testable.
        ensureShareRenderReady: () async {
          if (key.shareContext != 'list') return false;
          // Owner-gated inside the service. `forShare: true` re-renders the
          // cover from a FRESH backend fetch and uploads it whenever the cover
          // drifted since its last upload, so the shared card is a pure
          // function of the current cover (no stale pixels, no
          // pixels-vs-signature race). When the stored render still matches the
          // current recipe it no-ops (PROD-3258) — the pregen-warmed card is
          // reused. On an actual re-upload the service invalidates
          // instagramStoryAssetProvider (keyed by the canonical UUID) so the
          // preview + this share re-fetch the fresh card.
          return ref
              .read(coverShareRenderServiceProvider)
              .renderAndUpload(listId: key.entityId, forShare: true);
        },
      );
    });

// ---------- Controller ----------

class ShareController extends StateNotifier<ShareState> {
  ShareController({
    required this.key,
    required this.sharesApi,
    required this.handoff,
    required this.sideEffects,
    required this.fetchInstagramStoryAsset,
    this.ensureShareRenderReady,
  }) : super(const ShareIdle());

  final ShareControllerKey key;
  final SharesApi sharesApi;
  final InstagramStoryHandoff handoff;
  final ShareSideEffects sideEffects;

  /// PROD-3217 — optional pre-share hook. For list shares it captures the
  /// zine cover and uploads it (`cover_share_render_url`) when missing, so
  /// the backend composites a faithful card instead of its plain fallback.
  /// Null / no-op for non-list contexts and in tests. Awaited (bounded) at
  /// the top of [_shareInstagramStory]; failures never block the share.
  final Future<bool> Function()? ensureShareRenderReady;

  /// Resolves the IG-Story [ShareAsset]. Wired by [shareControllerProvider]
  /// to read from [instagramStoryAssetProvider] so the share-sheet's
  /// preview prefetch and the IG-Story tap share one download. Tests
  /// override this directly with a stub.
  final Future<ShareAsset> Function() fetchInstagramStoryAsset;

  /// Wall-clock (microseconds since epoch) captured at the moment
  /// `share_intent_fired` is emitted. Used to attach `latency_ms` to the
  /// paired `share_completed` event. Reset on each new intent — the
  /// last intent's clock is the only one that matters for the funnel.
  int? _intentAtMicros;

  /// Per-controller cache of the resolved IG-Story asset.
  ///
  /// The upstream [instagramStoryAssetProvider] is `autoDispose` and its
  /// only listener is the preview tile in [SokoShareSheet]. When the sheet
  /// swaps to the IG instructions view the tile unmounts, the provider
  /// disposes, and the next `.future` read would re-fetch. Stashing the
  /// asset on the controller pins it for the sheet's lifetime; cleared in
  /// [reset] so a fresh sheet open starts empty.
  ShareAsset? _cachedIgAsset;

  /// Returns the cached asset if present, otherwise resolves it once and
  /// stashes it. All IG-Story reads must go through here.
  Future<ShareAsset> _resolveIgAsset() async {
    final cached = _cachedIgAsset;
    if (cached != null) return cached;
    final asset = await fetchInstagramStoryAsset();
    _cachedIgAsset = asset;
    return asset;
  }

  /// Dispatch [channel]. [shareUrl] is the canonical Soko URL for the
  /// entity (used as the body of copy-link / WhatsApp / more). For IG
  /// Story the backend renders the card from `(context, id)` alone and
  /// supplies its own attribution URL — [shareUrl] is ignored.
  ///
  /// [sharePositionOrigin] is only consulted for [ShareChannel.more] —
  /// share_plus requires a non-zero source rect on iOS (see
  /// `_shareSystem`).
  ///
  /// [entryPoint] overrides the channel-derived `entry_point` on
  /// `share_intent_fired` (e.g. `deep_link` when the sheet was
  /// auto-presented by a `?share=` deep link, PROD-3319). Null keeps the
  /// default `share_sheet` / `direct_button` derivation.
  Future<void> share({
    required ShareChannel channel,
    required String shareUrl,
    Rect? sharePositionOrigin,
    String? entryPoint,
  }) async {
    sideEffects.trackIntent(
      channel: channel,
      context: key.shareContext,
      id: key.entityId,
      entryPoint: entryPoint,
    );
    _intentAtMicros = DateTime.now().microsecondsSinceEpoch;

    switch (channel) {
      case ShareChannel.copyLink:
        await _copyLink(shareUrl);
      case ShareChannel.whatsapp:
        await _shareWhatsapp(shareUrl);
      case ShareChannel.more:
        await _shareSystem(shareUrl, sharePositionOrigin: sharePositionOrigin);
      case ShareChannel.instagramStory:
      case ShareChannel.instagramStoryDirect:
        await _shareInstagramStory(channel);
      case ShareChannel.saveImage:
        await _saveImage();
    }
  }

  /// Manually reset to [ShareIdle]. Callers should invoke this when the
  /// sheet pops, so the next open starts fresh regardless of where the
  /// previous flow ended.
  void reset() {
    if (!mounted) return;
    _cachedIgAsset = null;
    state = const ShareIdle();
  }

  Future<void> _copyLink(String shareUrl) async {
    try {
      await sideEffects.copyToClipboard(shareUrl);
      _emit(const ShareLinkCopied());
      _trackCompleted(ShareChannel.copyLink, status: 'success');
    } catch (e) {
      _emit(ShareError(failure: ShareUnknown(message: e.toString())));
      _trackCompleted(
        ShareChannel.copyLink,
        status: 'handoff_error',
        errorCode: 'clipboard_error',
      );
    }
  }

  Future<void> _saveImage() async {
    _emit(const ShareLoading());
    try {
      // Reuse the sheet's pre-fetched IG-Story asset — same PNG the
      // preview tile shows and the IG handoff would use. The BE
      // renders the card from `(context, id)` so there's no per-
      // channel variant to fetch.
      final asset = await _resolveIgAsset();
      _emit(const ShareHandingOff(channel: ShareChannel.saveImage));
      // File-name-safe stem; the helper appends the extension (native:
      // `gal` inspects the byte header; web: we hardcode `.png`).
      final filename = 'soko_${key.shareContext}_${key.entityId}'.replaceAll(
        '/',
        '_',
      );
      await sideEffects.saveImageToLibrary(
        asset.imageBytes,
        filename: filename,
      );
      _emit(const ShareImageSaved());
      _trackCompleted(ShareChannel.saveImage, status: 'success');
    } on ShareFailure catch (f) {
      _emit(ShareError(failure: f));
      _trackCompleted(
        ShareChannel.saveImage,
        status: 'handoff_error',
        errorCode: f.runtimeType.toString(),
      );
    } catch (e) {
      _emit(ShareError(failure: ShareUnknown(message: e.toString())));
      _trackCompleted(
        ShareChannel.saveImage,
        status: 'handoff_error',
        errorCode: 'unknown',
      );
    }
  }

  Future<void> _shareWhatsapp(String shareUrl) async {
    _emit(const ShareHandingOff(channel: ShareChannel.whatsapp));
    try {
      // `SocialShare.shareWhatsapp` returns `"success"` when the OS
      // dispatched the intent / URL scheme, or `"error"` (iOS: WhatsApp
      // isn't installed or `whatsapp` isn't in LSApplicationQueriesSchemes;
      // Android: ActivityNotFoundException). Prior code awaited without
      // reading the result, so a user tapping "WhatsApp" on a device
      // without WhatsApp saw the sheet silently close — no toast, no
      // signal. Treat anything other than `"success"` as a failure so
      // the state listener surfaces the "install WhatsApp" info toast.
      final result = await sideEffects.shareViaWhatsapp(shareUrl);
      if (result == 'success') {
        _emit(const ShareSuccess(channel: ShareChannel.whatsapp));
        _trackCompleted(ShareChannel.whatsapp, status: 'success');
      } else {
        _emit(const ShareWhatsappNotInstalled());
        _trackCompleted(
          ShareChannel.whatsapp,
          status: 'whatsapp_not_installed',
        );
      }
    } catch (e) {
      _emit(ShareError(failure: ShareUnknown(message: e.toString())));
      _trackCompleted(
        ShareChannel.whatsapp,
        status: 'handoff_error',
        errorCode: 'unknown',
      );
    }
  }

  Future<void> _shareSystem(
    String shareUrl, {
    Rect? sharePositionOrigin,
  }) async {
    _emit(const ShareHandingOff(channel: ShareChannel.more));
    try {
      await sideEffects.shareViaSystem(
        shareUrl,
        sharePositionOrigin: sharePositionOrigin,
      );
      _emit(const ShareSuccess(channel: ShareChannel.more));
      _trackCompleted(ShareChannel.more, status: 'success');
    } catch (e) {
      _emit(ShareError(failure: ShareUnknown(message: e.toString())));
      _trackCompleted(
        ShareChannel.more,
        status: 'handoff_error',
        errorCode: 'unknown',
      );
    }
  }

  Future<void> _shareInstagramStory(ShareChannel channel) async {
    _emit(const ShareLoading());
    try {
      // PROD-3217 — render+upload the list cover FIRST (share-if-missing) so
      // the backend composites the fresh PNG rather than its plain fallback.
      // Bounded + swallow-all: the share must never be blocked by this.
      final ensureRender = ensureShareRenderReady;
      if (ensureRender != null) {
        try {
          final coverChanged = await ensureRender().timeout(
            const Duration(seconds: 8),
          );
          // A new cover render was uploaded → the sheet's prefetched card (and
          // any card cached on this controller) is stale. Drop it so the fetch
          // below re-composites with the fresh cover. When unchanged, keep the
          // prefetch (fast, correct — no wasted re-render).
          if (coverChanged) _cachedIgAsset = null;
        } catch (_) {
          // Timeout / capture / upload failure → proceed; backend falls back
          // to a plain solid-colour cover.
        }
      }
      // Reuse the sheet's pre-fetched asset when available (instant).
      // Falls back to the live network fetch if the sheet didn't prefetch.
      final asset = await _resolveIgAsset();
      // PROD-3805 — the sticker pasteboard needs a real file path, which only
      // the native fetch produces (web builds `imageFile: null`). Direct
      // IG-Story is already native-only (the tiles are `kIsWeb`-gated), so this
      // is belt-and-suspenders: no file → treat as "IG can't take it".
      final contentImage = asset.imageFile;
      if (contentImage == null) {
        _emit(const ShareIgNotInstalled());
        _trackCompleted(channel, status: 'ig_not_installed');
        return;
      }
      _emit(ShareHandingOff(channel: channel));
      final dispatched = await handoff.shareToStory(
        contentImage: contentImage,
        attributionUrl: asset.attributionUrl,
        backgroundTopColor: asset.backgroundTopColor,
        backgroundBottomColor: asset.backgroundBottomColor,
      );
      if (dispatched) {
        _emit(ShareSuccess(channel: channel));
        _trackCompleted(channel, status: 'success');
      } else {
        _emit(const ShareIgNotInstalled());
        _trackCompleted(channel, status: 'ig_not_installed');
      }
    } on ShareFailure catch (f) {
      _emit(ShareError(failure: f));
      _trackCompleted(
        channel,
        status: 'handoff_error',
        errorCode: f.runtimeType.toString(),
      );
    } catch (e) {
      _emit(ShareError(failure: ShareUnknown(message: e.toString())));
      _trackCompleted(channel, status: 'handoff_error', errorCode: 'unknown');
    }
  }

  void _emit(ShareState next) {
    if (!mounted) return;
    state = next;
  }

  void _trackCompleted(
    ShareChannel channel, {
    required String status,
    String? errorCode,
  }) {
    final startedAt = _intentAtMicros;
    final latencyMs = startedAt == null
        ? null
        : ((DateTime.now().microsecondsSinceEpoch - startedAt) / 1000).round();
    _intentAtMicros = null;
    sideEffects.trackCompleted(
      channel: channel,
      context: key.shareContext,
      id: key.entityId,
      status: status,
      latencyMs: latencyMs,
      errorCode: errorCode,
    );
  }
}
