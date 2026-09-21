/// Instagram Connect response — returned by GET /api/v1/instagram/connect
class InstagramConnectResponse {
  final String authorizationUrl;

  const InstagramConnectResponse({required this.authorizationUrl});

  factory InstagramConnectResponse.fromJson(Map<String, dynamic> json) {
    return InstagramConnectResponse(
      authorizationUrl: json['authorization_url'] as String,
    );
  }
}

/// Metadata about the connected Instagram account
class InstagramAccountMetadata {
  final String? name;
  final String? profilePictureUrl;
  final String? accountType;

  const InstagramAccountMetadata({
    this.name,
    this.profilePictureUrl,
    this.accountType,
  });

  factory InstagramAccountMetadata.fromJson(Map<String, dynamic> json) {
    return InstagramAccountMetadata(
      name: json['name'] as String?,
      profilePictureUrl: json['profile_picture_url'] as String?,
      accountType: json['account_type'] as String?,
    );
  }
}

/// A single Instagram connection
class InstagramConnection {
  final String id;
  final String instagramUserId;
  final String instagramUsername;
  final bool isActive;
  final DateTime connectedAt;
  final DateTime tokenExpiresAt;
  final InstagramAccountMetadata? accountMetadata;

  const InstagramConnection({
    required this.id,
    required this.instagramUserId,
    required this.instagramUsername,
    required this.isActive,
    required this.connectedAt,
    required this.tokenExpiresAt,
    this.accountMetadata,
  });

  factory InstagramConnection.fromJson(Map<String, dynamic> json) {
    return InstagramConnection(
      id: json['id'] as String,
      instagramUserId: json['instagram_user_id'] as String,
      instagramUsername: json['instagram_username'] as String,
      isActive: json['is_active'] as bool,
      connectedAt: DateTime.parse(json['connected_at'] as String),
      tokenExpiresAt: DateTime.parse(json['token_expires_at'] as String),
      accountMetadata: json['account_metadata'] != null
          ? InstagramAccountMetadata.fromJson(
              json['account_metadata'] as Map<String, dynamic>)
          : null,
    );
  }

  /// Whether the token expires in less than 7 days
  bool get isTokenExpiringSoon =>
      tokenExpiresAt.difference(DateTime.now()).inDays < 7;

  /// Human-readable account type display
  String get accountTypeDisplay {
    switch (accountMetadata?.accountType) {
      case 'BUSINESS':
        return 'Business';
      case 'MEDIA_CREATOR':
        return 'Creator';
      case 'PERSONAL':
        return 'Personal';
      default:
        return '';
    }
  }
}

/// An existing connection to a Soko account (from pending-connection response)
class ExistingInstagramConnection {
  final String? userFullName;
  final String? userHandle;
  final DateTime? connectedAt;

  const ExistingInstagramConnection({
    this.userFullName,
    this.userHandle,
    this.connectedAt,
  });

  factory ExistingInstagramConnection.fromJson(Map<String, dynamic> json) {
    return ExistingInstagramConnection(
      userFullName: json['user_full_name'] as String?,
      userHandle: json['user_handle'] as String?,
      connectedAt: json['connected_at'] != null
          ? DateTime.parse(json['connected_at'] as String)
          : null,
    );
  }

  /// Display name: full name, or @handle, or "Unknown"
  String get displayName =>
      userFullName ?? (userHandle != null ? '@$userHandle' : 'Unknown');
}

/// Response from GET /api/v1/instagram/pending-connection/{key}
class PendingConnectionResponse {
  final String igUsername;
  final String igUserId;
  final String? accountType;
  final List<ExistingInstagramConnection> existingConnections;

  const PendingConnectionResponse({
    required this.igUsername,
    required this.igUserId,
    this.accountType,
    required this.existingConnections,
  });

  factory PendingConnectionResponse.fromJson(Map<String, dynamic> json) {
    final list = (json['existing_connections'] as List<dynamic>?) ?? [];
    return PendingConnectionResponse(
      igUsername: json['ig_username'] as String,
      igUserId: json['ig_user_id'] as String,
      accountType: json['account_type'] as String?,
      existingConnections: list
          .map((e) =>
              ExistingInstagramConnection.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Response from POST /api/v1/instagram/pending-connection/{key}/confirm
class PendingConnectionConfirmResponse {
  final String status;
  final String? igUsername;

  const PendingConnectionConfirmResponse({
    required this.status,
    this.igUsername,
  });

  factory PendingConnectionConfirmResponse.fromJson(Map<String, dynamic> json) {
    return PendingConnectionConfirmResponse(
      status: json['status'] as String,
      igUsername: json['ig_username'] as String?,
    );
  }
}

/// Response from GET /api/v1/instagram/connections
class InstagramConnectionListResponse {
  final List<InstagramConnection> connections;

  const InstagramConnectionListResponse({required this.connections});

  factory InstagramConnectionListResponse.fromJson(Map<String, dynamic> json) {
    final list = (json['connections'] as List<dynamic>?) ?? [];
    return InstagramConnectionListResponse(
      connections: list
          .map((e) => InstagramConnection.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
