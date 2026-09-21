import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:turn_page_transition/turn_page_transition.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/weekly_bundle.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../feature_spotlight/widgets/spotlight_trigger.dart';
import '../../share/widgets/ig_direct_share_button.dart';
import '../../share/widgets/soko_share_sheet.dart';
import '../providers/weekly_bundle_provider.dart';

/// Full-screen Weekly Bundle overlay with journal-style page viewer.
///
/// Shows one journal page at a time with a realistic page-turn animation
/// using the turn_page_transition package. All pages are preloaded on mount.
class WeeklyBundleOverlay extends ConsumerStatefulWidget {
  const WeeklyBundleOverlay({super.key, this.openReason});

  /// PROD-2564 — analytics open-reason for the `weekly_bundle_open` event fired
  /// on mount: `'deep_link'` when reached via the `/weekly-bundle` deep link,
  /// `null` for a normal in-app open.
  final String? openReason;

  @override
  ConsumerState<WeeklyBundleOverlay> createState() =>
      _WeeklyBundleOverlayState();
}

class _WeeklyBundleOverlayState extends ConsumerState<WeeklyBundleOverlay> {
  late TurnPageController _turnController;
  late final UnifiedAnalyticsService _analytics;
  int _currentPage = 0;
  Timer? _pagePoller;

  // Snapshot of bundle metadata mirrored from the provider on every
  // build. Used by `dispose()` for the close-event payload — calling
  // `ref.read` from `dispose` throws "Cannot use 'ref' after the widget
  // was disposed" once the overlay is popped imperatively (e.g. from
  // `_openAsZine`'s pop-then-push), since the State is already detached
  // from the provider scope by then.
  String? _lastBatchId;
  int? _lastPageCount;

  @override
  void initState() {
    super.initState();
    _analytics = ref.read(unifiedAnalyticsProvider);
    _turnController = TurnPageController();

    // Poll currentIndex periodically — the most reliable way to track
    // page changes with TurnPageController, since its ChangeNotifier
    // fires during drag animations (not just on settle) and the
    // onTap/onSwipe callbacks have inconsistent timing.
    _pagePoller = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      final idx = _turnController.currentIndex;
      if (idx != _currentPage) {
        // Track page view
        final bundle = ref.read(weeklyBundleProvider).bundle;
        _analytics.trackWeeklyBundlePageView(
          batchId: bundle?.batchId,
          pageIndex: idx,
          pageCount: bundle?.pageCount,
        );
        setState(() => _currentPage = idx);
      }
    });

    // Preload all page images after first frame and track open
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadImages();

      final bundle = ref.read(weeklyBundleProvider).bundle;
      _analytics.trackWeeklyBundleOpen(
        batchId: bundle?.batchId,
        itemCount: bundle?.itemCount,
        pageCount: bundle?.pageCount,
        // PROD-2564: `deep_link` for a deep-link landing, null for an in-app
        // open. This is the single `weekly_bundle_open` fire — the Discovery
        // section no longer fires it (was double-counting).
        reason: widget.openReason,
      );
    });
  }

  void _preloadImages() {
    final bundle = ref.read(weeklyBundleProvider).bundle;
    if (bundle == null) return;
    for (final url in bundle.pageImageUrls) {
      precacheImage(CachedNetworkImageProvider(url), context);
    }
  }

  @override
  void dispose() {
    // Track close event — use the snapshot fields, not `ref.read`, since
    // the ProviderScope is no longer reachable from this State once the
    // overlay is being torn down imperatively.
    _analytics.trackWeeklyBundleClose(
      batchId: _lastBatchId,
      lastPageViewed: _currentPage,
      pageCount: _lastPageCount,
    );
    _pagePoller?.cancel();
    _turnController.dispose();
    super.dispose();
  }

  /// PROD-1953: opens the bundle as a full list-zine view via the
  /// existing `/lists/:listId?view=zine` route. The backend materializes
  /// the bundle into an auto-managed "This Week" system list
  /// (`system_kind=weekly_bundle`) and surfaces its id on the bundle
  /// response — this method is only wired up when [WeeklyBundle.listId]
  /// is non-null.
  void _openAsZine(String listId) {
    final bundle = ref.read(weeklyBundleProvider).bundle;
    // Reuses the existing `weekly_bundle_items_toggle` event with a new
    // `view=zine` value (over adding a new event + contract entry +
    // backend endpoint just for this navigation). Same semantic family:
    // "user requested a different view of the bundle".
    _analytics.trackWeeklyBundleItemsToggle(
      batchId: bundle?.batchId,
      view: 'zine',
    );
    // `/weekly-bundle` is a root-level GoRoute; `/lists/:id` lives inside
    // the ShellRoute. `pushReplacement` doesn't cleanly cross navigator
    // boundaries, and a synchronous `pop + push` races with the overlay's
    // disposal (`context` becomes invalid for the second call). Capture
    // the router first, pop the overlay, then push on the next frame —
    // the documented pattern (see `_popThenPushList` in
    // `create_zine_screen.dart`, plus
    // `docs/learnings/rootnavigator-overlay-hides-gorouter-push.md`).
    final router = GoRouter.of(context);
    final pendingRoute = '/lists/$listId?view=zine';
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      router.push(pendingRoute);
    });
  }

  /// PROD-2785 — open the unified [SokoShareSheet] for the current
  /// weekly bundle. A weekly bundle is a system-managed list under the
  /// hood, so we share it as the underlying `list` context (the BE's
  /// `ShareContext` enum doesn't include `weekly-bundle`). Falls back
  /// to a no-op when the bundle hasn't been materialised into a list
  /// yet (e.g. the cron is mid-render).
  void _handleShare(WeeklyBundle bundle) {
    final listId = bundle.listId;
    if (listId == null) return;
    showSokoShareSheet(
      context: context,
      ref: ref,
      shareContext: 'list',
      entityId: listId,
      shareUrl: _bundleFallbackUrl(listId),
    );
  }

  /// The locally-built URL, passed as the fallback on both share paths. The
  /// short, previewable link is swapped in by the share helpers (PROD-4388);
  /// this is what a failed or slow lookup degrades to.
  String _bundleFallbackUrl(String listId) =>
      '${ApiConstants.webappUrl}/lists/$listId'
      '?utm_source=soko_app&utm_medium=share'
      '&utm_campaign=list_share&utm_content=$listId';

  /// Same wiring as [_handleShare] but fires the direct-to-IG handoff.
  void _handleIgDirectShare(WeeklyBundle bundle) {
    final listId = bundle.listId;
    if (listId == null) return;
    shareDirectlyToInstagramStory(
      context: context,
      ref: ref,
      shareContext: 'list',
      entityId: listId,
      shareUrl: _bundleFallbackUrl(listId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bundleState = ref.watch(weeklyBundleProvider);
    final bundle = bundleState.bundle;

    // Mirror fields needed by `dispose`'s close-event so we never read
    // from `ref` after the widget is detached.
    if (bundle != null) {
      _lastBatchId = bundle.batchId;
      _lastPageCount = bundle.pageCount;
    }

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // Backdrop
          Positioned.fill(
            child: GestureDetector(
              onTap: () => context.pop(),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: Container(color: Colors.black.withValues(alpha: 0.7)),
              ),
            ),
          ),

          // Journal viewer
          if (bundle != null && bundle.hasPages)
            _buildJournalViewer(context, bundle)
          else
            const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildJournalViewer(BuildContext context, WeeklyBundle bundle) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    // Journal page dimensions (9:16 aspect ratio, fitting the screen)
    final maxPageHeight = screenHeight * 0.82;
    final pageWidth = min(maxPageHeight * (9 / 16), screenWidth - 32);
    final pageHeight = pageWidth * (16 / 9);

    return SafeArea(
      child: Column(
        children: [
          // Top bar
          Padding(
            // Web: push the chrome down so it hugs the book; native keeps the
            // tighter top inset for thumb-reach ergonomics.
            padding: kIsWeb
                ? const EdgeInsets.fromLTRB(16, 32, 16, 2)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Page counter
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${_currentPage + 1} / ${bundle.pageCount}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                // Right-side cluster: View-as-Zine, Share, Close.
                // Grouped so the page counter stays pinned left and the
                // actions stay pinned right, regardless of which of the
                // gated buttons happen to render this build.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // PROD-1953: "View as Zine" — opens the bundle's
                    // materialized list (`system_kind=weekly_bundle`) at
                    // `/lists/:id?view=zine`. Hidden while the backend
                    // hasn't yet returned a `list_id` so the affordance
                    // never appears broken; the in-overlay flipbook stays
                    // the sole experience in that case.
                    if (bundle.listId != null) ...[
                      Semantics(
                        button: true,
                        label: Lt.of(context).weeklyBundleViewAsZine,
                        child: BtSqIco(
                          icon: LucideIcons.list,
                          label: Lt.of(context).weeklyBundleViewAsZine,
                          variant: BtSqIcoVariant.selected,
                          onTap: () => _openAsZine(bundle.listId!),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    // PROD-2785: Share button — opens the unified
                    // SokoShareSheet (Copy link / WhatsApp / IG Story /
                    // More…). IG-Story + WhatsApp tiles auto-hide on
                    // web inside the sheet. Gated on batchId so we never
                    // offer a share that has no backend identity. Visual
                    // matches the zine-detail header share button
                    // (`list_page_header.dart#_HeaderActionButton`) —
                    // 40×40 Soko/Shade5 chip with the 14 px share glyph.
                    if (bundle.batchId != null) ...[
                      _HeaderActionButton(
                        icon: LucideIcons.share,
                        onTap: () => _handleShare(bundle),
                        semanticLabel: Lt.of(context).weeklyBundleActionShare,
                      ),
                      if (!kIsWeb) ...[
                        const SizedBox(width: 8),
                        SpotlightTrigger(
                          featureId: 'ig_share_v1',
                          targetCornerRadius: 20,
                          targetPadding: const EdgeInsets.all(4),
                          onCtaAction: () => _handleIgDirectShare(bundle),
                          child: IgDirectShareButton(
                            // Solid sokoLilac fill so the IG shortcut stands
                            // out from the faint sibling share chip. Glyph
                            // stays at 14 px (sibling chip size) so the
                            // 40 px row still aligns.
                            fillColor: AppColors.sokoLilac,
                            iconSize: 14,
                            shareContext: 'list',
                            entityId: bundle.listId ?? '',
                            onTap: () => _handleIgDirectShare(bundle),
                          ),
                        ),
                      ],
                      const SizedBox(width: 8),
                    ],
                    // Close button
                    GestureDetector(
                      onTap: () => context.pop(),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.15),
                        ),
                        child: const Icon(
                          LucideIcons.x,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Main content area
          Expanded(child: _buildPageArea(bundle, pageWidth, pageHeight)),

          // Page indicator dots
          if (bundle.pageCount > 1)
            Padding(
              // Web: pull dots up against the book; native keeps the original
              // inset.
              padding: kIsWeb
                  ? const EdgeInsets.only(top: 2, bottom: 32)
                  : const EdgeInsets.only(bottom: 12, top: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  bundle.pageCount,
                  (index) => AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: index == _currentPage ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: index == _currentPage
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPageArea(
    WeeklyBundle bundle,
    double pageWidth,
    double pageHeight,
  ) {
    return Center(
      child: SizedBox(
        width: pageWidth,
        height: pageHeight,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: TurnPageView.builder(
            controller: _turnController,
            itemCount: bundle.pageCount,
            animationTransitionPoint: 0.5,
            overleafColorBuilder: (_) => const Color(0xFFF0EBE3),
            itemBuilder: (context, index) {
              return CachedNetworkImage(
                imageUrl: bundle.pageImageUrls[index],
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  color: const Color(0xFFF5F0E8),
                  child: const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                errorWidget: (_, __, ___) => Container(
                  color: const Color(0xFFF5F0E8),
                  child: Center(
                    child: Icon(
                      LucideIcons.image_off,
                      size: 32,
                      color: const Color(0xFF3D2B1F).withValues(alpha: 0.3),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 40×40 circular header action button — Soko/Shade5 fill, 14 px icon.
/// Visual matches the zine-detail share button at
/// `features/lists/widgets/list_page_header.dart#_HeaderActionButton`
/// (Figma frame 9221). Duplicated inline rather than extracted because
/// the design-system primitive doesn't exist yet; PROD-2785 §3 calls
/// this out as a known extraction opportunity.
class _HeaderActionButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String semanticLabel;

  const _HeaderActionButton({
    required this.icon,
    required this.onTap,
    required this.semanticLabel,
  });

  @override
  State<_HeaderActionButton> createState() => _HeaderActionButtonState();
}

class _HeaderActionButtonState extends State<_HeaderActionButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticLabel,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) {
            setState(() => _isPressed = false);
            widget.onTap();
          },
          onTapCancel: () => setState(() => _isPressed = false),
          child: AnimatedScale(
            scale: _isPressed ? 0.95 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sokoShade5,
              ),
              child: Center(
                child: Icon(widget.icon, size: 14, color: AppColors.sokoInk),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
