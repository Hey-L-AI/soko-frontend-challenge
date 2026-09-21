/// A single supported locale from the API
class LocaleInfo {
  final String code;
  final String name;

  const LocaleInfo({
    required this.code,
    required this.name,
  });

  factory LocaleInfo.fromJson(Map<String, dynamic> json) {
    return LocaleInfo(
      code: json['code'] as String,
      name: json['name'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'name': name,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LocaleInfo && other.code == code && other.name == name;
  }

  @override
  int get hashCode => code.hashCode ^ name.hashCode;

  @override
  String toString() => 'LocaleInfo(code: $code, name: $name)';
}

/// Response from listAvailableLocales endpoint
class LocaleListResponse {
  final List<LocaleInfo> locales;

  const LocaleListResponse({required this.locales});

  factory LocaleListResponse.fromJson(Map<String, dynamic> json) {
    final localesList = json['locales'] as List<dynamic>;
    return LocaleListResponse(
      locales: localesList
          .map((e) => LocaleInfo.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'locales': locales.map((e) => e.toJson()).toList(),
    };
  }
}
