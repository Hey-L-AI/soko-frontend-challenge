class SelectedValueView {
  final String value;
  final double certainty;
  final String polarity;
  final String strength;
  final List<String> uses;

  const SelectedValueView({
    required this.value,
    required this.certainty,
    required this.polarity,
    required this.strength,
    required this.uses,
  });

  // TODO: required-string casts retained pending the Phase 3 `requireString`
  // helper (see docs/platform/error-handling-discipline.md). Drop the
  // `gstack:allow` markers once it lands.
  factory SelectedValueView.fromJson(Map<String, dynamic> json) {
    final value =
        json['value']
            as String; // gstack:allow check-error-handling json-cast-string
    final polarity =
        json['polarity']
            as String; // gstack:allow check-error-handling json-cast-string
    final strength =
        json['strength']
            as String; // gstack:allow check-error-handling json-cast-string
    return SelectedValueView(
      value: value,
      certainty: (json['certainty'] as num).toDouble(),
      polarity: polarity,
      strength: strength,
      uses: (json['uses'] as List? ?? const [])
          .map((u) => u as String)
          .toList(growable: false),
    );
  }
}
