import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/exceptions/api_exceptions.dart';
import '../core/services/sms_retriever_service.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import '../data/models/models.dart';
import 'api_provider.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'events_provider.dart';
import 'locale_provider.dart';
import 'memory_provider.dart';
import 'saved_provider.dart';
import 'session_provider.dart';

/// Result of verify operation
enum VerifyResult { success, mergeRequired, error }

/// Result of handle update operation
enum HandleUpdateResult { success, error }

/// Which account's value the user chose to keep during a merge conflict.
/// Selection is tracked by side (not by value string) so identical values
/// on both accounts can still be picked independently.
enum MergeSide { current, other }

/// Account management state
class AccountState {
  final List<AuthMethod> authMethods;
  final bool canAddPhone;
  final bool canAddEmail;
  final bool isLoading;
  final String? error;

  // For add auth flow
  final String? pendingIdentifier;
  final String? pendingType;
  final bool conflictDetected;

  // For merge flow
  final VerifyWithMergeResponse? mergeData;
  final MergeSide?
  selectedHandleSide; // Which side's handle to keep when both have handles
  final MergeSide?
  selectedFullNameSide; // Which side's name to keep when both have names

  const AccountState({
    this.authMethods = const [],
    this.canAddPhone = false,
    this.canAddEmail = false,
    this.isLoading = false,
    this.error,
    this.pendingIdentifier,
    this.pendingType,
    this.conflictDetected = false,
    this.mergeData,
    this.selectedHandleSide,
    this.selectedFullNameSide,
  });

  /// Initial state
  static const initial = AccountState();

  /// Get phone auth methods
  List<AuthMethod> get phoneAuthMethods =>
      authMethods.where((m) => m.isPhone).toList();

  /// Get email auth methods
  List<AuthMethod> get emailAuthMethods =>
      authMethods.where((m) => m.isEmail).toList();

  /// Get social auth methods (Google, Apple, Facebook)
  List<AuthMethod> get socialAuthMethods =>
      authMethods.where((m) => m.isSocial).toList();

  /// Whether the user can receive marketing email — true if they have a
  /// dedicated `email` auth method OR any social provider (Google / Apple /
  /// Facebook all surface an email at the identity-provider level, which
  /// the backend stores and uses as the marketing target).
  ///
  /// Used by `needsSokoIntroProvider` to skip the email-consent check for
  /// users who can't receive email, and by the menu preferences screen to
  /// hide the email-marketing toggle for those same users.
  bool get hasReachableEmail => authMethods.any((m) => m.isEmail || m.isSocial);

  /// Whether the user can receive marketing SMS — true if they have a
  /// `phone` auth method. Used by the same gate and UI as
  /// `hasReachableEmail`.
  bool get hasReachablePhone => phoneAuthMethods.isNotEmpty;

  /// Get primary auth method
  AuthMethod? get primaryMethod => authMethods.cast<AuthMethod?>().firstWhere(
    (m) => m?.isPrimary == true,
    orElse: () => null,
  );

  /// Id of the auth method we surface as "primary" in the UI. Falls back
  /// to the earliest-created method when the backend has not flagged any
  /// record `is_primary: true` — defensive against accounts where the
  /// flag was never written. See D159.
  String? get effectivePrimaryId {
    if (authMethods.isEmpty) return null;
    final flagged = primaryMethod;
    if (flagged != null) return flagged.id;
    final sorted = [...authMethods]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return sorted.first.id;
  }

  /// Check if there's a handle conflict (both accounts have handles)
  bool get hasHandleConflict {
    if (mergeData == null) return false;
    return mergeData!.mergePreview.thisAccount.handle != null &&
        mergeData!.mergePreview.otherAccount.handle != null;
  }

  /// Check if there's a full name conflict (both accounts have names)
  bool get hasFullNameConflict {
    if (mergeData == null) return false;
    return mergeData!.mergePreview.thisAccount.fullName != null &&
        mergeData!.mergePreview.otherAccount.fullName != null;
  }

  /// Resolve the selected handle side to the value the merge API expects.
  String? get selectedHandleValue {
    if (mergeData == null || selectedHandleSide == null) return null;
    return selectedHandleSide == MergeSide.current
        ? mergeData!.mergePreview.thisAccount.handle
        : mergeData!.mergePreview.otherAccount.handle;
  }

  /// Resolve the selected full name side to the value the merge API expects.
  String? get selectedFullNameValue {
    if (mergeData == null || selectedFullNameSide == null) return null;
    return selectedFullNameSide == MergeSide.current
        ? mergeData!.mergePreview.thisAccount.fullName
        : mergeData!.mergePreview.otherAccount.fullName;
  }

  /// Check if merge can be confirmed (all required selections made)
  bool get canConfirmMerge {
    if (mergeData == null) return false;
    // Check handle conflict
    if (hasHandleConflict && selectedHandleSide == null) return false;
    // Check full name conflict
    if (hasFullNameConflict && selectedFullNameSide == null) return false;
    return true;
  }

  AccountState copyWith({
    List<AuthMethod>? authMethods,
    bool? canAddPhone,
    bool? canAddEmail,
    bool? isLoading,
    String? error,
    String? pendingIdentifier,
    String? pendingType,
    bool? conflictDetected,
    VerifyWithMergeResponse? mergeData,
    MergeSide? selectedHandleSide,
    MergeSide? selectedFullNameSide,
    bool clearError = false,
    bool clearPending = false,
    bool clearMerge = false,
    bool clearSelections = false,
  }) {
    return AccountState(
      authMethods: authMethods ?? this.authMethods,
      canAddPhone: canAddPhone ?? this.canAddPhone,
      canAddEmail: canAddEmail ?? this.canAddEmail,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      pendingIdentifier: clearPending
          ? null
          : (pendingIdentifier ?? this.pendingIdentifier),
      pendingType: clearPending ? null : (pendingType ?? this.pendingType),
      conflictDetected: clearPending
          ? false
          : (conflictDetected ?? this.conflictDetected),
      mergeData: clearMerge ? null : (mergeData ?? this.mergeData),
      selectedHandleSide: (clearMerge || clearSelections)
          ? null
          : (selectedHandleSide ?? this.selectedHandleSide),
      selectedFullNameSide: (clearMerge || clearSelections)
          ? null
          : (selectedFullNameSide ?? this.selectedFullNameSide),
    );
  }
}

/// Account state notifier
class AccountNotifier extends StateNotifier<AccountState> {
  final IAuthMethodsApi _api;
  final Ref _ref;

  AccountNotifier(this._api, this._ref) : super(AccountState.initial);

  /// Load auth methods from API
  Future<void> loadAuthMethods() async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final response = await _api.listAuthMethods();
      state = state.copyWith(
        isLoading: false,
        authMethods: response.authMethods,
        canAddPhone: response.canAddPhone,
        canAddEmail: response.canAddEmail,
      );
    } on RateLimitException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Too many attempts. Please wait ${e.retryAfterSeconds} seconds.',
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load auth methods. Please try again.',
      );
    }
  }

  /// Remove a secondary auth method
  Future<bool> removeAuthMethod(String methodId) async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      await _api.removeAuthMethod(methodId);
      // Reload auth methods to get updated list
      await loadAuthMethods();
      return true;
    } on ValidationException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to remove auth method. Please try again.',
      );
      return false;
    }
  }

  /// Update profile name.
  ///
  /// Throws [ContentBlockedException] when the backend wordlist filter
  /// (PROD-2264) rejects the name so the caller can render the
  /// already-localized backend message (via [handleContentBlocked]).
  /// Other failures populate `state.error` and return `false`.
  Future<bool> updateName(String name) async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      await _api.updateProfile(ProfileUpdateRequest(fullName: name));
      // Refresh the user profile in auth provider
      await _ref.read(authStateProvider.notifier).refreshUserProfile();
      state = state.copyWith(isLoading: false);
      return true;
    } on DioException catch (e) {
      // PROD-2264 — moderation rejection. Re-throw so the screen can
      // render the backend's copy in a snackbar; clear the loading
      // spinner first.
      final blocked = ContentBlockedException.tryFrom(e);
      if (blocked != null) {
        state = state.copyWith(isLoading: false, clearError: true);
        throw blocked;
      }
      final innerError = e.error;
      if (innerError is ValidationException) {
        state = state.copyWith(isLoading: false, error: innerError.message);
        return false;
      }
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to update name. Please try again.',
      );
      return false;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to update name. Please try again.',
      );
      return false;
    }
  }

  /// Update profile handle
  /// Returns [HandleUpdateResult] indicating success or general error
  Future<HandleUpdateResult> updateHandle(String handle) async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      await _api.updateProfile(ProfileUpdateRequest(handle: handle));
      // Refresh the user profile in auth provider
      await _ref.read(authStateProvider.notifier).refreshUserProfile();
      state = state.copyWith(isLoading: false);
      return HandleUpdateResult.success;
    } on DioException catch (e) {
      // PROD-2264 — moderation rejection. Re-throw so the screen can
      // render the backend's copy in a snackbar.
      final blocked = ContentBlockedException.tryFrom(e);
      if (blocked != null) {
        state = state.copyWith(isLoading: false, clearError: true);
        throw blocked;
      }
      // Extract typed exception from DioException.error (set by ErrorInterceptor)
      final innerError = e.error;

      if (innerError is ValidationException) {
        state = state.copyWith(isLoading: false, error: innerError.message);
        return HandleUpdateResult.error;
      }

      if (innerError is RateLimitException) {
        state = state.copyWith(
          isLoading: false,
          error:
              'Too many attempts. Please wait ${innerError.retryAfterSeconds} seconds.',
        );
        return HandleUpdateResult.error;
      }

      // Fallback for other DioExceptions
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to set handle. Please try again.',
      );
      return HandleUpdateResult.error;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to set handle. Please try again.',
      );
      return HandleUpdateResult.error;
    }
  }

  /// Check if a handle is available
  Future<HandleAvailabilityResponse?> checkHandleAvailability(
    String handle,
  ) async {
    try {
      return await _api.checkHandleAvailability(handle);
    } on ValidationException catch (e) {
      // Return unavailable with validation message
      return HandleAvailabilityResponse(
        handle: handle,
        available: false,
        message: e.message,
      );
    } catch (e) {
      return null; // Network or other error
    }
  }

  /// Start adding phone (sends OTP)
  Future<bool> startAddPhone(String phone, {String channel = 'sms'}) async {
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearPending: true,
    );

    try {
      // Android SMS Retriever hash (PROD-3323) — null off Android.
      final appHash = await SmsRetrieverService().getAppSignature();
      final response = await _api.startAddPhone(
        phone,
        channel: channel,
        appHash: appHash,
      );
      state = state.copyWith(
        isLoading: false,
        pendingIdentifier: phone,
        pendingType: 'phone',
        conflictDetected: response.conflictDetected,
      );
      return true;
    } on RateLimitException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Too many attempts. Please wait ${e.retryAfterSeconds} seconds.',
      );
      return false;
    } on ValidationException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to send verification code. Please try again.',
      );
      return false;
    }
  }

  /// Verify phone OTP and add (or trigger merge)
  Future<VerifyResult> verifyAddPhone(String code) async {
    if (state.pendingIdentifier == null) {
      state = state.copyWith(error: 'No pending phone verification.');
      return VerifyResult.error;
    }

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final response = await _api.verifyAddPhone(
        state.pendingIdentifier!,
        code,
      );

      if (response is VerifyWithMergeResponse) {
        // Merge required
        state = state.copyWith(isLoading: false, mergeData: response);
        return VerifyResult.mergeRequired;
      } else if (response is AddAuthMethodResponse) {
        // Success - reload auth methods
        state = state.copyWith(isLoading: false, clearPending: true);
        await loadAuthMethods();
        return VerifyResult.success;
      }

      state = state.copyWith(isLoading: false);
      return VerifyResult.success;
    } on ValidationException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return VerifyResult.error;
    } on RateLimitException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Too many attempts. Please wait ${e.retryAfterSeconds} seconds.',
      );
      return VerifyResult.error;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Invalid verification code. Please try again.',
      );
      return VerifyResult.error;
    }
  }

  /// Start adding email (sends OTP)
  Future<bool> startAddEmail(String email) async {
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearPending: true,
    );

    try {
      final response = await _api.startAddEmail(email);
      state = state.copyWith(
        isLoading: false,
        pendingIdentifier: email,
        pendingType: 'email',
        conflictDetected: response.conflictDetected,
      );
      return true;
    } on RateLimitException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Too many attempts. Please wait ${e.retryAfterSeconds} seconds.',
      );
      return false;
    } on ValidationException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to send verification code. Please try again.',
      );
      return false;
    }
  }

  /// Verify email OTP and add (or trigger merge)
  Future<VerifyResult> verifyAddEmail(String code) async {
    if (state.pendingIdentifier == null) {
      state = state.copyWith(error: 'No pending email verification.');
      return VerifyResult.error;
    }

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final response = await _api.verifyAddEmail(
        state.pendingIdentifier!,
        code,
      );

      if (response is VerifyWithMergeResponse) {
        // Merge required
        state = state.copyWith(isLoading: false, mergeData: response);
        return VerifyResult.mergeRequired;
      } else if (response is AddAuthMethodResponse) {
        // Success - reload auth methods
        state = state.copyWith(isLoading: false, clearPending: true);
        await loadAuthMethods();
        return VerifyResult.success;
      }

      state = state.copyWith(isLoading: false);
      return VerifyResult.success;
    } on ValidationException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return VerifyResult.error;
    } on RateLimitException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Too many attempts. Please wait ${e.retryAfterSeconds} seconds.',
      );
      return VerifyResult.error;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Invalid verification code. Please try again.',
      );
      return VerifyResult.error;
    }
  }

  /// Set which side's handle to keep for merge conflict resolution
  void setSelectedHandleSide(MergeSide side) {
    state = state.copyWith(selectedHandleSide: side);
  }

  /// Set which side's full name to keep for merge conflict resolution
  void setSelectedFullNameSide(MergeSide side) {
    state = state.copyWith(selectedFullNameSide: side);
  }

  /// Confirm merge - current account is always kept, other account's data is merged
  Future<bool> confirmMerge() async {
    final mergeData = state.mergeData;
    if (mergeData == null) {
      state = state.copyWith(error: 'No pending merge.');
      return false;
    }

    // Validate required selections
    if (!state.canConfirmMerge) {
      state = state.copyWith(error: 'Please make all required selections.');
      return false;
    }

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      await _api.confirmMerge(
        MergeConfirmRequest(
          pendingAuthIdentifier: mergeData.pendingAuthIdentifier,
          pendingAuthType: mergeData.pendingAuthType,
          selectedHandle: state.selectedHandleValue,
          selectedFullName: state.selectedFullNameValue,
        ),
      );

      // Clear merge and pending state
      state = state.copyWith(clearPending: true, clearMerge: true);

      // Phase 1: Refresh user profile
      await _ref.read(authStateProvider.notifier).refreshUserProfile();

      // Phase 2: Reload auth methods
      await loadAuthMethods();

      // Phase 3: Invalidate FutureProviders (will re-fetch on next access)
      _ref.invalidate(eventsProvider);
      _ref.invalidate(venuesProvider);
      _ref.invalidate(messageStartersProvider);

      // Phase 4: Refresh StateNotifierProviders in parallel
      _ref.invalidate(memoryProvider);
      final locale = _ref.read(apiLocaleCodeProvider);
      await Future.wait([
        _ref.read(sessionsProvider.notifier).refresh(),
        _ref.read(savedProvider.notifier).refresh(),
        _ref.read(memoryProvider.notifier).refresh(locale: locale),
      ]);

      state = state.copyWith(isLoading: false);
      return true;
    } on ValidationException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to merge accounts. Please try again.',
      );
      return false;
    }
  }

  /// Cancel current add/merge flow
  void cancelFlow() {
    state = state.copyWith(
      clearError: true,
      clearPending: true,
      clearMerge: true,
    );
  }

  /// Clear error
  void clearError() {
    state = state.copyWith(clearError: true);
  }

  /// Update WhatsApp preference (select preferred WhatsApp number)
  Future<bool> updateWhatsappPreference(String whatsappPhone) async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      await _api.updateWhatsappPreference(whatsappPhone);
      // Refresh the user profile in auth provider
      await _ref.read(authStateProvider.notifier).refreshUserProfile();
      state = state.copyWith(isLoading: false);
      return true;
    } on DioException catch (e) {
      // Extract typed exception from DioException.error (set by ErrorInterceptor)
      final innerError = e.error;

      // Log the actual error for debugging
      print('[AccountNotifier] WhatsApp preference update failed: $innerError');
      print(
        '[AccountNotifier] Request phone: $whatsappPhone, Status: ${e.response?.statusCode}, Body: ${e.response?.data}',
      );

      if (innerError is RateLimitException) {
        state = state.copyWith(
          isLoading: false,
          error:
              'Too many attempts. Please wait ${innerError.retryAfterSeconds} seconds.',
        );
        return false;
      }

      // Show generic user-friendly message
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to update WhatsApp preference. Please try again.',
      );
      return false;
    } catch (e) {
      print(
        '[AccountNotifier] WhatsApp preference update failed (unexpected): $e',
      );
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to update WhatsApp preference. Please try again.',
      );
      return false;
    }
  }
}

/// Provider for account state.
///
/// Auto-invalidates whenever the authenticated user's id changes (login as
/// a different user, logout, account merge). Without this, a freshly-logged-
/// in user would briefly see the previous user's cached `authMethods`, which
/// would feed the wrong decision into `needsSokoIntroProvider` (channel
/// gate) and the menu preferences screen (toggle visibility).
///
/// Add/remove of an auth method on the SAME user already triggers
/// `loadAuthMethods()` inline (see `removeAuthMethod`,
/// `verifyAddPhone`/`verifyAddEmail` and `confirmMerge`) — those don't
/// need invalidation since they keep the same `user.id`.
final accountProvider = StateNotifierProvider<AccountNotifier, AccountState>((
  ref,
) {
  ref.listen<String?>(authStateProvider.select((s) => s.user?.id), (
    prev,
    next,
  ) {
    if (prev != next) ref.invalidateSelf();
  });
  final api = ref.watch(authMethodsApiProvider);
  return AccountNotifier(api, ref);
});

/// Convenience provider for auth methods list
final authMethodsListProvider = Provider<List<AuthMethod>>((ref) {
  return ref.watch(accountProvider).authMethods;
});

/// Convenience provider for can add phone
final canAddPhoneProvider = Provider<bool>((ref) {
  return ref.watch(accountProvider).canAddPhone;
});

/// Convenience provider for can add email
final canAddEmailProvider = Provider<bool>((ref) {
  return ref.watch(accountProvider).canAddEmail;
});

/// Convenience provider for merge data
final mergeDataProvider = Provider<VerifyWithMergeResponse?>((ref) {
  return ref.watch(accountProvider).mergeData;
});
