import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/datasources/interfaces/api_interfaces.dart';
import '../../providers/api_provider.dart';
import '../router/app_router.dart';
import 'storage_service.dart';

/// Service for managing search link referral flow
///
/// Handles:
/// - Storing referral slug from URL parameters
/// - Retrieving pending search from API after auth
/// - Executing the search in chat
class ReferralService {
  final StorageService _storageService;
  final IReferralsApi _referralsApi;

  ReferralService({
    required StorageService storageService,
    required IReferralsApi referralsApi,
  })  : _storageService = storageService,
        _referralsApi = referralsApi;

  /// Store referral from URL parameters
  ///
  /// Called when app opens via deep link with ref parameter.
  /// The slug is stored in persistent storage to survive OAuth redirects.
  Future<void> storeReferral(String slug, {String? searchQuery}) async {
    debugPrint('[ReferralService] Storing referral slug: $slug');
    await _storageService.savePendingReferral(slug, searchQuery: searchQuery);
  }

  /// Check if there's a pending referral
  bool hasPendingReferral() {
    return _storageService.hasPendingReferral();
  }

  /// Process pending referral after authentication
  ///
  /// Called after successful login/registration.
  /// Fetches search details from API and navigates to chat with the query.
  ///
  /// Returns true if a search was executed, false otherwise.
  Future<bool> processPendingReferral(GoRouter router) async {
    final slug = _storageService.getPendingReferralSlug();
    if (slug == null) {
      debugPrint('[ReferralService] No pending referral slug');
      return false;
    }

    debugPrint('[ReferralService] Processing pending referral: $slug');

    try {
      // Fetch pending search from API
      final pendingSearch = await _referralsApi.getPendingSearch(slug);

      // Clear the stored slug regardless of outcome
      await _storageService.clearPendingReferral();

      if (pendingSearch.hasValidSearch) {
        debugPrint('[ReferralService] Navigating to chat with search: ${pendingSearch.searchQuery}');
        _navigateToChatWithSearch(pendingSearch.searchQuery!, router);
        return true;
      } else {
        debugPrint('[ReferralService] No valid search to execute (query: ${pendingSearch.searchQuery}, autoExecute: ${pendingSearch.autoExecute})');
        return false;
      }
    } catch (e) {
      debugPrint('[ReferralService] Error fetching pending search: $e');

      // Try fallback to stored search query
      final fallbackQuery = _storageService.getPendingReferralSearch();
      await _storageService.clearPendingReferral();

      if (fallbackQuery != null && fallbackQuery.isNotEmpty) {
        debugPrint('[ReferralService] Using fallback search query: $fallbackQuery');
        _navigateToChatWithSearch(fallbackQuery, router);
        return true;
      }

      return false;
    }
  }

  /// Navigate to chat screen with autoSendMessage parameter
  ///
  /// The ChatScreen will handle:
  /// 1. Creating a new session if needed
  /// 2. Showing the user message immediately
  /// 3. Sending the message to API
  /// 4. Streaming the response
  void _navigateToChatWithSearch(String query, GoRouter router) {
    debugPrint('[ReferralService] Navigating to chat with autoSendMessage: $query');
    router.go(
      AppRoutes.chat,
      extra: {'autoSendMessage': query},
    );
  }

  /// Clear any pending referral (for cleanup)
  Future<void> clearPendingReferral() async {
    await _storageService.clearPendingReferral();
  }
}

/// Provider for ReferralService
final referralServiceProvider = Provider<ReferralService>((ref) {
  final storageService = ref.watch(storageServiceProvider);
  final referralsApi = ref.watch(referralsApiProvider);
  return ReferralService(
    storageService: storageService,
    referralsApi: referralsApi,
  );
});
