/// PROD-2735 — the two-layer discovery facet catalog (`GET /discovery/facets`).
///
/// One shared **parent** catalog spanning venues + events, each parent
/// carrying entity-specific `venue_children` / `event_children`. The on-wire
/// handle sent in `facet_filters` / received in `primary_facet` is the child
/// **slug** (not the fully-qualified `id`). Treat ids/slugs as opaque, stable
/// handles. v0 ignores `lenses` (deferred).
library;

/// A curated child chip under a parent facet. [slug] is the on-wire handle.
class DiscoveryFacetChild {
  final String id;
  final String slug;
  final String label;
  final String labelKey;

  const DiscoveryFacetChild({
    required this.id,
    required this.slug,
    required this.label,
    required this.labelKey,
  });

  static DiscoveryFacetChild? fromJson(Map<String, dynamic> json) {
    final slug = json['slug'] as String?;
    if (slug == null) return null;
    return DiscoveryFacetChild(
      id: json['id'] as String? ?? slug,
      slug: slug,
      label: json['label'] as String? ?? slug,
      labelKey: json['label_key'] as String? ?? '',
    );
  }
}

/// A shared parent facet (the primary layer). [appliesTo] is the entities it
/// spans (`venue` / `event`).
class DiscoveryParentFacet {
  final String id;
  final String label;
  final String labelKey;
  final int sortOrder;
  final bool visibleInFilters;
  final List<String> appliesTo;
  final List<DiscoveryFacetChild> venueChildren;
  final List<DiscoveryFacetChild> eventChildren;

  const DiscoveryParentFacet({
    required this.id,
    required this.label,
    required this.labelKey,
    this.sortOrder = 0,
    this.visibleInFilters = true,
    this.appliesTo = const [],
    this.venueChildren = const [],
    this.eventChildren = const [],
  });

  /// The children to show for the current O quê selection — venue children,
  /// event children, or (when both) their union deduped by slug.
  List<DiscoveryFacetChild> childrenFor({
    required bool wantVenue,
    required bool wantEvent,
  }) {
    final out = <DiscoveryFacetChild>[];
    final seen = <String>{};
    void add(Iterable<DiscoveryFacetChild> cs) {
      for (final c in cs) {
        if (seen.add(c.slug)) out.add(c);
      }
    }

    if (wantVenue) add(venueChildren);
    if (wantEvent) add(eventChildren);
    return out;
  }

  static DiscoveryParentFacet? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    if (id == null) return null;
    List<DiscoveryFacetChild> children(String key) =>
        ((json[key] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DiscoveryFacetChild.fromJson)
            .whereType<DiscoveryFacetChild>()
            .toList(growable: false);
    return DiscoveryParentFacet(
      id: id,
      label: json['label'] as String? ?? id,
      labelKey: json['label_key'] as String? ?? '',
      sortOrder: json['sort_order'] as int? ?? 0,
      visibleInFilters: json['visible_in_filters'] as bool? ?? true,
      appliesTo: ((json['applies_to'] as List<dynamic>?) ?? const [])
          .whereType<String>()
          .toList(growable: false),
      venueChildren: children('venue_children'),
      eventChildren: children('event_children'),
    );
  }
}

/// The `/discovery/facets` response. v0 consumes [parents] only.
class DiscoveryFacets {
  final List<DiscoveryParentFacet> parents;

  const DiscoveryFacets({this.parents = const []});

  factory DiscoveryFacets.fromJson(Map<String, dynamic> json) {
    final parents =
        ((json['parents'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DiscoveryParentFacet.fromJson)
            .whereType<DiscoveryParentFacet>()
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return DiscoveryFacets(parents: parents);
  }
}
