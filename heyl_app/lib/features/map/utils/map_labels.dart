import '../../../l10n/generated/l10n.dart';
import '../models/map_query.dart';

/// PROD-2671 — shared localized labels for the [MapQuery] filter values.
/// Used by both the filter bar (the 4 "De quem / O quê / Quando / Tema"
/// buttons) and the results-drawer's active-filter summary row, so the
/// two never drift.

/// PROD-3565/3567 — [MapSource.list] reads **"Zine"** for *every* list kind:
/// user lists, Soko/curated lists and system lists alike (review card D5, an
/// explicit decision — do not special-case by kind). The list's own *name* is
/// shown by the "De quem?" option chip, not by this label.
String mapSourceLabel(Lt l10n, MapSource source) => switch (source) {
  MapSource.yours => l10n.mapSourceYours,
  MapSource.following => l10n.mapSourceFollowing,
  MapSource.all => l10n.mapSourceAll,
  MapSource.list => l10n.mapSourceZine,
};

String mapDateLabel(Lt l10n, MapDateFilter date) => switch (date) {
  MapDateFilter.today => l10n.mapDateToday,
  MapDateFilter.tomorrow => l10n.mapDateTomorrow,
  MapDateFilter.thisWeek => l10n.mapDateThisWeek,
  MapDateFilter.thisWeekend => l10n.mapDateThisWeekend,
  MapDateFilter.nextWeek => l10n.mapDateNextWeek,
  MapDateFilter.next30Days => l10n.mapDateNext30Days,
  MapDateFilter.custom => l10n.mapDateCustom,
};

/// Summary label for the type filter, or null for [MapItemType.all] (both
/// kinds — nothing worth surfacing as a chip). "Sítios" / "Eventos" match
/// the design's "O quê" wording.
String? mapTypeSummaryLabel(Lt l10n, MapItemType type) => switch (type) {
  MapItemType.all => null,
  MapItemType.events => l10n.mapTypeEvents,
  MapItemType.places => l10n.mapWhatPlaces,
};
