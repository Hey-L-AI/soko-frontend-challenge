import 'geo_boundary.dart';

/// A lightweight autocomplete prediction from `/geo/areas` — no coordinates
/// (resolve on select). `type`/`source` are stored but the client never
/// branches on them (source/granularity-agnostic; see Phase 2 spec).
class AreaPrediction {
  final String id;
  final String name;
  final String secondaryText;
  final String type;
  final String source;
  final String entityType;
  final ResolvedArea? resolvedArea;

  const AreaPrediction({
    required this.id,
    required this.name,
    required this.secondaryText,
    required this.type,
    required this.source,
    this.entityType = 'area',
    this.resolvedArea,
  });

  factory AreaPrediction.fromJson(Map<String, dynamic> j) => AreaPrediction(
    id: j['id'] as String,
    name: j['name'] as String,
    secondaryText: (j['secondary_text'] as String?) ?? '',
    type: (j['type'] as String?) ?? '',
    source: (j['source'] as String?) ?? '',
    entityType: (j['entity_type'] as String?) ?? 'area',
    resolvedArea: j['resolved_area'] is Map<String, dynamic>
        ? ResolvedArea.fromJson(j['resolved_area'] as Map<String, dynamic>)
        : null,
  );
}

class AreaSearchResponse {
  final List<AreaPrediction> results;
  const AreaSearchResponse({required this.results});

  factory AreaSearchResponse.fromJson(Map<String, dynamic> j) =>
      AreaSearchResponse(
        results: ((j['results'] as List<dynamic>?) ?? const [])
            .map((e) => AreaPrediction.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Submitted map search response from `/geo/search`.
///
/// Unlike autocomplete, results may already carry [ResolvedArea] coordinates.
/// A partial response is still usable when it contains local results; an empty
/// partial response is surfaced as a recoverable error by the controller.
class DeepAreaSearchResponse {
  final List<AreaPrediction> results;
  final bool partial;
  final List<String> failedProviders;
  final bool googleFallbackUsed;

  const DeepAreaSearchResponse({
    required this.results,
    this.partial = false,
    this.failedProviders = const [],
    this.googleFallbackUsed = false,
  });

  factory DeepAreaSearchResponse.fromJson(Map<String, dynamic> j) =>
      DeepAreaSearchResponse(
        results: ((j['results'] as List<dynamic>?) ?? const [])
            .map((e) => AreaPrediction.fromJson(e as Map<String, dynamic>))
            .toList(),
        partial: (j['partial'] as bool?) ?? false,
        failedProviders: ((j['failed_providers'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .toList(),
        googleFallbackUsed: (j['google_fallback_used'] as bool?) ?? false,
      );
}

/// Resolve discriminator: `boundary` = real admin polygon (containment-capable
/// id); `point` = coordinate-only result (future Google street/POI).
enum AreaKind { boundary, point }

/// Resolved area = the shared [GeoBoundary] shape plus [kind]. The inner object
/// reuses `GeoBoundary.fromJson`; unknown `kind` defaults to `boundary`.
class ResolvedArea {
  final AreaKind kind;
  final GeoBoundary boundary;
  const ResolvedArea({required this.kind, required this.boundary});

  factory ResolvedArea.fromJson(Map<String, dynamic> j) => ResolvedArea(
    kind: (j['kind'] as String?) == 'point'
        ? AreaKind.point
        : AreaKind.boundary,
    boundary: GeoBoundary.fromJson(j),
  );
}
