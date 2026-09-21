import 'aggregated_dimension_value_view.dart';
import 'observation_view.dart';

class DimensionView {
  final String name;
  final String family;
  final String state; // 'known' | 'uncertain' | 'conflicting' | 'inherited'
  final List<ObservationView> observations;
  final AggregatedDimensionValueView? aggregated;
  final DateTime? lastObservedAt;
  final bool canDelete;

  const DimensionView({
    required this.name,
    required this.family,
    required this.state,
    required this.observations,
    required this.canDelete,
    this.aggregated,
    this.lastObservedAt,
  });

  // TODO: required-string casts retained pending the Phase 3 `requireString`
  // helper (see docs/platform/error-handling-discipline.md). Drop the
  // `gstack:allow` markers once it lands.
  factory DimensionView.fromJson(Map<String, dynamic> json) {
    final name =
        json['name']
            as String; // gstack:allow check-error-handling json-cast-string
    final family =
        json['family']
            as String; // gstack:allow check-error-handling json-cast-string
    final state =
        json['state']
            as String; // gstack:allow check-error-handling json-cast-string
    final lastObservedAtRaw = json['last_observed_at'] as String?;
    return DimensionView(
      name: name,
      family: family,
      state: state,
      observations: (json['observations'] as List? ?? const [])
          .map((o) => ObservationView.fromJson(o as Map<String, dynamic>))
          .toList(growable: false),
      aggregated: json['aggregated'] == null
          ? null
          : AggregatedDimensionValueView.fromJson(
              json['aggregated'] as Map<String, dynamic>,
            ),
      lastObservedAt: lastObservedAtRaw == null
          ? null
          : DateTime.parse(lastObservedAtRaw),
      canDelete: json['can_delete'] as bool,
    );
  }
}
