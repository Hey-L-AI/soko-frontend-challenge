import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../utils/memory_certainty.dart';
import '../utils/memory_polarity.dart';

class ObservationRow extends StatelessWidget {
  final ObservationView observation;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback? onDeletePressed;

  const ObservationRow({
    super.key,
    required this.observation,
    required this.expanded,
    required this.onTap,
    this.onDeletePressed,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final pol = polarityVisuals(observation.polarity);
    final ticks = certaintyTicks(observation.certainty);
    final isLow = observation.certainty < 0.5;
    final canDelete = observation.canDelete && onDeletePressed != null;
    final badge = _sourceBadge(l10n, observation);

    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: isLow ? 0.62 : 1,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: pol.background,
                  shape: BoxShape.circle,
                ),
                child: Icon(pol.icon, size: 14, color: pol.foreground),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      observation.value,
                      style: const TextStyle(
                        color: AppColors.sokoInk,
                        fontSize: 16,
                        fontWeight: FontWeight.w300,
                        height: 1.2,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _SourceBadge(
                          label: badge.label,
                          background: badge.background,
                        ),
                        const SizedBox(width: 6),
                        _CertaintyMeter(ticks: ticks),
                      ],
                    ),
                  ],
                ),
              ),
              if (canDelete)
                IconButton(
                  icon: const Icon(
                    LucideIcons.trash_2,
                    size: 16,
                    color: AppColors.sokoShade3,
                  ),
                  onPressed: onDeletePressed,
                  tooltip: l10n.memoryActionDeleteThisMemory,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Source badge (label + color) for the collapsed row, keyed off where the
/// memory came from (provenance_kind, PROD-2331). Pink for memories that came
/// from you (message / onboarding / location / action); blue for Soko's guesses
/// (inferred). Legacy payloads (provenanceKind == null, pre-PROD-2331) fall back
/// to the older stated-vs-guessed heuristic.
({String label, Color background}) _sourceBadge(Lt l10n, ObservationView o) {
  switch (o.provenanceKind) {
    case 'message':
      return (label: l10n.memoryBadgeStated, background: AppColors.sokoPink);
    case 'onboarding':
      return (
        label: l10n.memoryBadgeOnboarding,
        background: AppColors.sokoPink,
      );
    case 'location':
      return (label: l10n.memoryBadgeLocation, background: AppColors.sokoPink);
    case 'action':
      return (label: l10n.memoryBadgeAction, background: AppColors.sokoPink);
    case 'activity':
      return (label: l10n.memoryBadgeActivity, background: AppColors.sokoPink);
    case 'inferred':
      return (label: l10n.memoryBadgeGuessed, background: AppColors.sokoBlue);
    default:
      return o.isUserStated
          ? (label: l10n.memoryBadgeStated, background: AppColors.sokoPink)
          : (label: l10n.memoryBadgeGuessed, background: AppColors.sokoBlue);
  }
}

class _SourceBadge extends StatelessWidget {
  final String label;
  final Color background;
  const _SourceBadge({required this.label, required this.background});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.sokoInk,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.2,
        ),
      ),
    );
  }
}

class _CertaintyMeter extends StatelessWidget {
  final int ticks; // 1..4
  const _CertaintyMeter({required this.ticks});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 4; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Container(
                width: 3,
                height: 8,
                decoration: BoxDecoration(
                  color: i < ticks
                      ? AppColors.sokoShade1
                      : AppColors.sokoShade4,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
