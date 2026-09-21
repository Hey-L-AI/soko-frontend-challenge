import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'list_zine_item_page.dart' show kListZinePageMinHeight;

/// Loading skeleton for the zine view (PROD-1956). Renders during the
/// window between `loadList()` settling and the first `loadItems()`
/// batch returning — so opening a list no longer flashes the empty
/// "Esta edição está em branco" hero (owners) or a cover-only pager
/// (non-owners) before the real zine view paints.
///
/// Mimics the actual zine layout so the swap to the real view is
/// positionally stable: a 4:5 card-shaped block (matching
/// `max(width × 5/4, kListZinePageMinHeight)`), a 2-px progress-line
/// placeholder, a short description/note block, and an aux-content
/// block (where the map / calendar paints).
class ListZineSkeleton extends StatefulWidget {
  const ListZineSkeleton({super.key});

  @override
  State<ListZineSkeleton> createState() => _ListZineSkeletonState();
}

class _ListZineSkeletonState extends State<ListZineSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    // Same 1.4 s reverse pulse as `_ShimmerCard` in
    // `list_suggestions_section.dart` so loading states across the
    // list page share one shimmer cadence.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _opacity = Tween<double>(
      begin: 0.3,
      end: 0.7,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shimmer = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Padding(
      // Mirrors `ListZineView`'s 15-px horizontal pad so the skeleton
      // card aligns pixel-for-pixel with the real card on swap.
      padding: const EdgeInsets.symmetric(horizontal: 15),
      child: FadeTransition(
        opacity: _opacity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = constraints.maxWidth.isFinite
                    ? constraints.maxWidth
                    : 0.0;
                final cardHeight = math.max(
                  cardWidth * 5 / 4,
                  kListZinePageMinHeight,
                );
                return Container(
                  width: cardWidth,
                  height: cardHeight,
                  decoration: BoxDecoration(
                    color: shimmer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                );
              },
            ),
            // 8-px gap → 2-px progress-line placeholder, matching
            // `ZineProgressLine` spacing in the real view.
            const SizedBox(height: 8),
            Container(
              height: 2,
              decoration: BoxDecoration(
                color: shimmer,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            // Description / item-note slot: 12-px top gap then two
            // shimmer lines — matches the `AnimatedSwitcher` slot in
            // `ListZineView` that hosts `ListDescription`.
            const SizedBox(height: 12),
            Container(
              height: 12,
              width: 220,
              decoration: BoxDecoration(
                color: shimmer,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              height: 12,
              width: 160,
              decoration: BoxDecoration(
                color: shimmer,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            // Aux-content block: where `ListZineCoverAux` / map /
            // calendar paints in the real view.
            const SizedBox(height: 16),
            Container(
              height: 140,
              decoration: BoxDecoration(
                color: shimmer,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            // Bottom safe-area cushion to match `ListZineView`'s
            // final spacer.
            SizedBox(height: bottomInset + 20),
          ],
        ),
      ),
    );
  }
}
