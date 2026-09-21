/// Model representing a country with its dial code information
class Country {
  final String name;
  final String isoCode;
  final String dialCode;
  final String flag;

  const Country({
    required this.name,
    required this.isoCode,
    required this.dialCode,
    required this.flag,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Country &&
          runtimeType == other.runtimeType &&
          isoCode == other.isoCode;

  @override
  int get hashCode => isoCode.hashCode;
}
