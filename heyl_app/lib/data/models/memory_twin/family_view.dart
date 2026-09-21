import 'dimension_view.dart';

class FamilyView {
  final String family;
  final List<DimensionView> dimensions;

  const FamilyView({required this.family, required this.dimensions});

  /// Total observations across every dimension in this family.
  int get observationCount =>
      dimensions.fold(0, (sum, d) => sum + d.observations.length);

  // TODO: required-string cast retained pending the Phase 3 `requireString`
  // helper (see docs/platform/error-handling-discipline.md). Drop the
  // `gstack:allow` marker once it lands.
  factory FamilyView.fromJson(Map<String, dynamic> json) {
    final family =
        json['family']
            as String; // gstack:allow check-error-handling json-cast-string
    return FamilyView(
      family: family,
      dimensions: (json['dimensions'] as List? ?? const [])
          .map((d) => DimensionView.fromJson(d as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}
