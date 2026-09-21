import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:heyl_app/core/services/unified_analytics_service.dart';
import 'package:heyl_app/core/theme/app_colors.dart';
import 'package:heyl_app/core/utils/auth_gating.dart';
import 'package:heyl_app/core/utils/hex_color.dart';
import 'package:heyl_app/data/datasources/api/share_failure.dart';
import 'package:heyl_app/data/models/share_asset.dart';
import 'package:heyl_app/features/lists/providers/cover_share_render_provider.dart';
import 'package:heyl_app/features/share/models/share_channel.dart';
import 'package:heyl_app/l10n/generated/l10n.dart';
import 'package:heyl_app/features/share/providers/share_asset_provider.dart';
import 'package:heyl_app/features/share/providers/share_controller.dart';
import 'package:heyl_app/features/share/widgets/share_channel_tile.dart';
import 'package:heyl_app/shared/notifications/heyl_notification.dart';
import 'package:heyl_app/shared/notifications/notification_state.dart';
import 'package:heyl_app/shared/utils/bottom_sheet_utils.dart';
import 'package:heyl_app/shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../utils/share_url_resolver.dart';

/// PROD-2785 — unified share sheet (Spotify-spirit) opened from every
/// per-surface share button. Replaces the previous mix of
/// `share_plus`-direct calls and the `ShareSheet` web sheet with a single
/// custom Soko-branded bottom sheet whose channel grid is the canonical
/// way to share anything outbound.
///
/// v1 (this PR):
///   - Static placeholder preview thumbnail (not the live share asset).
///   - 4-channel grid: Copy link, WhatsApp, Instagram Story, More.
///   - Tile taps log to console — controller wiring lands in Phase 3.
///
/// v2 (follow-ups):
///   - Live preview rendered from the channel-asset endpoint.
///   - Channel additions (TikTok Story, WhatsApp Status, X, Facebook Story).
///
/// Spec: docs/investigations/context/prod-2785-share-to-instagram-story-frontend.md
/// Instagram brand gradient used both for the in-sheet IG-Story tile
/// and for the surface-level direct-IG shortcut button. Exposed at
/// top-level so per-surface buttons (event/venue/list/zine/weekly-bundle)
/// can render the same gradient without duplicating the color stops.
const LinearGradient instagramGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [
    Color(0xFFFEDA75),
    Color(0xFFFA7E1E),
    Color(0xFFD62976),
    Color(0xFF962FBF),
    Color(0xFF4F5BD5),
  ],
);

class SokoShareSheet extends ConsumerStatefulWidget {
  const SokoShareSheet({
    super.key,
    required this.shareContext,
    required this.entityId,
    required this.shareUrl,
    this.shareUrlFuture,
    this.previewTitle,
    this.previewSubtitle,
    this.previewImageUrl,
    this.showPersonaCard = true,
    this.analyticsEntryPoint,
  });

  /// Overrides the `entry_point` on `share_intent_fired` for every tile
  /// tap in this sheet instance. Set to `shareDeepLinkEntryPoint`
  /// (`deep_link`) when the sheet was auto-presented by a `?share=` deep
  /// link (PROD-3319); null keeps the default `share_sheet`.
  final String? analyticsEntryPoint;

  /// When false, the sheet drops the persona-card preview and the card-only
  /// channels (Instagram Story, Save image) — leaving a plain link share (copy
  /// link / WhatsApp / system share). Used when sharing SOMEONE ELSE's profile,
  /// where the generated persona card (which is always the viewer's own) makes
  /// no sense.
  final bool showPersonaCard;

  /// The share context (`event`, `venue`, `list`, `list-item`,
  /// `weekly-bundle`, `daily-drop`, `persona`). Matches the backend's
  /// `{context}` path parameter for the share-asset endpoint.
  final String shareContext;

  /// The entity id (`me` for persona).
  final String entityId;

  /// The canonical Soko URL for the entity (used as the body of
  /// copy-link / WhatsApp / system-share, and as the fallback attribution
  /// URL for IG Story if the channel asset doesn't carry its own).
  ///
  /// PROD-4388 — when [shareUrlFuture] is supplied this is only the FALLBACK,
  /// used if the resolve fails. It is never handed to a channel before the
  /// future settles: the tiles stay busy until then, so the long URL cannot be
  /// copied out from under the resolve.
  final String shareUrl;

  /// The in-flight lookup of the short, previewable link. Null means the caller
  /// already has the final URL and no waiting is needed.
  ///
  /// The sheet opens immediately and the channel tiles show their existing busy
  /// spinner while this settles — the alternative, awaiting before opening,
  /// made the share button look dead for as long as the lookup took.
  final Future<String>? shareUrlFuture;

  /// No longer rendered — the live IG-Story PNG drives the preview tile,
  /// and the title is composed into that PNG by the BE. Kept on the API
  /// surface to avoid a breaking change for callers; will be removed in a
  /// follow-up cleanup PR.
  @Deprecated(
    'No longer rendered — the live IG-Story PNG drives the preview tile.',
  )
  final String? previewTitle;

  /// See [previewTitle].
  @Deprecated(
    'No longer rendered — the live IG-Story PNG drives the preview tile.',
  )
  final String? previewSubtitle;

  /// See [previewTitle].
  @Deprecated(
    'No longer rendered — the live IG-Story PNG drives the preview tile.',
  )
  final String? previewImageUrl;

  @override
  ConsumerState<SokoShareSheet> createState() => _SokoShareSheetState();
}

class _SokoShareSheetState extends ConsumerState<SokoShareSheet> {
  /// Anchor for the iOS system share sheet (`sharePositionOrigin`).
  /// share_plus throws `PlatformException(sharePositionOrigin: argument
  /// must be set)` on iOS when the argument is missing or Rect.zero —
  /// affects iPad universally (popover anchor) and iPhone under iOS 26
  /// modal-presentation rules. We resolve the More tile's global rect
  /// from this key at tap time and forward it to the controller.
  final GlobalKey _moreTileKey = GlobalKey();

  /// The URL the tiles will actually share. Starts null while
  /// [SokoShareSheet.shareUrlFuture] is in flight so every tile reads busy and
  /// refuses taps; a share can never go out with the fallback while the real
  /// link is still coming.
  String? _shareUrl;

  @override
  void initState() {
    super.initState();
    final pending = widget.shareUrlFuture;
    if (pending == null) {
      _shareUrl = widget.shareUrl;
      return;
    }
    pending
        .then((url) {
          if (mounted) setState(() => _shareUrl = url);
        })
        .catchError((_) {
          // resolveShareUrl already swallows failures and returns the
          // fallback; this only guards against a caller passing a future that
          // rejects. Either way the share still works, just with the long URL.
          if (mounted) setState(() => _shareUrl = widget.shareUrl);
        });
  }

  @override
  Widget build(BuildContext context) {
    // No URL yet -> every tile spins and ignores taps. Reuses the tile's
    // existing busy state rather than adding a second loading language.
    final resolving = _shareUrl == null;
    final showWhatsapp = !kIsWeb;
    final showInstagramStory = !kIsWeb && widget.showPersonaCard;

    final key = (shareContext: widget.shareContext, entityId: widget.entityId);
    final state = ref.watch(shareControllerProvider(key));

    // Toast + auto-pop on terminal states. Registered once per build;
    // Riverpod dedupes the listener so we don't fire twice on rebuilds.
    ref.listen<ShareState>(
      shareControllerProvider(key),
      (prev, next) => _handleStateTransition(context, ref, next),
    );

    final busyChannel = switch (state) {
      ShareLoading() => ShareChannel.instagramStory,
      ShareHandingOff(channel: final c) => c,
      _ => null,
    };

    // PROD-3217 — for list shares, disable the Stories tile while the cover is
    // (re)rendering after an edit, so a tap can't fire a share against a
    // not-yet-updated cover. Keyed by the list UUID, matching the render service.
    final coverBusy = widget.shareContext == 'list'
        ? ref.watch(coverRenderInProgressProvider(widget.entityId))
        : false;

    return DSSheetShell(
      header: _Header(title: Lt.of(context).sokoShareSheetTitle),
      bodyPadding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showPersonaCard) ...[
            _PreviewTile(
              shareContext: widget.shareContext,
              entityId: widget.entityId,
            ),
            const SizedBox(height: 24),
          ],
          _ChannelRow(
            children: [
              ShareChannelTile(
                icon: LucideIcons.link,
                label: Lt.of(context).shareTileCopyLink,
                busy: resolving || busyChannel == ShareChannel.copyLink,
                onTap: () => _fire(ShareChannel.copyLink),
              ),
              if (showWhatsapp)
                ShareChannelTile(
                  icon: LucideIcons.message_circle,
                  label: 'WhatsApp',
                  iconColor: Colors.white,
                  iconBackground: AppColors.whatsapp,
                  busy: resolving || busyChannel == ShareChannel.whatsapp,
                  onTap: () => _fire(ShareChannel.whatsapp),
                ),
              if (showInstagramStory)
                ShareChannelTile(
                  icon: LucideIcons.instagram,
                  label: Lt.of(context).shareTileStories,
                  iconColor: Colors.white,
                  iconBackgroundGradient: instagramGradient,
                  busy: resolving || busyChannel == ShareChannel.instagramStory || coverBusy,
                  onTap: () => _fire(ShareChannel.instagramStory),
                ),
              if (widget.showPersonaCard)
                ShareChannelTile(
                  icon: LucideIcons.download,
                  label: Lt.of(context).shareSaveImageLabel,
                  busy: resolving || busyChannel == ShareChannel.saveImage,
                  onTap: () => _fire(ShareChannel.saveImage),
                ),
              ShareChannelTile(
                key: _moreTileKey,
                icon: LucideIcons.ellipsis,
                label: Lt.of(context).shareTileMore,
                busy: resolving || busyChannel == ShareChannel.more,
                onTap: () => _fire(ShareChannel.more),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _fire(ShareChannel channel) {
    // Belt and braces: the tiles are already inert while resolving, but a
    // programmatic tap must not leak the fallback either.
    if (_shareUrl == null) return;
    final key = (shareContext: widget.shareContext, entityId: widget.entityId);
    // previewTitle / previewImageUrl stay as widget props for the
    // on-screen preview tile only — the controller no longer needs them
    // (the backend renders the IG-Story card from {context, id}).
    //
    // Only the `more` channel needs `sharePositionOrigin` — the OS share
    // sheet on iOS anchors from that rect. Other channels either use
    // their own composer (WhatsApp, Instagram) or don't touch the OS UI
    // at all (copyLink, saveImage).
    final origin = channel == ShareChannel.more ? _resolveMoreOrigin() : null;
    ref
        .read(shareControllerProvider(key).notifier)
        .share(
          channel: channel,
          // The RESOLVED url, never widget.shareUrl — that is only the
          // fallback, and _fire has already returned if it is still null.
          shareUrl: _shareUrl!,
          sharePositionOrigin: origin,
          entryPoint: widget.analyticsEntryPoint,
        );
  }

  Rect? _resolveMoreOrigin() {
    final box = _moreTileKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _handleStateTransition(
    BuildContext context,
    WidgetRef ref,
    ShareState next,
  ) {
    switch (next) {
      case ShareLinkCopied():
        showSoko(
          ref,
          message: Lt.of(context).shareListCopied,
          variant: SokoVariant.success,
        );
        _closeSheet(context, ref);
      case ShareImageSaved():
        showSoko(
          ref,
          message: Lt.of(context).shareSaveImageSuccessToast,
          variant: SokoVariant.success,
        );
        _closeSheet(context, ref);
      case ShareSuccess():
        // No toast — the IG composer / WhatsApp / system sheet is already
        // foregrounded; a Soko toast underneath would be noise.
        _closeSheet(context, ref);
      case ShareIgNotInstalled():
        showSoko(
          ref,
          message: Lt.of(context).shareInstagramNotInstalled,
          variant: SokoVariant.info,
        );
        _closeSheet(context, ref);
      case ShareWhatsappNotInstalled():
        showSoko(
          ref,
          message: Lt.of(context).shareWhatsappNotInstalled,
          variant: SokoVariant.info,
        );
        _closeSheet(context, ref);
      case ShareError(failure: final f):
        showSoko(
          ref,
          message: shareFailureMessage(Lt.of(context), f),
          variant: SokoVariant.error,
        );
        _closeSheet(context, ref);
      case ShareIdle():
      case ShareLoading():
      case ShareHandingOff():
        // Non-terminal states — busy spinner on the active tile is enough.
        break;
    }
  }

  void _closeSheet(BuildContext context, WidgetRef ref) {
    final key = (shareContext: widget.shareContext, entityId: widget.entityId);
    // Reset the controller AFTER popping so the next sheet open starts
    // fresh. Must be scheduled post-frame because pop() unmounts the
    // listener; resetting synchronously would re-fire the listener's
    // ShareIdle path before pop completes.
    Navigator.of(context, rootNavigator: true).pop();
    Future.microtask(() {
      if (ref.exists(shareControllerProvider(key))) {
        ref.read(shareControllerProvider(key).notifier).reset();
      }
    });
  }
}

/// Maps a [ShareFailure] to a user-facing toast message.
String shareFailureMessage(Lt l10n, ShareFailure f) {
  switch (f) {
    case ShareNotShareable():
      return l10n.shareErrorNotShareable;
    case ShareRateLimited():
      return l10n.shareErrorRateLimited;
    case ShareNetworkError():
      return l10n.shareErrorNetwork;
    case ShareUnknown(:final message, :final statusCode):
      if (message != null && message.isNotEmpty) {
        return l10n.shareErrorWithMessage(message);
      }
      // Surface the HTTP status so we don't shrug a "Try again." in
      // the user's face when the BE returned a 5xx / 404 / etc. with
      // an empty body (otherwise the cause is invisible client-side).
      if (statusCode != null) {
        return l10n.shareErrorWithStatus(statusCode.toString());
      }
      return l10n.shareErrorGeneric;
  }
}

/// Open [SokoShareSheet] as a modal bottom sheet with the standard
/// hide-the-bottom-nav chrome (PROD-1860). On web, where IG-Story +
/// WhatsApp tiles don't apply, the sheet still opens — falling through
/// to the Copy link + More tiles which work everywhere.
Future<void> showSokoShareSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String shareContext,
  required String entityId,
  required String shareUrl,
  @Deprecated('No longer rendered — see SokoShareSheet.previewTitle.')
  String? previewTitle,
  @Deprecated('No longer rendered — see SokoShareSheet.previewTitle.')
  String? previewSubtitle,
  @Deprecated('No longer rendered — see SokoShareSheet.previewTitle.')
  String? previewImageUrl,
  bool showPersonaCard = true,
  String? analyticsEntryPoint,
}) {
  // PROD-3115 — the share asset endpoint requires a real account; a guest
  // JWT 401s. Gate at the entry point (like the sibling Follow button) so
  // guests get the login prompt instead of a "Couldn't share (HTTP 401)"
  // toast. Authenticated users hit `onAuthenticated` synchronously — no
  // behaviour change.
  return requireAuth(
    context,
    ref,
    action: Lt.of(context).guestShareAction,
    referrer: AuthReferrer.guestShare,
    onAuthenticated: () {
      // PROD-4388 — resolve the short, previewable link HERE rather than in
      // each caller. Every share surface funnels through this function, so one
      // resolve covers them all; doing it per-caller is what left the zine page
      // (`list_page_screen.dart`) still emitting the 150-char URL after the
      // first pass.
      //
      // Started, NOT awaited. Awaiting here held the sheet closed for as long
      // as the lookup took, so the share button read as dead on a cold subject.
      // The sheet opens now and its tiles stay busy until this settles — so the
      // wait is visible, and the fallback URL still cannot be shared early.
      final pending = resolveShareUrl(
        ref: ref,
        shareContext: shareContext,
        entityId: entityId,
        localFallbackUrl: shareUrl,
      );

      // ignore: discarded_futures
      showBottomSheetWithHiddenNav<void>(
        context: context,
        ref: ref,
        backgroundColor: Colors.transparent,
        // ignore: deprecated_member_use_from_same_package
        builder: (_) => SokoShareSheet(
          shareContext: shareContext,
          entityId: entityId,
          shareUrl: shareUrl,
          shareUrlFuture: pending,
          showPersonaCard: showPersonaCard,
          analyticsEntryPoint: analyticsEntryPoint,
          // ignore: deprecated_member_use_from_same_package
          previewTitle: previewTitle,
          // ignore: deprecated_member_use_from_same_package
          previewSubtitle: previewSubtitle,
          // ignore: deprecated_member_use_from_same_package
          previewImageUrl: previewImageUrl,
        ),
      );
    },
  );
}

/// Sheetless direct-to-Instagram-Story shortcut. Fires the controller
/// immediately and opens IG as soon as the BE-rendered PNG is ready —
/// no intermediate bottom sheet, no preview view. Terminal states
/// (`IgNotInstalled` / `Error`) surface as Soko toasts; success is
/// silent (IG is now foregrounded).
///
/// Wired to the per-surface [IgDirectShareButton] on event, venue, list
/// header (zine detail), zine per-card viewer, and weekly-bundle overlay.
/// The picker path (share icon → [SokoShareSheet] → IG-Story tile →
/// paste-link instructions) is unchanged and still available via the
/// normal share button.
Future<void> shareDirectlyToInstagramStory({
  required BuildContext context,
  required WidgetRef ref,
  required String shareContext,
  required String entityId,
  required String shareUrl,
}) async {
  // PROD-3115 — same guest gate as `showSokoShareSheet`: the IG-Story asset
  // endpoint 401s for guest JWTs, so prompt login instead of firing the
  // controller. Authenticated users run `onAuthenticated` immediately.
  await requireAuth(
    context,
    ref,
    action: Lt.of(context).guestShareAction,
    referrer: AuthReferrer.guestShare,
    onAuthenticated: () async {
      // PROD-4388 — same choke-point resolve as `showSokoShareSheet`, so the
      // IG-Story tap-back matches what a chat share would carry.
      final resolvedUrl = await resolveShareUrl(
        ref: ref,
        shareContext: shareContext,
        entityId: entityId,
        localFallbackUrl: shareUrl,
      );
      if (!context.mounted) return;

      final key = (shareContext: shareContext, entityId: entityId);
      final notifier = ref.read(shareControllerProvider(key).notifier);

      // One-shot listener: terminal transitions surface a toast (or no-op
      // on success), then the listener closes itself and resets the
      // controller so the next tap starts fresh. Non-terminal states
      // (loading / handingOff) fall through.
      var handled = false;
      late final ProviderSubscription<ShareState> sub;
      void handleTerminal(ShareState next) {
        if (handled) return;
        handled = true;
        sub.close();
        Future.microtask(() {
          if (ref.exists(shareControllerProvider(key))) {
            notifier.reset();
          }
        });
      }

      sub = ref.listenManual<ShareState>(shareControllerProvider(key), (
        _,
        next,
      ) {
        switch (next) {
          case ShareSuccess():
            handleTerminal(next);
          case ShareIgNotInstalled():
            showSoko(
              ref,
              message: Lt.of(context).shareInstagramNotInstalled,
              variant: SokoVariant.info,
            );
            handleTerminal(next);
          case ShareError(failure: final f):
            showSoko(
              ref,
              message: shareFailureMessage(Lt.of(context), f),
              variant: SokoVariant.error,
            );
            handleTerminal(next);
          case ShareIdle():
          case ShareLoading():
          case ShareHandingOff():
          case ShareLinkCopied():
          case ShareImageSaved():
          case ShareWhatsappNotInstalled():
            // Non-terminal / unreachable-for-direct: ignore.
            break;
        }
      });

      // ignore: discarded_futures
      notifier.share(
        channel: ShareChannel.instagramStoryDirect,
        shareUrl: resolvedUrl,
      );
    },
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: const TextStyle(
            fontFamily: 'Zalando Sans',
            fontSize: 18,
            fontWeight: FontWeight.w500,
            height: 1.2,
            letterSpacing: -0.36,
            color: AppColors.sokoInk,
          ),
        ),
      ),
    );
  }
}

/// Preview tile. Renders the backend-rendered IG-Story PNG (via
/// [instagramStoryAssetProvider]) once the prefetch resolves; until then
/// shows a neutral skeleton + spinner. On error stays on the (spinner-less)
/// skeleton — never falls back to a "fake" entity hero photo, which used
/// to mask the live preview missing.
///
/// The 1080×1920 IG asset is letterboxed (`BoxFit.contain`) over a
/// gradient built from the asset's `background_top/bottom_color` hints so
/// the tile reads roughly like what IG will composite. No overlay text:
/// the title is already composed into the BE-rendered PNG.
class _PreviewTile extends ConsumerWidget {
  const _PreviewTile({required this.shareContext, required this.entityId});

  final String shareContext;
  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const radius = 16.0;
    final key = (shareContext: shareContext, entityId: entityId);
    final asset = ref.watch(instagramStoryAssetProvider(key));

    Widget clipped(Widget child) =>
        ClipRRect(borderRadius: BorderRadius.circular(radius), child: child);

    return asset.when(
      data: (a) {
        // Diagnostic — confirms the BE round-trip + file write
        // succeeded. Strip once the live preview is verified to
        // ship reliably in practice.
        debugPrint(
          '[share-sheet] live preview ready: ${a.imageFile?.path ?? '<web:bytes-only>'} '
          '(top=${a.backgroundTopColor}, '
          'bottom=${a.backgroundBottomColor})',
        );
        return clipped(_LivePreviewBackground(asset: a));
      },
      // The neutral grey block reads as "there's something coming here"
      // while the cycling caption underneath carries the "still working"
      // signal. Combining a spinner with the moving text was noisy.
      loading: () => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          clipped(const _PreviewSkeleton()),
          const SizedBox(height: 12),
          const _CyclingCaption(),
        ],
      ),
      error: (err, _) {
        debugPrint('[share-sheet] live preview failed: $err');
        return clipped(const _PreviewSkeleton());
      },
    );
  }
}

/// Neutral 240-px-tall placeholder shown while the share-asset prefetch
/// is in flight or has errored. Replaces the previous "static fallback"
/// that rendered the entity hero photo — that was a fake preview, since
/// the actual posted artwork is the BE-rendered PNG, not the entity photo.
class _PreviewSkeleton extends StatelessWidget {
  const _PreviewSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 240,
      color: AppColors.sokoInk.withValues(alpha: 0.06),
    );
  }
}

/// Rotates through a short set of "still working" phrases while the BE
/// renders the IG-Story PNG (typically 1–3 s). Sits under the preview
/// skeleton so the user has an active signal without a spinning wheel.
/// Uses [AnimatedSwitcher] for a soft crossfade — matches the Soko
/// brand's low-motion tone.
class _CyclingCaption extends StatefulWidget {
  const _CyclingCaption();

  @override
  State<_CyclingCaption> createState() => _CyclingCaptionState();
}

class _CyclingCaptionState extends State<_CyclingCaption> {
  static const _tick = Duration(milliseconds: 1200);
  static const _fade = Duration(milliseconds: 400);
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_tick, (_) {
      if (!mounted) return;
      setState(() => _index = _index + 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final phrases = <String>[
      l10n.shareIgDirectPreparing,
      l10n.sharePreviewLoadingComposing,
      l10n.sharePreviewLoadingAlmostReady,
    ];
    final phrase = phrases[_index % phrases.length];
    return Center(
      child: AnimatedSwitcher(
        duration: _fade,
        child: Text(
          phrase,
          key: ValueKey<String>(phrase),
          style: const TextStyle(
            fontFamily: 'Zalando Sans',
            fontSize: 14,
            fontWeight: FontWeight.w500,
            height: 1.35,
            color: AppColors.sokoInk,
          ),
        ),
      ),
    );
  }
}

/// Renders the backend-rendered IG-Story PNG as a centered, contained
/// image over the BE-supplied gradient (the same gradient IG composites
/// behind the sticker). The portrait asset is letterboxed inside the
/// landscape 140-px tile — the gradient fills the sides.
class _LivePreviewBackground extends StatelessWidget {
  const _LivePreviewBackground({required this.asset});

  final ShareAsset asset;

  @override
  Widget build(BuildContext context) {
    final top =
        parseHexColor(asset.backgroundTopColor) ?? const Color(0xFFFFB8CB);
    final bottom =
        parseHexColor(asset.backgroundBottomColor) ?? const Color(0xFFC05A6C);
    return Container(
      width: double.infinity,
      height: 240,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        // Render from the in-memory bytes, not `asset.imageFile`.
        // `dart:io.File` is a stub on Flutter web — `Image.file` paints
        // nothing, and the tile shows as an empty gradient rectangle
        // (visible in prod on app.soko.fyi). The bytes are already
        // decoded during the fetch (see `ShareAsset.imageBytes` +
        // `shares_api.dart:77`), so `Image.memory` works on every
        // platform without an extra I/O hop.
        child: Image.memory(asset.imageBytes, fit: BoxFit.contain),
      ),
    );
  }
}

/// Equally-spaced horizontal row of channel tiles. 4-tile design fits
/// comfortably on any phone width without horizontal scrolling.
class _ChannelRow extends StatelessWidget {
  const _ChannelRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
