import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_location_line.dart';
import '../../../shared/widgets/soko_tag.dart';
import '../../profile/utils/profile_style.dart';
import '../utils/memory_certainty.dart';
import '../utils/memory_dimension_header.dart';
import '../utils/memory_hierarchy.dart';
import '../utils/memory_value_label.dart';
import 'compact_family_section.dart' show dedupeObservationsByValue;
import 'memory_bar_row.dart';
import 'memory_glyph.dart';

/// A collapsible chapter of the Memory surface — a SeasonMix display heading
/// with a circular arrow hinge on the right, and the bar rows underneath.
///
/// Hinge direction follows the design: **down while open, up while closed**.
/// It reads as "this is where the section runs to" rather than the usual
/// chevron-points-at-the-action convention.
class MemorySection extends StatelessWidget {
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  const MemorySection({
    super.key,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.only(top: 24, bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Pt.display.copyWith(fontSize: 30, height: 1.1),
                  ),
                ),
                const SizedBox(width: 12),
                MemoryCircleButton(
                  // Down while open, up while closed — the mockup's direction.
                  glyph: expanded
                      ? MemoryGlyphKind.arrowDown
                      : MemoryGlyphKind.arrowUp,
                  onTap: onToggle,
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded ? child : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// The bar rows for one parent's families: a quiet Soko-voice sub-header per
/// dimension ("o teu tipo de comida"), then one [MemoryBarRow] per distinct
/// value.
///
/// The PROD-3766 fold is preserved — secondary-tier values (a single tick of
/// evidence) stay behind a "+N" toggle so a heavy user's section reads as
/// tastes, not inventory.
class MemoryFamilyBars extends StatelessWidget {
  final List<FamilyView> families;
  final void Function(DimensionView dimension, ObservationView observation)
  onDelete;
  final void Function(
    DimensionView dimension,
    ObservationView observation,
    bool increase,
  )
  onNudge;

  /// PROD-3766: event sub-category bars group by their parent category —
  /// a "Música" header above [Jazz] [DJ set]. The Desporto section suppresses
  /// the group header (the section title already carries the context).
  final bool suppressSubcategoryGroupHeaders;

  const MemoryFamilyBars({
    super.key,
    required this.families,
    required this.onDelete,
    required this.onNudge,
    this.suppressSubcategoryGroupHeaders = false,
  });

  @override
  Widget build(BuildContext context) {
    // Likes first, then everything the user avoids — as one block at the foot
    // of the section. The backend returns `cuisine.preferred` and
    // `cuisine.avoided` as peer dimensions in whatever order it likes, so
    // rendering them in arrival order interleaves "what you love" with "what
    // you can't stand" family by family. Splitting reads as one sentence:
    // here is what you like, and here is what to keep away from.
    final liked = <Widget>[];
    final avoided = <Widget>[];
    for (final family in families) {
      for (final dimension in family.dimensions) {
        if (dimension.observations.isEmpty) continue;
        if (family.family == eventSubCategoriesFamilyKey) {
          // One block per category, "Música" header above its values —
          // mirroring the legacy memory screen's CompactFamilySection.
          for (final group in groupSubcategoryDimension(dimension)) {
            final block = _DimensionBars(
              dimension: group.dimension,
              headerOverride: suppressSubcategoryGroupHeaders
                  ? null
                  : group.headerKey,
              onDelete: onDelete,
              onNudge: onNudge,
            );
            (isAvoidDimension(group.dimension) ? avoided : liked).add(block);
          }
          continue;
        }
        final block = _DimensionBars(
          dimension: dimension,
          onDelete: onDelete,
          onNudge: onNudge,
        );
        (isAvoidDimension(dimension) ? avoided : liked).add(block);
      }
    }
    final blocks = [...liked, ...avoided];
    if (blocks.isEmpty) return const SizedBox(width: double.infinity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: blocks,
    );
  }
}

/// One avoided value, carried with the dimension it came from so the delete
/// handler still knows where to write.
typedef AvoidedValue = ({DimensionView dimension, ObservationView observation});

/// Pulls every avoided value out of [families].
///
/// Avoids reach the app two ways — a whole `.avoided` dimension, and single
/// observations tagged `polarity: 'avoid'` sitting inside an otherwise
/// preferred dimension. The second kind is why avoids were invisible: they
/// rendered as ungraded bars in the middle of the likes, so an "evitas" value
/// looked exactly like a like with no data. Both kinds are lifted out here and
/// surfaced in their own section.
///
/// Returns the families with those observations removed (so nothing renders
/// twice) plus the avoided values, deduped by value.
({List<FamilyView> kept, List<AvoidedValue> avoided}) partitionAvoids(
  List<FamilyView> families,
) {
  final kept = <FamilyView>[];
  final avoided = <AvoidedValue>[];
  final seen = <String>{};
  for (final family in families) {
    final keptDims = <DimensionView>[];
    for (final dim in family.dimensions) {
      final dimIsAvoid = dim.name.endsWith('.avoided');
      final keptObs = <ObservationView>[];
      for (final obs in dim.observations) {
        if (dimIsAvoid || obs.polarity == 'avoid') {
          if (seen.add(obs.value.trim().toLowerCase())) {
            avoided.add((dimension: dim, observation: obs));
          }
        } else {
          keptObs.add(obs);
        }
      }
      if (keptObs.isEmpty) continue;
      keptDims.add(
        DimensionView(
          name: dim.name,
          family: dim.family,
          state: dim.state,
          observations: keptObs,
          canDelete: dim.canDelete,
          aggregated: dim.aggregated,
          lastObservedAt: dim.lastObservedAt,
        ),
      );
    }
    if (keptDims.isNotEmpty) {
      kept.add(FamilyView(family: family.family, dimensions: keptDims));
    }
  }
  return (kept: kept, avoided: avoided);
}

/// The avoided values, as chips.
///
/// A chip, not a bar: an avoided value has no magnitude — you don't dislike
/// paella 3 out of 4 — so there is no meter to draw and nothing for -/+ to
/// move. Soko/Red is the app's negative accent, which keeps the block legible
/// as the opposite pole of the sections above it.
class MemoryAvoidChips extends StatelessWidget {
  final List<AvoidedValue> values;
  final void Function(DimensionView dimension, ObservationView observation)
  onDelete;

  const MemoryAvoidChips({
    super.key,
    required this.values,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      // A column, not a Wrap: the avoided values stack one per line, the same
      // rhythm the bar rows above them keep, so the bin stays in a single
      // vertical run down the left edge of the whole page.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final v in values)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The same circular bin the bar rows use, in the same place —
                  // leading the value, not tucked inside it — so deleting a
                  // memory is one gesture wherever it appears on the page.
                  MemoryCircleButton(
                    icon: LucideIcons.trash_2,
                    size: 30,
                    iconSize: 15,
                    onTap: () => onDelete(v.dimension, v.observation),
                  ),
                  const SizedBox(width: 7),
                  SokoTag(
                    background: AppColors.sokoRed,
                    child: Text(
                      humanizeMemoryValue(
                        context,
                        v.observation.value,
                        family: v.dimension.family,
                      ),
                      style: SokoTag.textStyle,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Whether a dimension holds things the user AVOIDS rather than likes.
///
/// Two signals, because the backend uses both: the dimension name
/// (`cuisine.avoided`) and, for values that arrive on a preferred dimension,
/// the observation's own `polarity`.
bool isAvoidDimension(DimensionView dimension) =>
    dimension.name.endsWith('.avoided') ||
    dimension.observations.every((o) => o.polarity == 'avoid');

/// PROD-3766's fold, re-cut for the bar rows, with a ceiling on top.
///
/// Two rules, in order:
///
///  1. **Weak values fold.** A bar sitting at level 1 is a single tick of
///     evidence, so it hides behind the toggle. (The chip page folded on the
///     backend's `tier` flag, computed separately from the certainty the meter
///     renders — so a bar could show 1 and still be tagged `primary`. Here the
///     displayed level IS the criterion: what you see is what folds.)
///  2. **Long sections get a ceiling.** Even all-strong values are capped at
///     [maxVisible], so a heavy user reads a top slice instead of forty bars.
///     A short section never hits this, so it keeps rule 1's behaviour alone —
///     only its level-1 values fold.
///
/// [keepVisible] pins the NORMALIZED VALUES the user has just nudged, past
/// both rules, so a value they tune does not vanish under their finger.
({List<ObservationView> visible, int hidden}) foldByLevel(
  List<ObservationView> observations, {
  required bool showAll,
  Set<String> keepVisible = const <String>{},
  int maxVisible = 5,
}) {
  final strong = <ObservationView>[];
  final weak = <ObservationView>[];
  for (final o in observations) {
    if (certaintyTicks(o.certainty) <= 1 &&
        !keepVisible.contains(o.value.trim().toLowerCase())) {
      weak.add(o);
    } else {
      strong.add(o);
    }
  }
  if (showAll) return (visible: [...strong, ...weak], hidden: 0);

  final visible = <ObservationView>[];
  var overflow = 0;
  for (final o in strong) {
    // A pinned value is shown wherever it lands in the order.
    if (visible.length < maxVisible ||
        keepVisible.contains(o.value.trim().toLowerCase())) {
      visible.add(o);
    } else {
      overflow++;
    }
  }
  // 2026-09-07 (user-directed): a block whose every value is weak used to
  // render as a bare "+N mais" under the header — nothing visible at all.
  // With the act door that is the normal state of a fresh section, so when
  // the fold leaves nothing, the weak values themselves fill the window.
  if (visible.isEmpty && weak.isNotEmpty) {
    final shown = weak.take(maxVisible).toList();
    return (visible: shown, hidden: weak.length - shown.length);
  }
  return (visible: visible, hidden: overflow + weak.length);
}

class _DimensionBars extends StatefulWidget {
  final DimensionView dimension;

  /// When set, an `event_categories` display key ("music", "food & drink")
  /// rendered instead of the dimension's own header — the per-category
  /// group header of the sub-categories block.
  final String? headerOverride;
  final void Function(DimensionView dimension, ObservationView observation)
  onDelete;
  final void Function(
    DimensionView dimension,
    ObservationView observation,
    bool increase,
  )
  onNudge;

  const _DimensionBars({
    required this.dimension,
    this.headerOverride,
    required this.onDelete,
    required this.onNudge,
  });

  @override
  State<_DimensionBars> createState() => _DimensionBarsState();
}

class _DimensionBarsState extends State<_DimensionBars> {
  bool _showAll = false;

  /// VALUES the user has nudged this session (normalized). A value tuned down
  /// to level 1 would otherwise fold away mid-interaction, which reads as
  /// "the app ate my row". Keyed by value, not observation id: duplicate
  /// observations of the same value can swap identity under dedupe/rebuild,
  /// and the id-keyed guard let the nudged chip vanish (2026-09-09).
  final Set<String> _touched = <String>{};

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final dimension = widget.dimension;
    final values = dedupeObservationsByValue(dimension.observations);
    if (values.isEmpty) return const SizedBox.shrink();

    // The level meter reads as INTEREST strength, so it is suppressed where a
    // number would mislead: the home location is a fact, not a preference, and
    // a full bar on an "avoided" value would look like a strong like.
    final graded =
        dimension.family != 'geographic' && !isAvoidDimension(dimension);

    // Ungraded dimensions draw no level, so there is nothing to fold ON — a
    // level-1 fold there would hide values for a reason the user cannot see,
    // and the ceiling would hide them for no visible reason either.
    final collapsed = graded
        ? foldByLevel(values, showAll: false, keepVisible: _touched)
        : (visible: values, hidden: 0);
    final fold = _showAll && graded
        ? foldByLevel(values, showAll: true, keepVisible: _touched)
        : collapsed;
    // Derived from the COLLAPSED fold, so "show less" survives being expanded —
    // asking the expanded fold would always report nothing hidden.
    final showToggle = collapsed.hidden > 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              _capitalize(
                widget.headerOverride != null
                    ? humanizeMemoryValue(
                        context,
                        widget.headerOverride!,
                        family: 'event_categories',
                      )
                    : memoryDimensionHeader(context, dimension.name),
              ),
              style: Pt.b2.copyWith(
                color: AppColors.sokoInk.withValues(alpha: 0.7),
              ),
            ),
          ),
          for (final obs in fold.visible)
            MemoryBarRow(
              label: humanizeMemoryValue(
                context,
                obs.value,
                family: dimension.family,
              ),
              level: certaintyTicks(obs.certainty),
              // Proportional fill: the raw certainty, not the quantized band.
              fill: obs.certainty.toDouble(),
              showLevel: graded && obs.polarity != 'avoid',
              onDelete: obs.canDelete
                  ? () => widget.onDelete(dimension, obs)
                  : null,
              onDecrease: () {
                setState(() => _touched.add(obs.value.trim().toLowerCase()));
                widget.onNudge(dimension, obs, false);
              },
              onIncrease: () {
                setState(() => _touched.add(obs.value.trim().toLowerCase()));
                widget.onNudge(dimension, obs, true);
              },
            ),
          if (showToggle)
            Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                onTap: () => setState(() => _showAll = !_showAll),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(37, 0, 8, 6),
                  child: Text(
                    _showAll
                        ? l10n.memoryChipsShowLess
                        : l10n.memoryChipsShowMore(collapsed.hidden),
                    style: Pt.b2.copyWith(
                      color: AppColors.sokoInk.withValues(alpha: 0.55),
                      decoration: TextDecoration.underline,
                      decorationColor: AppColors.sokoInk.withValues(
                        alpha: 0.25,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// The Localização section's headline row — the same "Estás em … 📍 Lisboa, PT"
/// line the feed header uses, and the same behaviour: tapping the location
/// opens the search-location picker.
///
/// [SokoLocationLine] is shared with the feed, so the label, the picker and any
/// future change to either follow automatically instead of drifting apart.
class MemoryHomeRow extends StatelessWidget {
  const MemoryHomeRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            Lt.of(context).feedTopHeaderLocationPrefix,
            style: const TextStyle(fontSize: 18, color: AppColors.sokoInk),
          ),
          const Flexible(
            child: SokoLocationLine(
              iconSize: 22,
              textStyle: TextStyle(fontSize: 18, color: AppColors.sokoInk),
            ),
          ),
        ],
      ),
    );
  }
}
