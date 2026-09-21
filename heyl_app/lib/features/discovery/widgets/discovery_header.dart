import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../product_tour/models/tour_step.dart';
import '../../product_tour/providers/product_tour_controller.dart';
import '../providers/search_open_provider.dart';
import '../providers/search_query_provider.dart';
import 'scroll_memory_observer.dart';

/// Soko wordmark header for the Discovery page (PROD-1517).
///
/// Reuses the existing `soko-logo-paper.svg` asset and tints it with
/// [AppColors.sokoInk] in light mode (no tint in dark mode — the asset is
/// already paper-coloured). Width scales with the parent constraints to
/// roughly mirror the Figma 398/430 (~92.5%) ratio on mobile, capped on
/// desktop where no design exists yet.
///
/// PROD-2280: the wordmark is tappable and mirrors the bottom-nav Home
/// button — closes the Create sheet, closes the Discovery search overlay
/// (page-local state), and routes to `/`. Tour-step guard mirrors the
/// nav so a stray tap can't race the `profileMenu` cursor demo.
///
/// Source-of-truth design: `docs/ui/figma-cache/screens/discovery/header-chat-bar.md`.
class DiscoveryHeader extends ConsumerWidget {
  const DiscoveryHeader({super.key});

  void _onTap(BuildContext context, WidgetRef ref) {
    final tourStep = ref.read(
      productTourControllerProvider.select((s) => s.step),
    );
    if (tourStep == TourStep.profileMenu) return;
    ref.read(createMenuControllerProvider)?.close();
    if (ref.read(searchOpenProvider)) {
      ref.read(searchOpenProvider.notifier).state = false;
      ref.read(searchQueryProvider.notifier).state = '';
    }
    context.go(AppRoutes.home);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = Lt.of(context);
    final isDesktop = MediaQuery.of(context).size.width >= 1024;

    // Figma redesign — while the "Descobre a cidade" search is open the
    // wordmark gives way to a page-style header: back arrow (closes the
    // overlay, restoring the feed scroll) + centered title.
    if (ref.watch(searchOpenProvider)) {
      final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
      return Padding(
        padding: EdgeInsets.only(top: isDesktop ? 48.0 : 0.0),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 4),
              child: Text(
                l10n.discoveryActionBarDiscoverCity,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.displayPrimary(
                  fontSize: 32,
                  fontWeight: FontWeight.w300,
                  color: inkColor,
                  height: 0.95,
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: SokoBackButton(
                color: inkColor,
                onTap: () {
                  ref.read(searchOpenProvider.notifier).state = false;
                  ref.read(searchQueryProvider.notifier).state = '';
                  discoveryFeedScroll.restoreAfterSearch();
                },
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // TODO(desktop-redesign): no desktop designs yet. Cap the wordmark
        // width on wide viewports so it doesn't stretch awkwardly inside the
        // 600px DiscoveryShell content column.
        final width = (constraints.maxWidth * 0.925).clamp(0.0, 480.0);

        // D39: extra top breathing room on desktop. Mobile keeps the wordmark
        // close to the top because vertical real estate is tight; desktop has
        // room and the wordmark looks awkwardly stuck to the top edge without
        // it. See docs/ui/design-decisions.md.
        final topPad = isDesktop ? 48.0 : 0.0;

        return Padding(
          padding: EdgeInsets.only(top: topPad),
          child: Center(
            child: Semantics(
              header: true,
              button: true,
              label: l10n.discoveryHeaderLabel,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _onTap(context, ref),
                  child: SvgPicture.asset(
                    'assets/images/logos/soko-logo-paper.svg',
                    width: width,
                    colorFilter: isDark
                        ? null
                        : const ColorFilter.mode(
                            AppColors.sokoInk,
                            BlendMode.srcIn,
                          ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
