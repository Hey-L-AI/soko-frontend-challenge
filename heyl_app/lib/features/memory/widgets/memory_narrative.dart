import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../profile/utils/persona_icon.dart';
import '../../user_profiling/utils/profiling_strings.dart';
import '../utils/memory_value_label.dart';

/// Profile narrative shown above the parent tiles — Soko talking back to
/// the user in one paragraph: greeting + a few of the strongest signals
/// woven into a sentence ("Vives em Lisboa, és vegetariano, adoras
/// japonesa e italiana, e segues 2 zines.").
///
/// Template-based and locale-aware. Each fragment is rendered only when
/// its source data is present, so a sparse twin still produces a clean
/// "Olá. Vives em Lisboa." rather than awkward holes. When there is no
/// signal at all the widget renders nothing.
class MemoryNarrative extends StatelessWidget {
  final MemoryTwinResponse twin;
  final String? userName;

  /// The greeting line ("Olá, João.") — hidden on the profile memory card,
  /// which wants just the prose description.
  final bool showGreeting;

  /// The activity count pills ("1 zine criada" …) below the prose — also
  /// hidden on the profile memory card.
  final bool showActivityTags;

  const MemoryNarrative({
    super.key,
    required this.twin,
    this.userName,
    this.showGreeting = true,
    this.showActivityTags = true,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final fragments = _buildFragments(context, twin);
    final tags = showActivityTags
        ? _buildActivityTags(context, twin)
        : const <String>[];
    if (fragments.isEmpty && tags.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Persona — the onboarding illustration + name, centred at the top
          // of the memory page (no greeting), before the prose.
          if (showGreeting) _PersonaHeader(personaTags: twin.personaTags),
          // The "Memory Profile" prose — your tastes, woven into a sentence.
          if (fragments.isNotEmpty) ...[
            if (showGreeting) const SizedBox(height: 10),
            Text(
              _joinFragments(fragments, l10n.memoryNarrativeAndConnector),
              style: TextStyle(
                fontFamily: 'ZalandoSans',
                fontSize: 16,
                fontWeight: FontWeight.w400,
                height: 1.35,
                letterSpacing: -0.2,
                color: AppColors.sokoInk.withValues(alpha: 0.78),
              ),
            ),
          ],
          // Activity (saved / followed / created) as tags with a dot — kept
          // OUT of the prose so the description stays about who you are.
          if (tags.isNotEmpty) ...[
            SizedBox(height: fragments.isEmpty ? 12 : 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final t in tags) _ActivityTag(label: t)],
            ),
          ],
        ],
      ),
    );
  }
}

/// The user's persona — the onboarding illustration + its name, centred and
/// prominent — shown on the memory page above the prose. Nothing when the user
/// has no assigned persona.
class _PersonaHeader extends StatelessWidget {
  final List<String> personaTags;
  const _PersonaHeader({required this.personaTags});

  @override
  Widget build(BuildContext context) {
    final asset = personaAssetForTags(personaTags);
    final id = personaIdForTags(personaTags);
    if (asset == null || id == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(asset, width: 84, height: 84, fit: BoxFit.contain),
            const SizedBox(height: 6),
            Text(
              profilingPersonaName(context, id),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'SeasonMix',
                fontSize: 26,
                height: 1.0,
                letterSpacing: -0.4,
                fontWeight: FontWeight.w400,
                color: AppColors.sokoInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small pill — a dot + a short count label ("4 places", "2 zines followed")
/// — used for the activity counts below the profile prose.
class _ActivityTag extends StatelessWidget {
  final String label;
  const _ActivityTag({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
      decoration: BoxDecoration(
        color: AppColors.sokoPaper,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.sokoInk.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: AppColors.sokoInk.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.1,
              color: AppColors.sokoInk.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }
}

/// Collect the present-and-strong signals from the twin and convert each
/// to one human sentence fragment. Order is hand-curated so the paragraph
/// flows naturally (location → identity → tastes → activity).
List<String> _buildFragments(BuildContext context, MemoryTwinResponse twin) {
  final l10n = Lt.of(context);
  final out = <String>[];

  final home = _firstObservationValue(twin, 'location.home');
  if (home != null) {
    out.add(
      l10n.memoryNarrativeFragmentLivesIn(
        humanizeMemoryValue(context, home, family: 'geographic'),
      ),
    );
  }

  final dietary = _observationValues(twin, 'dietary.restriction', limit: 2);
  if (dietary.isNotEmpty) {
    final labels = dietary
        .map((v) => humanizeMemoryValue(context, v, family: 'dietary'))
        .map((s) => s.toLowerCase())
        .join(' ${l10n.memoryNarrativeAndConnector} ');
    out.add(l10n.memoryNarrativeFragmentDietary(labels));
  }

  final cuisines = _observationValues(
    twin,
    'cuisine.preferred',
    limit: 3,
    minCertainty: _narrativeMinCertainty,
  );
  if (cuisines.isNotEmpty) {
    final labels = _humanList(
      context,
      cuisines,
      family: 'cuisine',
      lowercase: true,
    );
    out.add(l10n.memoryNarrativeFragmentCuisines(labels));
  }

  // Venue types (kinds of place: wine bar, brunch restaurant, …) — only the
  // strongest, framed as examples ("spots like …") so the singular type names
  // read naturally. Distinct from cuisine (food) and vibes (atmosphere).
  final venueTypes = _observationValues(
    twin,
    'venue_type.preferred',
    limit: 2,
    minCertainty: _narrativeMinCertainty,
  );
  if (venueTypes.isNotEmpty) {
    final labels = _humanList(
      context,
      venueTypes,
      family: 'venue_types',
      lowercase: true,
    );
    out.add(l10n.memoryNarrativeFragmentVenueTypes(labels));
  }

  final vibes = _observationValues(
    twin,
    'vibe.preferred',
    limit: 3,
    minCertainty: _narrativeMinCertainty,
  );
  if (vibes.isNotEmpty) {
    final labels = _humanList(context, vibes, family: 'vibes', lowercase: true);
    out.add(l10n.memoryNarrativeFragmentVibes(labels));
  }

  // Event interests (sport, music, culture, nightlife, …) — the variety axis
  // beyond food/places. Strongest first, gated, so the reel can read
  // "…are into sport and live music".
  final events = _observationValues(
    twin,
    'event_category.preferred',
    limit: 3,
    minCertainty: _narrativeMinCertainty,
  );
  if (events.isNotEmpty) {
    final labels = _humanList(
      context,
      events,
      family: 'event_categories',
      lowercase: true,
    );
    out.add(l10n.memoryNarrativeFragmentEvents(labels));
  }

  // Saved / followed / created counts are NOT woven into the prose anymore —
  // they render as activity tags below it (see _buildActivityTags).
  return out;
}

/// Activity counts as short tag labels (rendered as pills with a leading dot
/// below the prose, not inside it): saved places/events, followed & created
/// zines. Returns an empty list when there's no activity.
List<String> _buildActivityTags(BuildContext context, MemoryTwinResponse twin) {
  final l10n = Lt.of(context);
  final out = <String>[];

  final venueCount = _countActionFactsByKind(twin, _SavedKind.venues);
  if (venueCount > 0) out.add(l10n.memoryNarrativeSavedVenueLabel(venueCount));

  final eventCount = _countActionFactsByKind(twin, _SavedKind.events);
  if (eventCount > 0) out.add(l10n.memoryNarrativeSavedEventLabel(eventCount));

  final createdZineCount = _countActionFactsByKind(
    twin,
    _SavedKind.zinesCreated,
  );
  if (createdZineCount > 0) {
    out.add(l10n.memoryNarrativeTagZinesCreated(createdZineCount));
  }

  final zineCount = _countActionFactsByKind(twin, _SavedKind.lists);
  if (zineCount > 0) out.add(l10n.memoryNarrativeTagZinesFollowed(zineCount));

  return out;
}

String _joinFragments(List<String> fragments, String connector) {
  if (fragments.isEmpty) return '';
  if (fragments.length == 1) return '${fragments.first}.';
  final body = fragments.sublist(0, fragments.length - 1).join(', ');
  return '$body $connector ${fragments.last}.';
}

enum _SavedKind { venues, events, lists, zinesCreated }

int _countActionFactsByKind(MemoryTwinResponse twin, _SavedKind kind) {
  final seen = <String>{};
  for (final fact in twin.actionFacts) {
    if (seen.contains(fact.id)) continue;
    _SavedKind? actual;
    if (fact.content.startsWith("Saved venue '")) {
      actual = _SavedKind.venues;
    } else if (fact.content.startsWith("Saved event '")) {
      actual = _SavedKind.events;
    } else if (fact.content.startsWith("Followed list '")) {
      actual = _SavedKind.lists;
    } else if (fact.content.startsWith("Created list '")) {
      actual = _SavedKind.zinesCreated;
    }
    if (actual == kind) {
      seen.add(fact.id);
    }
  }
  return seen.length;
}

String? _firstObservationValue(MemoryTwinResponse twin, String dimensionName) {
  for (final family in twin.families) {
    for (final dim in family.dimensions) {
      if (dim.name != dimensionName) continue;
      if (dim.observations.isEmpty) continue;
      return dim.observations.first.value;
    }
  }
  return null;
}

/// The narrative is a highlight reel, so it must feature the user's STRONGEST
/// signals — not whatever happened to be first. Values are ranked by certainty
/// (the same thing the tick meter shows) and gated at [minCertainty] so a
/// 1- or 2-tick signal never headlines a confident "you love …" claim.
/// 0.6 ≈ 3 ticks — only genuinely strong tastes make the highlight reel.
const double _narrativeMinCertainty = 0.6;

List<String> _observationValues(
  MemoryTwinResponse twin,
  String dimensionName, {
  int limit = 3,
  double minCertainty = 0.0,
}) {
  for (final family in twin.families) {
    for (final dim in family.dimensions) {
      if (dim.name != dimensionName) continue;
      // Strongest certainty per value (a value can have several observations).
      final best = <String, double>{};
      final order = <String>[];
      for (final obs in dim.observations) {
        if (!best.containsKey(obs.value)) order.add(obs.value);
        final prev = best[obs.value];
        if (prev == null || obs.certainty > prev)
          best[obs.value] = obs.certainty;
      }
      final ranked = order.where((v) => (best[v] ?? 0) >= minCertainty).toList()
        // Rank by certainty desc; stable on ties (insertion order preserved).
        ..sort((a, b) => best[b]!.compareTo(best[a]!));
      return ranked.take(limit).toList();
    }
  }
  return const [];
}

String _humanList(
  BuildContext context,
  List<String> values, {
  required String family,
  bool lowercase = false,
}) {
  final connector = Lt.of(context).memoryNarrativeAndConnector;
  final humanised = values
      .map((v) => humanizeMemoryValue(context, v, family: family))
      .map((s) => lowercase ? s.toLowerCase() : s)
      .toList();
  if (humanised.isEmpty) return '';
  if (humanised.length == 1) return humanised.first;
  if (humanised.length == 2) {
    return '${humanised[0]} $connector ${humanised[1]}';
  }
  return '${humanised.sublist(0, humanised.length - 1).join(", ")} '
      '$connector ${humanised.last}';
}
