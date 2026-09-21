import 'package:flutter/material.dart';

import '../../../data/models/library_feed.dart';
import '../../../data/models/user_list.dart';

enum LibraryCategory { eventos, sitios, zines, pessoas }

/// `?tag=` value that means "no filter" — the landing with every shelf.
/// Spelled out so it can force the unfiltered hub, which an absent `tag`
/// deliberately does not (that one leaves the parked tab alone).
const String kLibraryAllTag = 'all';

LibraryCategory? libraryCategoryFromName(String? name) {
  if (name == null || name.isEmpty) return null;
  for (final c in LibraryCategory.values) {
    if (c.name == name) return c;
  }
  return null;
}

enum LibrarySubFilter {
  futuros(LibraryCategory.eventos),
  passados(LibraryCategory.eventos),
  data(LibraryCategory.eventos),
  tuas(LibraryCategory.zines),
  seguidas(LibraryCategory.zines),
  feitasParaTi(LibraryCategory.zines);

  const LibrarySubFilter(this.category);

  final LibraryCategory category;

  static List<LibrarySubFilter> forCategory(LibraryCategory c) =>
      LibrarySubFilter.values.where((s) => s.category == c).toList();

  /// Zines join [tuas] immediately so owned and followed never mix.
  static LibrarySubFilter? defaultFor(LibraryCategory c) => switch (c) {
    LibraryCategory.zines => LibrarySubFilter.tuas,
    _ => null,
  };
}

/// Wire `types` for the library GET.
LibraryFeedItemType libraryFeedTypeFor(LibraryCategory c) => switch (c) {
  LibraryCategory.eventos => LibraryFeedItemType.event,
  LibraryCategory.sitios => LibraryFeedItemType.place,
  LibraryCategory.pessoas => LibraryFeedItemType.person,
  LibraryCategory.zines => LibraryFeedItemType.zine,
};

/// `membership` for `GET /users/me/library` (PROD-4171). Null unless Zines.
String? libraryMembershipQuery(LibraryFilter filter) {
  if (filter.category != LibraryCategory.zines) return null;
  return switch (filter.subFilter) {
    LibrarySubFilter.seguidas => 'following',
    LibrarySubFilter.feitasParaTi => 'system',
    _ => 'owned',
  };
}

/// `when` for Eventos Futuros / Passados (PROD-4166). Null for Data / none.
String? libraryWhenQuery(LibraryFilter filter) {
  if (filter.category != LibraryCategory.eventos) return null;
  return switch (filter.subFilter) {
    LibrarySubFilter.futuros => 'upcoming',
    LibrarySubFilter.passados => 'past',
    _ => null,
  };
}

/// Inclusive local-day window for the Data chip. Both ends the same day.
({String? fromDate, String? toDate}) libraryEventDateQuery(
  LibraryFilter filter,
) {
  if (filter.category != LibraryCategory.eventos ||
      filter.subFilter != LibrarySubFilter.data ||
      filter.selectedDate == null) {
    return (fromDate: null, toDate: null);
  }
  final d = filter.selectedDate!;
  final iso =
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  return (fromDate: iso, toDate: iso);
}

/// Owner setting from `LibraryFeedZine.visibility`. Retired `followers`
/// reads as private, matching [VisibilityMenuChip]. Unknown/missing → hide.
ListVisibility? libraryZineVisibility(String? raw) {
  return switch (raw) {
    'public' => ListVisibility.public,
    'private' || 'followers' => ListVisibility.private,
    _ => null,
  };
}

bool isSameCalendarDay(DateTime? instant, DateTime day) {
  if (instant == null) return false;
  final local = instant.toLocal();
  return local.year == day.year &&
      local.month == day.month &&
      local.day == day.day;
}

DateTime calendarDay(DateTime d) {
  final local = d.toLocal();
  return DateTime(local.year, local.month, local.day);
}

enum LibrarySort {
  recent,
  alphabetical,
  chronological;

  String get wire => name;
}

enum LibraryViewMode { list, grid }

@immutable
class LibraryFilter {
  final LibraryCategory? category;
  final LibrarySubFilter? subFilter;

  final DateTime? selectedDate;

  const LibraryFilter({this.category, this.subFilter, this.selectedDate});

  static const LibraryFilter initial = LibraryFilter();

  bool get isInitial =>
      category == null && subFilter == null && selectedDate == null;

  LibraryFilter withCategory(LibraryCategory c) =>
      LibraryFilter(category: c, subFilter: LibrarySubFilter.defaultFor(c));

  LibraryFilter toggleCategory(LibraryCategory c) =>
      category == c ? LibraryFilter.initial : withCategory(c);

  LibraryFilter withSubFilter(LibrarySubFilter? s) => LibraryFilter(
    category: category,
    subFilter: s,
    selectedDate: s == LibrarySubFilter.data ? selectedDate : null,
  );

  /// Peel the sub-filter, then the category. Does not skip straight to landing.
  LibraryFilter withoutAppliedFilter() {
    if (category == null) return this;
    final def = LibrarySubFilter.defaultFor(category!);
    if (subFilter != null && subFilter != def) {
      return withSubFilter(def);
    }
    return LibraryFilter.initial;
  }

  LibraryFilter withDate(DateTime day) => LibraryFilter(
    category: LibraryCategory.eventos,
    subFilter: LibrarySubFilter.data,
    selectedDate: calendarDay(day),
  );

  @override
  bool operator ==(Object other) =>
      other is LibraryFilter &&
      other.category == category &&
      other.subFilter == subFilter &&
      other.selectedDate == selectedDate;

  @override
  int get hashCode => Object.hash(category, subFilter, selectedDate);
}

/// Resolve `/library?tag=` into the filter the hub should land on.
///
/// * absent/unknown → null: no opinion, the tab parked by the last visit
///   stands (that's what keeps a Home round-trip on the same shelf).
/// * [kLibraryAllTag] → the unfiltered landing.
/// * a [LibraryCategory] name → that shelf, with its default sub-filter.
LibraryFilter? libraryLandingFilterFor(String? tag) {
  if (tag == null || tag.isEmpty) return null;
  if (tag == kLibraryAllTag) return LibraryFilter.initial;
  final category = libraryCategoryFromName(tag);
  return category == null ? null : LibraryFilter.initial.withCategory(category);
}
