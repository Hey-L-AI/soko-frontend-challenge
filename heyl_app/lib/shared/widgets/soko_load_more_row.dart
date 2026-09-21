import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// A full-width tappable "load a deeper tier" row, shared by the two search
/// surfaces that offer a manual deeper search: the map area picker's "Load more"
/// (deep `POST /geo/search`) and the Business Connect venue search's "Find more"
/// (transient Google search, PROD-4270 S5). One widget so the two deep tiers
/// look identical.
///
/// Carries a quiet `sokoShade5` tint — enough to separate it from the white
/// result rows above without competing with them — and a `sokoInk` 15/600
/// label (never white, per the design-system contrast rule). 48 px min height
/// keeps the tap target accessible.
///
/// A null [onTap] renders the row disabled (dimmed, no ink response) — used to
/// block duplicate activation while a search is already in flight.
class SokoLoadMoreRow extends StatelessWidget {
  const SokoLoadMoreRow({
    super.key,
    required this.label,
    this.onTap,
    this.highlighted = false,
  });

  final String label;

  /// Tap handler. Null disables the row (dimmed, non-interactive).
  final VoidCallback? onTap;

  /// Keyboard highlight (the caller's ArrowDown reached this row): a 3 px
  /// `sokoInk` leading bar and `selected` semantics. The row keeps its tint,
  /// so the bar — not colour alone — carries the state (PROD-4295).
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: AppColors.sokoShade5,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          button: true,
          enabled: enabled,
          selected: highlighted,
          liveRegion: highlighted,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            decoration: highlighted
                ? const BoxDecoration(
                    border: Border(
                      left: BorderSide(color: AppColors.sokoInk, width: 3),
                    ),
                  )
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: enabled ? AppColors.sokoInk : AppColors.sokoShade3,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
