import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../utils/memory_family_label.dart';
import 'observation_row.dart';
import 'provenance_panel.dart';

class FamilySection extends StatelessWidget {
  final FamilyView family;
  final String? expandedObservationId;
  final void Function(String observationId) onToggle;
  final void Function(ObservationView observation) onDeleteObservation;
  final VoidCallback onClearCategory;

  const FamilySection({
    super.key,
    required this.family,
    required this.expandedObservationId,
    required this.onToggle,
    required this.onDeleteObservation,
    required this.onClearCategory,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final obs = [for (final dim in family.dimensions) ...dim.observations];
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  memoryFamilyLabel(context, family.family).toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.sokoInk,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.3,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  l10n.memoryFamilyCount(obs.length),
                  style: const TextStyle(
                    color: AppColors.sokoShade3,
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: onClearCategory,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.sokoShade3,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                  ),
                  child: Text(
                    l10n.memoryFamilyClearCategory,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: AppColors.sokoInk.withValues(alpha: 0.08),
              ),
            ),
            child: Column(
              children: [
                for (var i = 0; i < obs.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: AppColors.sokoInk.withValues(alpha: 0.08),
                    ),
                  ObservationRow(
                    observation: obs[i],
                    expanded: obs[i].id == expandedObservationId,
                    onTap: () => onToggle(obs[i].id),
                    onDeletePressed: obs[i].canDelete
                        ? () => onDeleteObservation(obs[i])
                        : null,
                  ),
                  if (obs[i].id == expandedObservationId)
                    ProvenancePanel(
                      observation: obs[i],
                      onDelete: obs[i].canDelete
                          ? () => onDeleteObservation(obs[i])
                          : null,
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
