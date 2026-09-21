import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../core/theme/app_colors.dart';
import '../../l10n/generated/l10n.dart';

/// Small amber pill marking a user manually designated as a **Local Legend**
/// ("Lenda Local"; backend `is_expert`, PROD-3336). Rendered next to a user's
/// name wherever it appears — profile header, "Shared by" attribution,
/// list-owner attribution, follower / following lists, and people search.
///
/// The tag is a curator/operator judgment call, orthogonal to any role — it is
/// not earned or algorithmic. Modelled on [SystemListBadge]'s pill chrome.
///
/// Use [compact] on tight rows (follow lists, search results) to render the
/// check-badge glyph only; the full variant adds the "Local Legend" label and
/// suits roomier surfaces like the profile header.
class ExpertBadge extends StatelessWidget {
  /// Icon-only when true (tight rows); icon + "Local Legend" label when false.
  final bool compact;

  const ExpertBadge({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    const fg = AppColors.amber;
    final fill = fg.withValues(alpha: 0.12);
    final icon = Icon(LucideIcons.badge_check, size: 12, color: fg);

    if (compact) {
      return Tooltip(message: l10n.expertBadgeTooltip, child: icon);
    }

    return Tooltip(
      message: l10n.expertBadgeTooltipFull,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(width: 4),
            Text(
              l10n.expertBadgeLabel,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
