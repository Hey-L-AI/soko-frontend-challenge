// Unified search — the focused overlay. Opening search anywhere but the map
// pushes this: the input pill + chips pin to the top of a `sokoPaper` panel, the
// grouped results scroll beneath, and the rest of the page dims behind it (tap
// the dim or the ✕ to dismiss). It is the same shape as the onboarding search
// hosts the full [UnifiedContentSearch] (all-Soko content search with toggle
// chips) so the feed, library and onboarding all get the identical experience —
// onboarding wires its like / close-on-like / detail add-ons through it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../soko_search_input_pill.dart';
import 'unified_content_results_view.dart' show kUnifiedContentCategories;
import 'unified_content_search.dart'
    show CatalogueUnifiedSearchSource, UnifiedContentSearchSource;
import 'unified_content_search_view.dart';
import 'unified_search_models.dart';

/// Shared-element tags: the collapsed entry (feed Procura circle / library search
/// icon) flies into the overlay's input pill. Distinct per surface so the two
/// entries can coexist in a kept-alive tab stack without a Hero-tag collision.
const String kFeedSearchHeroTag = 'unified-search:feed';
const String kLibrarySearchHeroTag = 'unified-search:library';

/// Flight shuttle for the search Hero: a neutral rounded box carrying the
/// pill's resting outline + magnifier, shown while the collapsed entry grows
/// into the input. Rendering a placeholder (not the live field, which
/// autofocuses) keeps the mid-flight frame clean; the real pill lands when the
/// flight settles.
Widget unifiedSearchHeroFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromContext,
  BuildContext toContext,
) {
  return Material(
    type: MaterialType.transparency,
    child: DecoratedBox(
      decoration: SokoSearchInputPill.decorationFor(kSokoSearchInputRadius),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 18),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Icon(LucideIcons.search, size: 18, color: AppColors.sokoInk),
        ),
      ),
    ),
  );
}

/// Push the unified search overlay. Resolves when it is dismissed.
///
/// [heroTag] wires the shared-element flight from the collapsed entry; null
/// falls back to the plain barrier fade.
Future<void> openUnifiedSearchOverlay(
  BuildContext context, {
  required String hintText,
  List<SokoSearchCategory> categories = kUnifiedContentCategories,
  UnifiedContentSearchSource source = const CatalogueUnifiedSearchSource(),
  bool showCategoryChips = true,
  double? latitude,
  double? longitude,
  bool guestWall = false,
  Object? heroTag,
  bool showLike = false,
  String? provenance,
  void Function(UnifiedSearchRow row, bool nowLiked)? onLikeToggled,
  bool Function(UnifiedSearchRow row)? onOpen,
  void Function(String query)? onSearch,
  bool closeOnLike = false,
  String? emptyLabel,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: AppColors.sokoInk.withValues(alpha: 0.35),
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, __, ___) => _UnifiedSearchOverlay(
        hintText: hintText,
        categories: categories,
        source: source,
        showCategoryChips: showCategoryChips,
        latitude: latitude,
        longitude: longitude,
        guestWall: guestWall,
        heroTag: heroTag,
        showLike: showLike,
        provenance: provenance,
        onLikeToggled: onLikeToggled,
        onOpen: onOpen,
        onSearch: onSearch,
        closeOnLike: closeOnLike,
        emptyLabel: emptyLabel,
      ),
      transitionsBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    ),
  );
}

class _UnifiedSearchOverlay extends StatelessWidget {
  const _UnifiedSearchOverlay({
    required this.hintText,
    required this.categories,
    required this.source,
    required this.showCategoryChips,
    required this.latitude,
    required this.longitude,
    required this.guestWall,
    required this.heroTag,
    required this.showLike,
    required this.provenance,
    required this.onLikeToggled,
    required this.onOpen,
    required this.onSearch,
    required this.closeOnLike,
    required this.emptyLabel,
  });

  final String hintText;
  final List<SokoSearchCategory> categories;
  final UnifiedContentSearchSource source;
  final bool showCategoryChips;
  final double? latitude;
  final double? longitude;
  final bool guestWall;
  final Object? heroTag;
  final bool showLike;
  final String? provenance;
  final void Function(UnifiedSearchRow row, bool nowLiked)? onLikeToggled;
  final bool Function(UnifiedSearchRow row)? onOpen;
  final void Function(String query)? onSearch;
  final bool closeOnLike;
  final String? emptyLabel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Cap the panel so a tall result set never fills the whole screen — the
        // dimmed tail stays visible (and tappable to dismiss). Subtract the
        // keyboard inset so the panel's scrollable sits above the IME.
        final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
        final safeTop = MediaQuery.of(context).padding.top;
        final availableHeight = constraints.maxHeight - keyboardInset;
        final maxPanelHeight = availableHeight * 0.9;
        final maxPanelWidth =
            constraints.maxWidth < PageLayout.desktopBreakpoint
            ? double.infinity
            : PageLayout.desktopContentMaxWidth;
        return Stack(
          children: [
            // Tap the dimmed area behind the panel to dismiss.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
            // No SafeArea here: the paper runs to the very top edge so the
            // status-bar strip reads as part of the panel instead of showing
            // the dim barrier behind it. The inset is paid as padding instead.
            //
            // Because the strip is now light `sokoPaper` rather than the dim,
            // the status-bar icons must be dark or they vanish. Nothing else in
            // the app sets an overlay style, so this route would otherwise
            // inherit whatever the page underneath left behind. Note the two
            // fields read backwards from each other: `statusBarIconBrightness`
            // (Android) names the ICONS, `statusBarBrightness` (iOS) names the
            // BACKGROUND — both values below mean "dark icons on light".
            AnnotatedRegion<SystemUiOverlayStyle>(
              value: const SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.dark,
                statusBarBrightness: Brightness.light,
              ),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: maxPanelHeight,
                    maxWidth: maxPanelWidth,
                  ),
                  child: Material(
                    color: AppColors.sokoPaper,
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(16),
                    ),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 12 + safeTop, 16, 12),
                      child: UnifiedContentSearch(
                        hintText: hintText,
                        categories: categories,
                        source: source,
                        showCategoryChips: showCategoryChips,
                        latitude: latitude,
                        longitude: longitude,
                        guestWall: guestWall,
                        fillHeight: true,
                        inputHeroTag: heroTag,
                        inputHeroFlightShuttleBuilder:
                            unifiedSearchHeroFlightShuttle,
                        showLike: showLike,
                        provenance: provenance,
                        onSearch: onSearch,
                        onOpen: onOpen,
                        // A result tap the host doesn't fully handle closes this
                        // overlay before navigating, so the detail isn't pushed
                        // under the dim barrier.
                        onDismiss: () => Navigator.of(context).maybePop(),
                        emptyLabel: emptyLabel,
                        onLikeToggled: (row, nowLiked) {
                          onLikeToggled?.call(row, nowLiked);
                          // closeOnLike: a like is the step's completion — drop
                          // back to where the reader was (mirrors onboarding).
                          if (closeOnLike && nowLiked) {
                            Navigator.of(context).maybePop();
                          }
                        },
                        // The ✕ on an empty field dismisses the overlay.
                        onCloseWhenEmpty: () =>
                            Navigator.of(context).maybePop(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
