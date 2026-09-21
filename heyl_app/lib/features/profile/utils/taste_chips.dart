import 'package:flutter/material.dart';

import '../../../data/models/models.dart';
import '../../memory/utils/memory_value_label.dart';

/// A single colored taste pill in the profile's "O que gosta" section.
class TasteChip {
  final String label;
  final Color color;
  const TasteChip(this.label, this.color);
}

// Exact Figma "Tag" fills (node 7058:19395) — brighter than the base AppColors
// tokens, so kept local to the chips.
const Color _tagGreen = Color(0xFFB0EF8B);
const Color _tagRed = Color(0xFFF68686);
const Color _tagBlue = Color(0xFF8BDFFF);
const Color _tagLilac = Color(0xFFE08EFB);
const Color _tagYellow = Color(0xFFEDE77D);

/// The taste dimensions surfaced as chips, in display priority order. Each maps
/// to a stable color (matching the Figma taste-tag palette: dietary→green,
/// cuisine→red, venue→blue, vibe→lilac, event→yellow) and to the humanization
/// family used to localize the raw value.
const List<({String dim, String family, Color color})> _chipDims = [
  (dim: 'dietary.restriction', family: 'dietary', color: _tagGreen),
  (dim: 'cuisine.preferred', family: 'cuisine', color: _tagRed),
  (dim: 'venue_type.preferred', family: 'venue_types', color: _tagBlue),
  (dim: 'vibe.preferred', family: 'vibes', color: _tagLilac),
  (
    dim: 'event_category.preferred',
    family: 'event_categories',
    color: _tagYellow,
  ),
];

/// Sample chips for LOCAL UI TESTING ONLY — used by `_TastesSection` when the
/// real taste twin is empty AND the build is debug (`kDebugMode`). Never reaches
/// release/staging/prod. Remove the debug call once the test account has real
/// memory-derived tastes.
List<TasteChip> debugSampleTasteChips() => const [
  TasteChip('Italian food', _tagRed),
  TasteChip('Japanese food', _tagRed),
  TasteChip('Wine bars', _tagBlue),
  TasteChip('Live music', _tagLilac),
  TasteChip('Theatre', _tagBlue),
  TasteChip('Adventurous', _tagYellow),
  TasteChip('Authentic', _tagGreen),
];

/// Build the colored taste chips from a taste twin — the strongest values per
/// taste dimension, humanized + localized, capped at [max]. Empty when the twin
/// carries no taste signal (only location, or gated to empty).
List<TasteChip> buildTasteChips(
  BuildContext context,
  MemoryTwinResponse twin, {
  int max = 6,
}) {
  final chips = <TasteChip>[];
  for (final spec in _chipDims) {
    for (final value in _topValues(twin, spec.dim, limit: 2)) {
      chips.add(
        TasteChip(
          humanizeMemoryValue(context, value, family: spec.family),
          spec.color,
        ),
      );
      if (chips.length >= max) return chips;
    }
  }
  return chips;
}

/// Strongest observation values for one dimension, ranked by certainty desc,
/// de-duplicated, preserving the strongest occurrence.
List<String> _topValues(
  MemoryTwinResponse twin,
  String dimensionName, {
  int limit = 2,
}) {
  for (final family in twin.families) {
    for (final dim in family.dimensions) {
      if (dim.name != dimensionName) continue;
      final best = <String, double>{};
      for (final o in dim.observations) {
        final prev = best[o.value];
        if (prev == null || o.certainty > prev) best[o.value] = o.certainty;
      }
      final ranked = best.keys.toList()
        ..sort((a, b) => best[b]!.compareTo(best[a]!));
      return ranked.take(limit).toList();
    }
  }
  return const [];
}
