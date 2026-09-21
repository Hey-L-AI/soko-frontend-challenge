import 'auth_method.dart';
import 'saved_item_preview.dart';

/// Summary of an account for merge preview
class AccountSummary {
  final String id;
  final String userId; // Now a UUID (same as id)
  final String? displayIdentifier; // Phone or email for display
  final String? fullName;
  final String? handle; // User's unique @username
  final DateTime? handleLastChangedAt; // For cooldown tracking
  final List<AuthMethod> authMethods;
  final String? memoryText;
  final List<String> memoryKeyFacts;
  final int memoryConversationCount;
  final int savedItemsCount;
  final List<SavedItemPreview> savedItemsPreview;
  final int savedItemsRemaining;
  final DateTime createdAt;

  const AccountSummary({
    required this.id,
    required this.userId,
    this.displayIdentifier,
    this.fullName,
    this.handle,
    this.handleLastChangedAt,
    required this.authMethods,
    this.memoryText,
    required this.memoryKeyFacts,
    required this.memoryConversationCount,
    required this.savedItemsCount,
    required this.savedItemsPreview,
    required this.savedItemsRemaining,
    required this.createdAt,
  });

  factory AccountSummary.fromJson(Map<String, dynamic> json) {
    return AccountSummary(
      id: json['id'] as String,
      userId: json['id'] as String,
      displayIdentifier: json['display_identifier'] as String?,
      fullName: json['full_name'] as String?,
      handle: json['handle'] as String?,
      handleLastChangedAt: json['handle_last_changed_at'] != null
          ? DateTime.parse(json['handle_last_changed_at'] as String)
          : null,
      authMethods: (json['auth_methods'] as List<dynamic>?)
              ?.map((e) => AuthMethod.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      memoryText: json['memory_text'] as String?,
      memoryKeyFacts: (json['memory_key_facts'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      memoryConversationCount: json['memory_conversation_count'] as int? ?? 0,
      savedItemsCount: json['saved_items_count'] as int? ?? 0,
      savedItemsPreview: (json['saved_items_preview'] as List<dynamic>?)
              ?.map((e) => SavedItemPreview.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      savedItemsRemaining: json['saved_items_remaining'] as int? ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  /// Get display name, falling back to displayIdentifier or userId
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

  /// Number of memory facts
  int get memoryCount => memoryKeyFacts.length;
}

/// Preview of both accounts before merge
class MergePreview {
  final AccountSummary thisAccount;
  final AccountSummary otherAccount;

  const MergePreview({
    required this.thisAccount,
    required this.otherAccount,
  });

  factory MergePreview.fromJson(Map<String, dynamic> json) {
    return MergePreview(
      thisAccount:
          AccountSummary.fromJson(json['this_account'] as Map<String, dynamic>),
      otherAccount:
          AccountSummary.fromJson(json['other_account'] as Map<String, dynamic>),
    );
  }
}

/// Response when verification detects merge is needed
class VerifyWithMergeResponse {
  final bool added;
  final bool mergeRequired;
  final MergePreview mergePreview;
  final String pendingAuthIdentifier;
  final String pendingAuthType;

  const VerifyWithMergeResponse({
    required this.added,
    required this.mergeRequired,
    required this.mergePreview,
    required this.pendingAuthIdentifier,
    required this.pendingAuthType,
  });

  factory VerifyWithMergeResponse.fromJson(Map<String, dynamic> json) {
    return VerifyWithMergeResponse(
      added: json['added'] as bool? ?? false,
      mergeRequired: json['merge_required'] as bool? ?? true,
      mergePreview:
          MergePreview.fromJson(json['merge_preview'] as Map<String, dynamic>),
      pendingAuthIdentifier: json['pending_auth_identifier'] as String,
      pendingAuthType: json['pending_auth_type'] as String,
    );
  }
}

/// Request to confirm account merge
/// Note: The current logged-in account is always kept as primary.
/// Data from both accounts is automatically merged using AI.
class MergeConfirmRequest {
  final String pendingAuthIdentifier;
  final String pendingAuthType;
  final String? selectedHandle; // Required when both accounts have handles
  final String? selectedFullName; // Required when both accounts have names

  const MergeConfirmRequest({
    required this.pendingAuthIdentifier,
    required this.pendingAuthType,
    this.selectedHandle,
    this.selectedFullName,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'pending_auth_identifier': pendingAuthIdentifier,
      'pending_auth_type': pendingAuthType,
    };
    if (selectedHandle != null) {
      json['selected_handle'] = selectedHandle;
    }
    if (selectedFullName != null) {
      json['selected_full_name'] = selectedFullName;
    }
    return json;
  }
}

/// Response after merge confirmation with data preservation stats
class MergeConfirmResponse {
  final bool merged;
  final String keptAccountId;
  final String deletedAccountId;
  final int itemsTransferred;
  final int listsMerged;
  final bool memoriesMerged;
  final String? handleKept; // The handle that was kept after merge
  final String? fullNameKept; // The display name that was kept after merge
  final String message;

  const MergeConfirmResponse({
    required this.merged,
    required this.keptAccountId,
    required this.deletedAccountId,
    this.itemsTransferred = 0,
    this.listsMerged = 0,
    this.memoriesMerged = false,
    this.handleKept,
    this.fullNameKept,
    required this.message,
  });

  factory MergeConfirmResponse.fromJson(Map<String, dynamic> json) {
    return MergeConfirmResponse(
      merged: json['merged'] as bool,
      keptAccountId: json['kept_account_id'] as String,
      deletedAccountId: json['deleted_account_id'] as String,
      itemsTransferred: json['items_transferred'] as int? ?? 0,
      listsMerged: json['lists_merged'] as int? ?? 0,
      memoriesMerged: json['memories_merged'] as bool? ?? false,
      handleKept: json['handle_kept'] as String?,
      fullNameKept: json['full_name_kept'] as String?,
      message: json['message'] as String,
    );
  }
}
