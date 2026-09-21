import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../utils/memory_certainty.dart';
import '../utils/memory_dimension_header.dart';
import '../utils/memory_hierarchy.dart';
import '../utils/memory_value_label.dart';
import 'memory_ticks.dart';
import 'provenance_panel.dart';

/// Slim family rendering used inside a [ParentSection]. Now renders one
/// sub-section per **dimension** (e.g. `cuisine.preferred` =
/// "adoras" + chips; `cuisine.avoided` = "evitas" + chips) instead of
/// merging them under a single family header. Each sub-section opens with
/// a Soko-voice line from [memoryDimensionHeader] and the chip text comes
/// from [humanizeMemoryValue], so canonical strings like `outdoor_seating`
/// never reach the eye.
class CompactFamilySection extends StatelessWidget {
  final FamilyView family;
  final MemoryParent parent;
  final String? expandedObservationId;
  final void Function(String observationId) onToggle;
  final void Function(DimensionView dimension, ObservationView observation)
  onDeleteObservation;
  final void Function(
    DimensionView dimension,
    ObservationView observation,
    bool increase,
  )
  onNudgeObservation;
  final VoidCallback onClearCategory;

  const CompactFamilySection({
    super.key,
    required this.family,
    required this.parent,
    required this.expandedObservationId,
    required this.onToggle,
    required this.onDeleteObservation,
    required this.onNudgeObservation,
    required this.onClearCategory,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final chipBg = memoryParentChipBackground(parent);

    final renderable = family.dimensions
        .where((d) => d.observations.isNotEmpty)
        .toList();
    if (renderable.isEmpty) return const SizedBox.shrink();

    // PROD-3766: event sub-category chips group by their parent category —
    // a "Música" header above [Blues] [Jazz] — instead of one flat list
    // under the mechanical family title. In Sport & Outdoors the section
    // title already carries the context, so no group header there.
    final blocks = <(_DimGroup, bool)>[];
    if (family.family == eventSubCategoriesFamilyKey) {
      var first = true;
      for (final dim in renderable) {
        final byPrefix = <String, List<ObservationView>>{};
        for (final obs in dim.observations) {
          final prefix = subcategoryGroupPrefix(obs.value) ?? '';
          byPrefix.putIfAbsent(prefix, () => <ObservationView>[]).add(obs);
        }
        final prefixes = byPrefix.keys.toList()..sort();
        for (final prefix in prefixes) {
          final header = parent == MemoryParent.sportOutdoors
              ? ''
              : humanizeMemoryValue(
                  context,
                  subcategoryGroupCategoryKey(prefix),
                  family: 'event_categories',
                );
          blocks.add((
            _DimGroup(
              dimension: DimensionView(
                name: dim.name,
                family: dim.family,
                state: dim.state,
                observations: byPrefix[prefix]!,
                canDelete: dim.canDelete,
                lastObservedAt: dim.lastObservedAt,
              ),
              headerOverride: header,
            ),
            first,
          ));
          first = false;
        }
      }
    } else {
      for (var idx = 0; idx < renderable.length; idx++) {
        blocks.add((
          _DimGroup(dimension: renderable[idx], headerOverride: null),
          idx == 0,
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var idx = 0; idx < blocks.length; idx++) ...[
            if (idx > 0) const SizedBox(height: 10),
            _DimensionBlock(
              dimension: blocks[idx].$1.dimension,
              headerOverride: blocks[idx].$1.headerOverride,
              chipBg: chipBg,
              expandedObservationId: expandedObservationId,
              onToggle: onToggle,
              onDeleteObservation: onDeleteObservation,
              onNudgeObservation: onNudgeObservation,
              clearLabel: l10n.memoryFamilyClearCategory.toLowerCase(),
              onClearCategory: blocks[idx].$2 ? onClearCategory : null,
            ),
          ],
        ],
      ),
    );
  }
}

class _DimGroup {
  final DimensionView dimension;
  final String? headerOverride;
  const _DimGroup({required this.dimension, required this.headerOverride});
}

class _DimensionBlock extends StatefulWidget {
  final DimensionView dimension;

  /// PROD-3766: group header shown instead of the Soko-voice dimension
  /// header ("Música" above the music sub-category chips). Empty string
  /// hides the header row entirely (Sport & Outdoors).
  final String? headerOverride;
  final Color chipBg;
  final String? expandedObservationId;
  final void Function(String observationId) onToggle;
  final void Function(DimensionView dimension, ObservationView observation)
  onDeleteObservation;
  final void Function(
    DimensionView dimension,
    ObservationView observation,
    bool increase,
  )
  onNudgeObservation;
  final String clearLabel;
  final VoidCallback? onClearCategory;

  const _DimensionBlock({
    required this.dimension,
    this.headerOverride,
    required this.chipBg,
    required this.expandedObservationId,
    required this.onToggle,
    required this.onDeleteObservation,
    required this.onNudgeObservation,
    required this.clearLabel,
    required this.onClearCategory,
  });

  @override
  State<_DimensionBlock> createState() => _DimensionBlockState();
}

/// PROD-3766: the fold. Backend tags every chip `primary` (>= 2 ticks) or
/// `secondary` (1 tick); secondary chips hide behind a "+N more" toggle so a
/// heavy user's section reads as tastes, not inventory. Returns the chips
/// to render and how many stay hidden. The expanded chip is always shown.
({List<ObservationView> visible, int hidden}) foldByTier(
  List<ObservationView> observations, {
  required bool showAll,
  String? expandedObservationId,
}) {
  final primary = observations.where((o) => !o.isSecondary).toList();
  final secondary = observations.where((o) => o.isSecondary).toList();
  if (secondary.isEmpty) return (visible: primary, hidden: 0);
  final expandedIsHidden =
      expandedObservationId != null &&
      secondary.any((o) => o.id == expandedObservationId);
  if (showAll || expandedIsHidden) {
    return (visible: [...primary, ...secondary], hidden: 0);
  }
  return (visible: primary, hidden: secondary.length);
}

class _DimensionBlockState extends State<_DimensionBlock> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final dimension = widget.dimension;
    final observations = dimension.observations;
    if (observations.isEmpty) return const SizedBox.shrink();
    final observationsByValue = dedupeObservationsByValue(observations);
    final headerText =
        widget.headerOverride ?? memoryDimensionHeader(context, dimension.name);
    final familyKey = dimension.family;
    final expanded = _findExpanded(observationsByValue);
    final fold = foldByTier(
      observationsByValue,
      showAll: _showAll,
      expandedObservationId: widget.expandedObservationId,
    );
    final l10n = Lt.of(context);
    final showFoldToggle =
        fold.hidden > 0 ||
        (_showAll && observationsByValue.any((o) => o.isSecondary));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (headerText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    // Group headers ("Música") keep their casing; Soko-voice
                    // dimension headers stay lowercase.
                    widget.headerOverride != null
                        ? headerText
                        : headerText.toLowerCase(),
                    style: TextStyle(
                      fontFamily: 'ZalandoSans',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.1,
                      color: AppColors.sokoInk.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                if (widget.onClearCategory != null)
                  GestureDetector(
                    onTap: widget.onClearCategory,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Text(
                        widget.clearLabel,
                        style: TextStyle(
                          fontFamily: 'ZalandoSans',
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: AppColors.sokoInk.withValues(alpha: 0.45),
                          decoration: TextDecoration.underline,
                          decorationColor: AppColors.sokoInk.withValues(
                            alpha: 0.25,
                          ),
                          decorationThickness: 0.5,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final obs in fold.visible)
                _ChipObservation(
                  observation: obs,
                  familyKey: familyKey,
                  background: widget.chipBg,
                  isExpanded: obs.id == widget.expandedObservationId,
                  onTap: () => widget.onToggle(obs.id),
                ),
              if (showFoldToggle)
                _FoldToggleChip(
                  label: fold.hidden > 0
                      ? l10n.memoryChipsShowMore(fold.hidden)
                      : l10n.memoryChipsShowLess,
                  onTap: () => setState(() => _showAll = !_showAll),
                ),
            ],
          ),
        ),
        if (expanded != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.sokoInk8),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.sokoInk.withValues(alpha: 0.07),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ProvenancePanel(
                observation: expanded,
                showSignal:
                    dimension.family != 'geographic' &&
                    expanded.polarity != 'avoid',
                onDelete: expanded.canDelete
                    ? () => widget.onDeleteObservation(dimension, expanded)
                    : null,
                onNudge: (increase) =>
                    widget.onNudgeObservation(dimension, expanded, increase),
              ),
            ),
          ),
      ],
    );
  }

  ObservationView? _findExpanded(List<ObservationView> observations) {
    final id = widget.expandedObservationId;
    if (id == null) return null;
    for (final o in observations) {
      if (o.id == id) return o;
    }
    return null;
  }
}

/// The "+N more" / "show less" toggle, styled as a quiet outline chip so it
/// reads as a control, not a memory.
class _FoldToggleChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _FoldToggleChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: AppColors.sokoInk.withValues(alpha: 0.25)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'ZalandoSans',
            fontWeight: FontWeight.w400,
            fontSize: 13,
            height: 1.15,
            letterSpacing: -0.1,
            color: AppColors.sokoInk.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

/// values is preserved so deterministic test output stays stable.
///
/// Public: the redesigned bar rows on the profile need the same merge.
List<ObservationView> dedupeObservationsByValue(
  List<ObservationView> observations,
) {
  final byValue = <String, ObservationView>{};
  final byValueBackingFactIds = <String, Set<String>>{};
  for (final obs in observations) {
    final key = obs.value.toLowerCase();
    final existing = byValue[key];
    if (existing == null) {
      byValue[key] = obs;
      byValueBackingFactIds[key] = {for (final f in obs.backingFacts) f.id};
      continue;
    }
    // Merge backing facts into the canonical observation. Build a new
    // ObservationView since the model is immutable.
    final seenIds = byValueBackingFactIds[key]!;
    final mergedFacts = List<MemoryFactView>.from(existing.backingFacts);
    for (final fact in obs.backingFacts) {
      if (seenIds.add(fact.id)) {
        mergedFacts.add(fact);
      }
    }
    // PROD-2799: a chat statement ('message') carries the literal quote the
    // provenance panel renders. When a save/activity observation merges in and
    // would otherwise win the primary kind, that quote (and the "N chats"
    // count) used to vanish even though the chat still contributed. Prefer the
    // 'message' kind + its evidence so the quote survives next to the other
    // source labels.
    final existingIsMessage = existing.provenanceKind == 'message';
    final obsIsMessage = obs.provenanceKind == 'message';
    final mergedKind = existingIsMessage
        ? existing.provenanceKind
        : (obsIsMessage ? obs.provenanceKind : existing.provenanceKind);
    final mergedEvidence = existingIsMessage
        ? existing.evidenceText
        : (obsIsMessage ? obs.evidenceText : existing.evidenceText);
    byValue[key] = ObservationView(
      id: existing.id,
      value: existing.value,
      // Strongest source drives the meter (the chip's level reflects the
      // best signal across sources, not just whichever came first).
      certainty: existing.certainty > obs.certainty
          ? existing.certainty
          : obs.certainty,
      polarity: existing.polarity,
      strength: existing.strength,
      sourceClass: existing.sourceClass,
      uses: existing.uses,
      canDelete: existing.canDelete || obs.canDelete,
      backingFacts: mergedFacts,
      provenanceKind: mergedKind,
      // Union all sources behind this value so the panel can show e.g.
      // "Do teu onboarding · Da tua coleção · Da tua atividade".
      provenanceKinds: {
        ...existing.allProvenanceKinds,
        ...obs.allProvenanceKinds,
      },
      observedAt: existing.observedAt,
      sourceFactId: existing.sourceFactId ?? obs.sourceFactId,
      sourceSessionId: existing.sourceSessionId,
      factSource: existing.factSource,
      evidenceText: mergedEvidence,
      group: existing.group ?? obs.group,
      tier: (existing.isSecondary && obs.isSecondary) ? 'secondary' : 'primary',
    );
  }
  return byValue.values.toList(growable: false);
}

class _ChipObservation extends StatelessWidget {
  final ObservationView observation;
  final String familyKey;
  final Color background;
  final bool isExpanded;
  final VoidCallback onTap;

  const _ChipObservation({
    required this.observation,
    required this.familyKey,
    required this.background,
    required this.isExpanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isInferred =
        observation.sourceClass == 'persona_prior' ||
        observation.factSource == 'inferred';
    final display = humanizeMemoryValue(
      context,
      observation.value,
      family: familyKey,
    );
    final ticks = certaintyTicks(observation.certainty);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: isInferred ? background.withValues(alpha: 0.22) : background,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: isExpanded
                ? AppColors.sokoInk
                : (isInferred
                      ? background.withValues(alpha: 0.6)
                      : Colors.transparent),
            width: isExpanded ? 1.4 : 0,
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              display,
              style: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontWeight: FontWeight.w400,
                fontSize: 13.5,
                height: 1.15,
                letterSpacing: -0.1,
                color: AppColors.sokoInk,
              ),
            ),
            // No tick meter for: the home location (a fact, not graded) and
            // avoided chips (the meter reads as INTEREST strength — a strong
            // bar on an "evitas" chip would wrongly look like a strong like).
            if (familyKey != 'geographic' &&
                observation.polarity != 'avoid') ...[
              const SizedBox(width: 7),
              MemoryTicks(ticks: ticks),
            ],
          ],
        ),
      ),
    );
  }
}
