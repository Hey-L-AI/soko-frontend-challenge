import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bt_sq_ico.dart';

/// Shown in place of the zine body when the items request failed.
///
/// **Why this exists.** `UnifiedListNotifier.loadItems` catches its own
/// failures: it records `state.error` and clears `isLoadingItems`, but leaves
/// `itemsLoaded` false and `items` empty. Nothing on `ListPageScreen` ever read
/// `state.error`, so that combination rendered the zine view's "items are still
/// loading" static cover — forever. No spinner, no message, no retry, and (on a
/// short page) nothing even scrollable. Reported 2026-09-15 on a zine that
/// simply sat there.
///
/// Metadata and items are two separate requests fired in parallel
/// (`unified_list_provider.dart` — `loadList()` + `loadItems()`), which is what
/// makes "header rendered, body empty" a reachable steady state rather than a
/// momentary frame.
///
/// Pull-to-refresh already recovered this (`refreshListDetail` via the shell),
/// but nothing on screen said so. This makes the failure legible and the
/// recovery tappable.
class ZineLoadErrorState extends StatelessWidget {
  /// Re-runs the full load (metadata + items). Wire to the notifier's
  /// `refresh()`, the same call pull-to-refresh makes.
  final VoidCallback onRetry;

  const ZineLoadErrorState({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 48, 15, 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.circle_alert,
            size: 40,
            color: AppColors.sokoInk.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.listPagesLoadError,
            textAlign: TextAlign.center,
            style: AppTheme.body(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.sokoInk.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 20),
          // Design-system CTA, matching the sibling empty state's button
          // (`EmptyZineState`) — the two states sit at the same spot on the
          // same screen and should not look like two different products.
          Center(
            child: BtSqIco(
              icon: LucideIcons.rotate_cw,
              label: l10n.commonRetry,
              variant: BtSqIcoVariant.selected,
              onTap: onRetry,
            ),
          ),
        ],
      ),
    );
  }
}
