import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/clickable.dart';
import '../utils/zine_cover_recipe.dart';
import 'system_list_badge.dart';
import 'zine/list_zine_cover.dart';

/// Compact card widget for displaying a list in the hub
/// Designed to match the Lovable mockup style
class ListCard extends StatelessWidget {
  final UserList list;
  final VoidCallback? onTap;

  const ListCard({super.key, required this.list, this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark ? AppColors.surfaceDark : AppColors.surface;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    return Clickable(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Image section - rounded corners with overflow hidden.
          // 4:5 portrait per D110 (matches the list-page hero ratio so
          // the hub-card → cover-hero tap reads as a continuous
          // visual transition). ~4 px border radius.
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: AspectRatio(
              aspectRatio: 4 / 5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Image collage or placeholder
                  _buildImageSection(),

                  // Gradient overlay
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.1),
                          Colors.black.withValues(alpha: 0.5),
                        ],
                      ),
                    ),
                  ),

                  // Top-right indicators
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Visibility indicator (public / followers / private)
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: surfaceColor.withValues(alpha: 0.9),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            switch (list.visibility) {
                              ListVisibility.public => Icons.public,
                              ListVisibility.followers => Icons.group_outlined,
                              ListVisibility.private => Icons.lock_outline,
                            },
                            size: 12,
                            color: list.visibility == ListVisibility.public
                                ? primaryColor
                                : AppColors.textSecondary,
                          ),
                        ),
                        // Default list heart indicator
                        if (list.isDefault) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: surfaceColor.withValues(alpha: 0.9),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.favorite,
                              size: 12,
                              color: primaryColor,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // System-managed list badge (PROD-1741, extended in
                  // PROD-1953). Shown on any list the backend marks via
                  // `system_kind`. Anchored top-left so it doesn't fight
                  // with the visibility / default circles on the right.
                  // Pill (icon + "Auto") rather than icon-only so users
                  // can read the affordance at a glance on the hub.
                  if (list.isSystemManaged)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: SystemListBadge(
                        label: l10n.systemListBadgeAuto,
                        tooltip: l10n.systemListBadgeTooltip,
                        systemKind: list.systemKind,
                        onImage: true,
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Title and subtitle section (outside rounded image area)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title - matches Lovable: text-[15px] font-normal
                Text(
                  list.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w400, // font-normal
                    height: 1.3, // leading-snug
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // Creator subtitle - matches Lovable: text-[12px] text-muted-foreground/60
                Text(
                  list.isOwner ? l10n.listsCreatorYou : (list.ownerName ?? ''),
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        (isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary)
                            .withValues(alpha: 0.6),
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageSection() {
    // PROD-1918 batch 3 — every cover resolves through the single
    // `ZineCoverRecipe.fromUserList` factory so card / shelf / zine
    // surfaces stay in sync with the BE recipe. Without items, an
    // `cover_type=item_image` list falls through to solid colour mode
    // (deterministic by listId) — the BE follow-up for
    // `cover_item_image_url` will unlock photo mode here. Title +
    // logo are suppressed because the card already shows the list
    // name below the image.
    final recipe = ZineCoverRecipe.fromUserList(list);
    return ListZineCover(
      recipe: recipe,
      title: list.name,
      showTitle: false,
      showLogo: false,
    );
  }
}
