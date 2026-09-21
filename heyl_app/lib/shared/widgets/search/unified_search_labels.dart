// Unified search — the shared localized labels for the filter chips and the
// "View other {category}…" expander. Section-header labels stay per-host
// (onboarding drives some from onboarding copy), but the chip + expander
// vocabulary is identical everywhere, so it lives here once.

import '../../../l10n/generated/l10n.dart';
import 'unified_search_models.dart';

/// Filter-chip label for a category. Reuses the feed's filter vocabulary
/// (Eventos / Sítios / Zines / Pessoas) plus the map's Locations tag.
String unifiedChipLabel(Lt l10n, SokoSearchCategory category) => switch (category) {
  SokoSearchCategory.locations => l10n.mapDomainTagLocations,
  SokoSearchCategory.venues => l10n.feedFilterSitios,
  SokoSearchCategory.events => l10n.feedFilterEventos,
  SokoSearchCategory.zines => l10n.feedFilterZines,
  SokoSearchCategory.people => l10n.feedFilterPessoas,
};

/// "View other {category} that match your search" expander label. Reuses the
/// map's existing expander copy for locations/venues/events/zines; people is
/// unified-search's own key.
String unifiedExpanderLabel(Lt l10n, SokoSearchCategory category) =>
    switch (category) {
      SokoSearchCategory.locations => l10n.mapSuggestExpandLocations,
      SokoSearchCategory.venues => l10n.mapSuggestExpandVenues,
      SokoSearchCategory.events => l10n.mapSuggestExpandEvents,
      SokoSearchCategory.zines => l10n.mapSuggestExpandZines,
      SokoSearchCategory.people => l10n.unifiedSearchExpandPeople,
    };

/// Shared "Show less" collapse label.
String unifiedCollapseLabel(Lt l10n) => l10n.mapSuggestCollapse;

/// Default section-header pill label for a category, for hosts that don't drive
/// section labels from their own copy.
String unifiedSectionLabel(Lt l10n, SokoSearchCategory category) =>
    switch (category) {
      SokoSearchCategory.locations => l10n.mapDomainTagLocations,
      SokoSearchCategory.venues => l10n.unifiedSearchSectionPlaces,
      SokoSearchCategory.events => l10n.unifiedSearchSectionEvents,
      SokoSearchCategory.zines => l10n.unifiedSearchSectionZines,
      SokoSearchCategory.people => l10n.unifiedSearchSectionPeople,
    };
