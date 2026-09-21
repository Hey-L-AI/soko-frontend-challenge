/// Represents a single authentication method (phone, email, google, etc.)
class AuthMethod {
  final String id;
  final String authType;
  final String authIdentifier;
  final bool isPrimary;
  final bool isVerified;
  final bool isActive;
  final DateTime createdAt;

  const AuthMethod({
    required this.id,
    required this.authType,
    required this.authIdentifier,
    required this.isPrimary,
    required this.isVerified,
    required this.isActive,
    required this.createdAt,
  });

  factory AuthMethod.fromJson(Map<String, dynamic> json) {
    return AuthMethod(
      id: json['id'] as String,
      authType: json['auth_type'] as String,
      authIdentifier: json['auth_identifier'] as String,
      isPrimary: json['is_primary'] as bool? ?? false,
      isVerified: json['is_verified'] as bool? ?? false,
      isActive: json['is_active'] as bool? ?? true,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'auth_type': authType,
        'auth_identifier': authIdentifier,
        'is_primary': isPrimary,
        'is_verified': isVerified,
        'is_active': isActive,
        'created_at': createdAt.toIso8601String(),
      };

  /// Whether this is a phone auth method
  bool get isPhone => authType == 'phone';

  /// Whether this is an email auth method
  bool get isEmail => authType == 'email';

  /// Whether this is a social auth method (Google, Apple, Facebook)
  bool get isSocial =>
      authType == 'google' || authType == 'apple' || authType == 'facebook';
}

/// Response for listing auth methods
class AuthMethodsListResponse {
  final List<AuthMethod> authMethods;
  final bool canAddPhone;
  final bool canAddEmail;

  const AuthMethodsListResponse({
    required this.authMethods,
    required this.canAddPhone,
    required this.canAddEmail,
  });

  factory AuthMethodsListResponse.fromJson(Map<String, dynamic> json) {
    return AuthMethodsListResponse(
      authMethods: (json['auth_methods'] as List<dynamic>)
          .map((e) => AuthMethod.fromJson(e as Map<String, dynamic>))
          .toList(),
      canAddPhone: json['can_add_phone'] as bool? ?? false,
      canAddEmail: json['can_add_email'] as bool? ?? false,
    );
  }
}

/// Response for removing an auth method
class RemoveAuthMethodResponse {
  final bool removed;
  final String message;

  const RemoveAuthMethodResponse({
    required this.removed,
    required this.message,
  });

  factory RemoveAuthMethodResponse.fromJson(Map<String, dynamic> json) {
    return RemoveAuthMethodResponse(
      removed: json['removed'] as bool,
      message: json['message'] as String,
    );
  }
}

/// Response when starting phone/email verification for adding to account
class OTPStartResponse {
  final String status;
  final bool conflictDetected;

  const OTPStartResponse({
    required this.status,
    required this.conflictDetected,
  });

  factory OTPStartResponse.fromJson(Map<String, dynamic> json) {
    return OTPStartResponse(
      status: json['status'] as String? ?? 'sent',
      conflictDetected: json['conflict_detected'] as bool? ?? false,
    );
  }
}

/// Response when adding auth method successfully (no merge required)
class AddAuthMethodResponse {
  final bool added;
  final AuthMethod authMethod;
  final bool mergeRequired;

  const AddAuthMethodResponse({
    required this.added,
    required this.authMethod,
    required this.mergeRequired,
  });

  factory AddAuthMethodResponse.fromJson(Map<String, dynamic> json) {
    return AddAuthMethodResponse(
      added: json['added'] as bool,
      authMethod: AuthMethod.fromJson(json['auth_method'] as Map<String, dynamic>),
      mergeRequired: json['merge_required'] as bool? ?? false,
    );
  }
}
