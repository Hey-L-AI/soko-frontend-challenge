import 'package:flutter/widgets.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/memory_twin/dimension_view.dart';
import '../../../data/models/memory_twin/family_view.dart';
import '../../../data/models/memory_twin/observation_view.dart';
import '../../../l10n/generated/l10n.dart';

/// Top-level parent groups in the Memory page.
///
/// Each parent collapses several twin families into one user-facing section.
/// The backend still exposes flat families (cuisine, vibes, …) — this mapping
/// is a pure UI grouping. `savedFollowed` is the only parent that does not
/// project from twin dimensions; it surfaces the user's action-sourced
/// memory facts (saved venues/events, followed lists) directly.
enum MemoryParent {
  tastes,
  vibeStyle,
  sportOutdoors,
  events,
  location,
  practical,
  social,
  savedFollowed,
}

/// Family-key → parent mapping. Source of truth: the 20 family keys returned
/// by the backend `GET /api/v1/app/users/me/memory`. Any new family the
/// backend adds defaults to [MemoryParent.practical] (the "uncategorised"
/// bucket) until explicitly mapped here.
const Map<String, MemoryParent> _familyParent = <String, MemoryParent>{
  // Tastes — food & drink + the kind of place the user goes to. venue_types
  // ("your kind of place": Portuguese restaurant, Café, Ramen restaurant…)
  // reads as a taste, not atmosphere (PROD-2799).
  'cuisine': MemoryParent.tastes,
  'dietary': MemoryParent.tastes,
  'meal_periods': MemoryParent.tastes,
  'service_formats': MemoryParent.tastes,
  'venue_types': MemoryParent.tastes,
  // Vibe & Style — atmosphere and venue character. amenities ("always nice to
  // have": outdoor seating, live music, good for groups…) describe a place's
  // character, so they belong here, not under Tastes (PROD-2799).
  'vibes': MemoryParent.vibeStyle,
  'audience': MemoryParent.vibeStyle,
  'amenities': MemoryParent.vibeStyle,
  'quality_bars': MemoryParent.vibeStyle,
  // Events — event interests; sub-categories nest under their parent
  // category at render time (see [eventSubCategoriesFamilyKey]).
  'event_categories': MemoryParent.events,
  'event_sub_categories': MemoryParent.events,
  // Location — geographic preferences.
  'geographic': MemoryParent.location,
  'areas': MemoryParent.location,
  // Practical — constraints and situational signals.
  'budget_level': MemoryParent.practical,
  'budget_ceiling': MemoryParent.practical,
  'accessibility': MemoryParent.practical,
  'occasions': MemoryParent.practical,
  // Social — people the user goes out with / mentions.
  'social_graph': MemoryParent.social,
  // Saved & Followed — entity-named facts surfaced separately. `known_venues`
  // and `known_events` carry the entity-name observations the user explicitly
  // named via chat; the SavedFollowed surface also lists the action-sourced
  // facts (`venue_saved`, `event_saved`, `list_followed`) by name.
  'known_venues': MemoryParent.savedFollowed,
  'known_events': MemoryParent.savedFollowed,
};

/// The canonical render order — parents appear top-to-bottom in this order.
/// Location sits first because "where" is the most concrete piece of context
/// a Soko user sees about themselves; Saved & Followed follows because it
/// is the surface that updates most often.
const List<MemoryParent> memoryParentRenderOrder = <MemoryParent>[
  MemoryParent.location,
  MemoryParent.savedFollowed,
  MemoryParent.tastes,
  MemoryParent.vibeStyle,
  MemoryParent.sportOutdoors,
  MemoryParent.events,
  MemoryParent.practical,
  MemoryParent.social,
];

/// Family key whose observations should render *under* their matching
/// event_categories observation (e.g. `culture-comedy` under `Culture`).
const String eventCategoriesFamilyKey = 'event_categories';
const String eventSubCategoriesFamilyKey = 'event_sub_categories';

/// Returns the parent of [familyKey], or [MemoryParent.practical] when the
/// backend introduces a new family we haven't mapped yet (graceful default).
MemoryParent parentForFamily(String familyKey) {
  return _familyParent[familyKey] ?? MemoryParent.practical;
}

// PROD-2799 #1b: venue_types is heterogeneous (food, culture, sport, outdoor,
// nightlife…), so a single family→parent mapping wrongly dumped hiking_trail /
// beach / theater under Tastes. Instead each venue_type chip is routed by its
// backend category `group` (+ value for the active-outdoor split).
const Set<String> _foodVenueGroups = <String>{
  'Restaurants & Dining',
  'Cafes & Coffee',
  'Bakeries & Sweets',
  'Quick Bites & Takeaway',
  'Production & Tastings',
  'Bars & Nightlife',
};
const Set<String> _eventVenueGroups = <String>{
  'Culture & Arts',
  'Entertainment & Leisure',
};
const Set<String> _hiddenVenueGroups = <String>{
  'Health & Wellness',
  'Shopping',
  'Lodging',
  'Services & Utilities',
  'Transport',
  'Places of Worship',
  'Education & Learning',
};
// Outdoors & Parks values that are an active pursuit (→ Sport & Outdoors) vs
// scenic places (→ Vibe & Style).
const Set<String> _activeOutdoorTypes = <String>{
  'hiking_trail',
  'hiking_area',
  'running_trail',
  'bike_trail',
  'skate_park',
  'sports_field',
  'camping_site',
};

/// Which parent a venue_type chip belongs to, from its backend category
/// [group] (+ [value] for the active-outdoor split). Returns `null` for utility
/// venues that aren't a taste/interest and should be hidden. `null` group
/// (legacy payload / unknown type) falls back to Tastes — the pre-#1b behaviour.
MemoryParent? parentForVenueGroup(String? group, String value) {
  if (group == null) return MemoryParent.tastes;
  if (_foodVenueGroups.contains(group)) return MemoryParent.tastes;
  if (_eventVenueGroups.contains(group)) return MemoryParent.events;
  if (group == 'Sports & Fitness') return MemoryParent.sportOutdoors;
  if (group == 'Outdoors & Parks') {
    return _activeOutdoorTypes.contains(value.toLowerCase())
        ? MemoryParent.sportOutdoors
        : MemoryParent.vibeStyle;
  }
  if (_hiddenVenueGroups.contains(group)) return null; // hidden
  if (group == 'Attractions') return MemoryParent.vibeStyle;
  return MemoryParent.tastes; // unknown group → keep visible under Tastes
}

/// PROD-2799 #1b: split a `venue_types` [family] so each chip lands in the
/// parent section its category group maps to (via [parentForVenueGroup]).
/// Utility venues (hidden groups) are dropped. Each dimension is rebuilt with
/// only the observations for that parent; the aggregated summary is not rebuilt
/// because the chips render from observations, not the summary.
Map<MemoryParent, FamilyView> splitVenueTypesByGroup(FamilyView family) {
  final dimsByParent = <MemoryParent, List<DimensionView>>{};
  for (final dim in family.dimensions) {
    final obsByParent = <MemoryParent, List<ObservationView>>{};
    for (final obs in dim.observations) {
      final parent = parentForVenueGroup(obs.group, obs.value);
      if (parent == null) continue; // hidden utility venue
      obsByParent.putIfAbsent(parent, () => <ObservationView>[]).add(obs);
    }
    obsByParent.forEach((parent, obs) {
      dimsByParent
          .putIfAbsent(parent, () => <DimensionView>[])
          .add(
            DimensionView(
              name: dim.name,
              family: dim.family,
              state: dim.state,
              observations: obs,
              canDelete: dim.canDelete,
              lastObservedAt: dim.lastObservedAt,
            ),
          );
    });
  }
  return dimsByParent.map(
    (parent, dims) =>
        MapEntry(parent, FamilyView(family: family.family, dimensions: dims)),
  );
}

/// PROD-3766 (open sub-categories): event sub-category chips group by their
/// parent category at render time — "Blues" and "Jazz" under a "Música"
/// header — and `sport-*` ones live in the Sport & Outdoors section, like
/// active venue types already do. The prefix before the first hyphen IS the
/// category ("music-blues" → music), so no backend change is needed.
String? subcategoryGroupPrefix(String value) {
  final i = value.indexOf('-');
  if (i <= 0) return null;
  return value.substring(0, i).toLowerCase();
}

/// Maps a slug prefix to the `event_categories` display-label key used by
/// [humanizeMemoryValue] (multi-word categories keep their full key).
String subcategoryGroupCategoryKey(String prefix) {
  const multiword = <String, String>{
    'activism': 'activism & community',
    'business': 'business & networking',
    'commerce': 'commerce & shopping',
    'education': 'education & talks',
    'family': 'family & kids',
    'food': 'food & drink',
    'gaming': 'gaming & esports',
    'nature': 'nature & outdoors',
    'nightlife': 'nightlife & parties',
    'religion': 'religion & spirituality',
    'tech': 'tech & startups',
    'volunteer': 'volunteer work',
    'wellness': 'wellness & health',
  };
  return multiword[prefix] ?? prefix;
}

/// Where a sub-category prefix lives when it is NOT an Events-section chip:
/// activity prefixes join Sport (whose empty hint promises "trilhos"), and
/// food interests sit beside the cuisine chips in Tastes. Every other prefix
/// — canonical or proposed — stays under Events, grouped by category.
const Map<String, MemoryParent> _subcategoryPrefixParent = {
  'sport': MemoryParent.sportOutdoors,
  'nature': MemoryParent.sportOutdoors,
  'wellness': MemoryParent.sportOutdoors,
  'food': MemoryParent.tastes,
};

/// Splits the `event_sub_categories` family by prefix: `sport-*`, `nature-*`
/// and `wellness-*` chips go to Sport, `food-*` to Tastes, everything else
/// stays under Events. Mirrors [splitVenueTypesByGroup].
Map<MemoryParent, FamilyView> splitEventSubCategoriesByParent(
  FamilyView family,
) {
  final dimsByParent = <MemoryParent, List<DimensionView>>{};
  for (final dim in family.dimensions) {
    final obsByParent = <MemoryParent, List<ObservationView>>{};
    for (final obs in dim.observations) {
      final parent =
          _subcategoryPrefixParent[subcategoryGroupPrefix(obs.value)] ??
          MemoryParent.events;
      obsByParent.putIfAbsent(parent, () => <ObservationView>[]).add(obs);
    }
    obsByParent.forEach((parent, obs) {
      dimsByParent
          .putIfAbsent(parent, () => <DimensionView>[])
          .add(
            DimensionView(
              name: dim.name,
              family: dim.family,
              state: dim.state,
              observations: obs,
              canDelete: dim.canDelete,
              lastObservedAt: dim.lastObservedAt,
            ),
          );
    });
  }
  return dimsByParent.map(
    (parent, dims) =>
        MapEntry(parent, FamilyView(family: family.family, dimensions: dims)),
  );
}

/// Icon shown next to the parent's title in its tile header. Picked from
/// Lucide for vector parity with the rest of the app. Saved & Followed
/// gets the bookmark icon because it is the only parent whose content is
/// the saved entities themselves rather than typed dimensions.
IconData memoryParentIcon(MemoryParent parent) {
  switch (parent) {
    case MemoryParent.location:
      return LucideIcons.map_pin;
    case MemoryParent.savedFollowed:
      return LucideIcons.bookmark_check;
    case MemoryParent.tastes:
      return LucideIcons.utensils;
    case MemoryParent.vibeStyle:
      return LucideIcons.sparkles;
    case MemoryParent.sportOutdoors:
      return LucideIcons.bike;
    case MemoryParent.events:
      return LucideIcons.calendar_days;
    case MemoryParent.practical:
      return LucideIcons.settings_2;
    case MemoryParent.social:
      return LucideIcons.users;
  }
}

/// Background colour for the parent's tile container — a saturated version
/// of the family chip background, in line with the chat-card surface
/// pattern (sokoVenue / sokoEvent / sokoLilac used at full strength). The
/// chip palette stays on top at 100% so the section has weight without
/// being shouty.
Color memoryParentTileBackground(MemoryParent parent) {
  return memoryParentChipBackground(parent).withValues(alpha: 0.55);
}

/// Background colour for chips rendered inside a parent. Each parent gets
/// one accent so the eye reads the section at a glance — green for tastes
/// (food/drink), blue for vibe/style, lilac for events, yellow for
/// location, pink for social, neutral for practical. Saved & Followed
/// doesn't use this helper (its cards pick their own colour per kind).
Color memoryParentChipBackground(MemoryParent parent) {
  switch (parent) {
    case MemoryParent.location:
      return AppColors.sokoYellow;
    case MemoryParent.tastes:
      return AppColors.sokoEvent;
    case MemoryParent.vibeStyle:
      return AppColors.sokoVenue;
    case MemoryParent.sportOutdoors:
      return AppColors.sokoGreen;
    case MemoryParent.events:
      return AppColors.sokoLilac;
    case MemoryParent.practical:
      return AppColors.sokoShade45;
    case MemoryParent.social:
      return AppColors.sokoPink;
    case MemoryParent.savedFollowed:
      // Defensive fallback — savedFollowed should never use the chip path,
      // but if a caller routes here we default to the neutral practical
      // tone rather than crash.
      return AppColors.sokoShade45;
  }
}

/// Localised label for a parent header. Falls back to a built-in English
/// label if the locale binding hasn't been regenerated yet.
String memoryParentLabel(BuildContext context, MemoryParent parent) {
  final l10n = Lt.of(context);
  switch (parent) {
    case MemoryParent.tastes:
      return l10n.memoryParentTastes;
    case MemoryParent.vibeStyle:
      return l10n.memoryParentVibeStyle;
    case MemoryParent.sportOutdoors:
      return l10n.memoryParentSport;
    case MemoryParent.events:
      return l10n.memoryParentEvents;
    case MemoryParent.location:
      return l10n.memoryParentLocation;
    case MemoryParent.practical:
      return l10n.memoryParentPractical;
    case MemoryParent.social:
      return l10n.memoryParentSocial;
    case MemoryParent.savedFollowed:
      return l10n.memoryParentSavedFollowed;
  }
}

/// Short section title used by the redesigned Memory surface on the profile.
///
/// The legacy Memory page keeps [memoryParentLabel]'s longer names ("Vibe &
/// Estilo", "Desporto & Ar Livre"); the profile headings are set in 30pt
/// SeasonMix and a two-part name wraps there, so tastes / vibe / sport get a
/// one-word title. Every other parent reuses its existing label.
String memorySectionTitle(BuildContext context, MemoryParent parent) {
  final l10n = Lt.of(context);
  switch (parent) {
    case MemoryParent.tastes:
      return l10n.memorySectionTitleTastes;
    case MemoryParent.vibeStyle:
      return l10n.memorySectionTitleStyle;
    case MemoryParent.sportOutdoors:
      return l10n.memorySectionTitleSport;
    case MemoryParent.events:
    case MemoryParent.location:
    case MemoryParent.practical:
    case MemoryParent.social:
    case MemoryParent.savedFollowed:
      return memoryParentLabel(context, parent);
  }
}

/// Inviting one-liner shown in a parent that has nothing yet, hinting how the
/// user fills it. Keeps a brand-new user's page warm instead of blank — every
/// parent shows up front, each nudging a different way to feed Soko.
String memoryParentEmptyHint(BuildContext context, MemoryParent parent) {
  final l10n = Lt.of(context);
  switch (parent) {
    case MemoryParent.tastes:
      return l10n.memoryEmptyTastes;
    case MemoryParent.vibeStyle:
      return l10n.memoryEmptyVibeStyle;
    case MemoryParent.sportOutdoors:
      return l10n.memoryEmptySport;
    case MemoryParent.events:
      return l10n.memoryEmptyEvents;
    case MemoryParent.location:
      return l10n.memoryEmptyLocation;
    case MemoryParent.practical:
      return l10n.memoryEmptyPractical;
    case MemoryParent.social:
      return l10n.memoryEmptySocial;
    case MemoryParent.savedFollowed:
      return l10n.memoryEmptySavedFollowed;
  }
}

/// PROD-3766: splits one `event_sub_categories` dimension into per-category
/// render groups — "Música" above [Jazz] [DJ set] — mirroring the legacy
/// memory screen. `headerKey` is the `event_categories` display key for
/// [humanizeMemoryValue] (null for unprefixed slugs, which render with the
/// dimension's own header).
List<({DimensionView dimension, String? headerKey})> groupSubcategoryDimension(
  DimensionView dim,
) {
  final byPrefix = <String, List<ObservationView>>{};
  for (final obs in dim.observations) {
    final prefix = subcategoryGroupPrefix(obs.value) ?? '';
    byPrefix.putIfAbsent(prefix, () => <ObservationView>[]).add(obs);
  }
  final prefixes = byPrefix.keys.toList()..sort();
  return [
    for (final prefix in prefixes)
      (
        dimension: DimensionView(
          name: dim.name,
          family: dim.family,
          state: dim.state,
          observations: byPrefix[prefix]!,
          canDelete: dim.canDelete,
          aggregated: dim.aggregated,
          lastObservedAt: dim.lastObservedAt,
        ),
        headerKey:
            prefix.isEmpty ? null : subcategoryGroupCategoryKey(prefix),
      ),
  ];
}
