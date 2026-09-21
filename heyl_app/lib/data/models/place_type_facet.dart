/// A product-facing place type facet returned by
/// `GET /api/v1/app/places/type-facets`.
///
/// Facets are collapsed, user-facing chips for Discovery Places filters. The
/// backend owns the taxonomy: each facet [id] maps server-side to one or more
/// canonical root venue types ([canonicalTypes]), and venue search expands
/// those roots to descendants. The frontend renders chips and sends selected
/// [id]s back in the `POST /api/v1/app/places/search` `facets` field.
class PlaceTypeFacet {
  /// Stable English slug, e.g. `eat_drink`. The value sent in `search`.
  final String id;

  /// Stable, locale-independent i18n key (e.g. `facet.eat_drink`). The
  /// frontend maps it to ARB and falls back to [label] for unknown facets.
  final String labelKey;

  /// English fallback label only. The UI localizes via [labelKey]/ARB.
  final String label;

  /// Canonical root venue types this facet expands to server-side.
  final List<String> canonicalTypes;

  /// Display order for visible chips. Hidden facets may report null; the
  /// provider normalizes null to the end of the list.
  final int? sortOrder;

  /// When false, the facet exists in taxonomy but should not render as a chip.
  final bool visibleInFilters;

  const PlaceTypeFacet({
    required this.id,
    required this.labelKey,
    required this.label,
    required this.canonicalTypes,
    required this.sortOrder,
    required this.visibleInFilters,
  });

  factory PlaceTypeFacet.fromJson(Map<String, dynamic> json) {
    return PlaceTypeFacet(
      id: json['id'] as String? ?? '',
      labelKey: json['label_key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      canonicalTypes:
          (json['canonical_types'] as List<dynamic>?)?.cast<String>() ??
          const [],
      sortOrder: (json['sort_order'] as num?)?.toInt(),
      visibleInFilters: json['visible_in_filters'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PlaceTypeFacet && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'PlaceTypeFacet($id, $label, $canonicalTypes)';
}
