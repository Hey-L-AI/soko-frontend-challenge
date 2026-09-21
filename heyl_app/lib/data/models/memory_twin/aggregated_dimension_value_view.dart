import 'selected_value_view.dart';

class AggregatedDimensionValueView {
  final String kind; // 'categorical' | 'continuous'
  final String? valueSpace;
  final List<SelectedValueView> selectedValues;
  final double? scalar;
  final double? variance;
  final double? certainty;

  const AggregatedDimensionValueView({
    required this.kind,
    this.valueSpace,
    this.selectedValues = const [],
    this.scalar,
    this.variance,
    this.certainty,
  });

  // TODO: required-string cast retained pending the Phase 3 `requireString`
  // helper (see docs/platform/error-handling-discipline.md). Drop the
  // `gstack:allow` marker once it lands.
  factory AggregatedDimensionValueView.fromJson(Map<String, dynamic> json) {
    final kind =
        json['kind']
            as String; // gstack:allow check-error-handling json-cast-string
    return AggregatedDimensionValueView(
      kind: kind,
      valueSpace: json['value_space'] as String?,
      selectedValues: (json['selected_values'] as List? ?? const [])
          .map((v) => SelectedValueView.fromJson(v as Map<String, dynamic>))
          .toList(growable: false),
      scalar: (json['scalar'] as num?)?.toDouble(),
      variance: (json['variance'] as num?)?.toDouble(),
      certainty: (json['certainty'] as num?)?.toDouble(),
    );
  }
}
