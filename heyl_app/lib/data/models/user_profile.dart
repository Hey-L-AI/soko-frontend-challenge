/// User role enum
enum UserRole {
  user,
  curator,
  admin;

  String toJson() => name;

  static UserRole fromJson(String json) {
    return UserRole.values.firstWhere(
      (e) => e.name == json,
      orElse: () => UserRole.user,
    );
  }
}

/// WhatsApp number model for available Soko WhatsApp numbers
class WhatsAppNumber {
  final String phone;
  final String region;
  final String locale;
  final bool isCurrent;

  const WhatsAppNumber({
    required this.phone,
    required this.region,
    required this.locale,
    required this.isCurrent,
  });

  factory WhatsAppNumber.fromJson(Map<String, dynamic> json) {
    return WhatsAppNumber(
      phone: json['phone'] as String? ?? '',
      region: json['region'] as String? ?? '',
      locale: json['locale'] as String? ?? '',
      isCurrent: json['is_current'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'phone': phone,
      'region': region,
      'locale': locale,
      'is_current': isCurrent,
    };
  }
}

/// User profile model matching OpenAPI UserProfile schema
class UserProfile {
  final String id;
  final String userId; // Now a UUID (same as id)
  final String?
  displayIdentifier; // Phone or email for display (e.g., "+351912345678")
  final String? fullName;
  final String? handle;
  final DateTime? handleLastChangedAt;
  final DateTime? handleNextChangeAllowedAt;
  final String? city;
  final String? neighborhood;
  final String? country;
  final List<String> interests;
  final String? preferredLocale;
  final UserRole role;
  final bool onboardingComplete;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? whatsappPhone; // User's selected Soko WhatsApp number
  final List<WhatsAppNumber>
  availableWhatsappNumbers; // All available Soko WhatsApp numbers

  const UserProfile({
    required this.id,
    required this.userId,
    this.displayIdentifier,
    this.fullName,
    this.handle,
    this.handleLastChangedAt,
    this.handleNextChangeAllowedAt,
    this.city,
    this.neighborhood,
    this.country,
    required this.interests,
    this.preferredLocale,
    required this.role,
    required this.onboardingComplete,
    required this.createdAt,
    required this.updatedAt,
    this.whatsappPhone,
    this.availableWhatsappNumbers = const [],
  });

  /// Whether the user has set a handle
  bool get hasHandle => handle != null && handle!.isNotEmpty;

  /// Whether the user has set a display name
  bool get hasDisplayName => fullName != null && fullName!.isNotEmpty;

  /// Display name - returns fullName or displayIdentifier or userId as fallback
  String get displayName {
    if (fullName != null && fullName!.isNotEmpty) {
      return fullName!;
    }
    // Use displayIdentifier (phone/email) if available
    if (displayIdentifier != null && displayIdentifier!.isNotEmpty) {
      return displayIdentifier!;
    }
    // Fallback to userId (which is now a UUID)
    return userId;
  }

  /// Handle formatted for display with @ prefix
  String? get displayHandle => hasHandle ? '@$handle' : null;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    return UserProfile(
      id: id,
      userId: id,
      displayIdentifier: json['display_identifier'] as String?,
      fullName: json['full_name'] as String?,
      handle: json['handle'] as String?,
      handleLastChangedAt: json['handle_last_changed_at'] != null
          ? DateTime.parse(json['handle_last_changed_at'] as String)
          : null,
      handleNextChangeAllowedAt: json['handle_next_change_allowed_at'] != null
          ? DateTime.parse(json['handle_next_change_allowed_at'] as String)
          : null,
      city: json['city'] as String?,
      neighborhood: json['neighborhood'] as String?,
      country: json['country'] as String?,
      interests:
          (json['interests'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      preferredLocale: json['preferred_locale'] as String?,
      role: UserRole.fromJson(json['role'] as String? ?? 'user'),
      onboardingComplete: json['onboarding_complete'] as bool? ?? false,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : DateTime.now(),
      whatsappPhone: json['whatsapp_phone'] as String?,
      availableWhatsappNumbers:
          (json['available_whatsapp_numbers'] as List<dynamic>?)
              ?.map((e) => WhatsAppNumber.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'display_identifier': displayIdentifier,
      'full_name': fullName,
      'handle': handle,
      'handle_last_changed_at': handleLastChangedAt?.toIso8601String(),
      'handle_next_change_allowed_at': handleNextChangeAllowedAt
          ?.toIso8601String(),
      'city': city,
      'neighborhood': neighborhood,
      'country': country,
      'interests': interests,
      'preferred_locale': preferredLocale,
      'role': role.toJson(),
      'onboarding_complete': onboardingComplete,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'whatsapp_phone': whatsappPhone,
      'available_whatsapp_numbers': availableWhatsappNumbers
          .map((e) => e.toJson())
          .toList(),
    };
  }

  UserProfile copyWith({
    String? id,
    String? userId,
    String? displayIdentifier,
    String? fullName,
    String? handle,
    DateTime? handleLastChangedAt,
    DateTime? handleNextChangeAllowedAt,
    String? city,
    String? neighborhood,
    String? country,
    List<String>? interests,
    String? preferredLocale,
    UserRole? role,
    bool? onboardingComplete,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? whatsappPhone,
    List<WhatsAppNumber>? availableWhatsappNumbers,
  }) {
    return UserProfile(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      displayIdentifier: displayIdentifier ?? this.displayIdentifier,
      fullName: fullName ?? this.fullName,
      handle: handle ?? this.handle,
      handleLastChangedAt: handleLastChangedAt ?? this.handleLastChangedAt,
      handleNextChangeAllowedAt:
          handleNextChangeAllowedAt ?? this.handleNextChangeAllowedAt,
      city: city ?? this.city,
      neighborhood: neighborhood ?? this.neighborhood,
      country: country ?? this.country,
      interests: interests ?? this.interests,
      preferredLocale: preferredLocale ?? this.preferredLocale,
      role: role ?? this.role,
      onboardingComplete: onboardingComplete ?? this.onboardingComplete,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      whatsappPhone: whatsappPhone ?? this.whatsappPhone,
      availableWhatsappNumbers:
          availableWhatsappNumbers ?? this.availableWhatsappNumbers,
    );
  }
}
