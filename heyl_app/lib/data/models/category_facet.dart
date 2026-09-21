/// A product-facing event category facet returned by
/// `GET /api/v1/app/events/category-facets`.
///
/// Facets are the collapsed, user-facing chips for the Discovery Events
/// filters. The backend owns the taxonomy: each facet [id] maps server-side
/// to one or more canonical `events.categories[]` values ([canonicalValues]).
/// The frontend renders chips and sends the selected [id]s back in the
/// `POST /api/v1/app/events/search` `facets` field — it never expands ids to
/// canonical categories itself. That keeps the id↔category mapping on the
/// server so it can't drift from a stale client (PROD-2369).
class CategoryFacet {
  /// Stable English slug, e.g. `arts_culture`. The value sent in `search`.
  final String id;

  /// Stable, locale-independent i18n key (e.g. `facet.arts_culture`). This is
  /// the designated localization key: the frontend maps it to an ARB string
  /// (see `EventFiltersBar`). Also used for contract tests.
  final String labelKey;

  /// English fallback label only — the backend does NOT localize this. The UI
  /// localizes via [labelKey]/ARB and falls back to this string for any facet
  /// the frontend doesn't yet have an ARB entry for.
  final String label;

  /// The canonical `events.categories[]` values this facet expands to,
  /// server-side. Returned for transparency/debugging only — the frontend
  /// does NOT send these in the search request.
  final List<String> canonicalValues;

  /// Display order for visible chips (ascending).
  final int sortOrder;

  /// When false the facet exists in the taxonomy but should not be rendered
  /// as a chip (e.g. `religion_spirituality`). Those events still surface
  /// under the unfiltered "All" / text / date views.
  final bool visibleInFilters;

  const CategoryFacet({
    required this.id,
    required this.labelKey,
    required this.label,
    required this.canonicalValues,
    required this.sortOrder,
    required this.visibleInFilters,
  });

  factory CategoryFacet.fromJson(Map<String, dynamic> json) {
    return CategoryFacet(
      id: json['id'] as String? ?? '',
      labelKey: json['label_key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      canonicalValues:
          (json['canonical_values'] as List<dynamic>?)?.cast<String>() ??
          const [],
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      visibleInFilters: json['visible_in_filters'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CategoryFacet && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'CategoryFacet($id, $label, $canonicalValues)';
}
