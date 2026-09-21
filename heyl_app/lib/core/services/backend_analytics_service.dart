import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../data/datasources/api/analytics_events_api.dart';
import '../../providers/api_provider.dart';
import '../../providers/session_provider.dart';
import 'attribution_service.dart';

/// Destination types for external click tracking
class ExternalDestination {
  static const String googleMaps = 'google_maps';
  static const String website = 'website';
  static const String ticketing = 'ticketing';
  static const String social = 'social';
  static const String calendar = 'calendar';
  static const String phone = 'phone';
  static const String share = 'share';
  static const String other = 'other';
}

/// Origin sources for tracking where a click originated
class OriginSource {
  static const String listShare = 'list_share';
  static const String smartListSuggestion = 'smart_list_suggestion';
  static const String search = 'search';
  static const String recommendation = 'recommendation';
  static const String detailView = 'detail_view';
  static const String chat = 'chat';
}

/// Provider for backend analytics service
final backendAnalyticsServiceProvider = Provider<BackendAnalyticsService>((
  ref,
) {
  final api = ref.watch(analyticsEventsApiProvider);
  return BackendAnalyticsService(ref, api);
});

/// Service for tracking analytics events to the backend.
/// Wraps AnalyticsEventsApi with convenient methods and automatic session ID injection.
///
/// All methods are fire-and-forget - they never throw exceptions and
/// should never block the UI.
class BackendAnalyticsService {
  final Ref _ref;
  final AnalyticsEventsApi _api;
  String? _cachedAppVersion;

  BackendAnalyticsService(this._ref, this._api);

  /// Get current session ID from provider
  String? get _sessionId => _ref.read(activeSessionIdProvider);

  /// Get visitor ID for pre-auth event stitching (async to avoid race condition)
  Future<String?> _getVisitorId() async {
    try {
      return await _ref.read(attributionServiceProvider).getVisitorId();
    } catch (_) {
      return null;
    }
  }

  /// Get app version (cached after first call)
  Future<String?> _getAppVersion() async {
    if (_cachedAppVersion != null) return _cachedAppVersion;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _cachedAppVersion = packageInfo.version;
      return _cachedAppVersion;
    } catch (e) {
      debugPrint('BackendAnalytics: Could not get app version - $e');
      return null;
    }
  }

  /// Generic event tracking — dispatches any event to the unified backend endpoint.
  /// Automatically injects sessionId and visitorId.
  Future<void> trackGeneric(
    String eventName,
    Map<String, dynamic> properties,
  ) async {
    await _api.trackGeneric(
      eventName: eventName,
      properties: properties.isNotEmpty ? properties : null,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track app open event
  /// Called on app startup/foreground after authentication is confirmed.
  ///
  /// [authMethod] - Optional: 'google', 'apple', 'phone', 'email'
  Future<void> trackAppOpen({String? authMethod}) async {
    final appVersion = await _getAppVersion();
    await _api.trackAppOpen(
      appVersion: appVersion,
      sessionId: _sessionId,
      authMethod: authMethod,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track search result click
  /// Called when user taps/clicks a search result item to view details.
  ///
  /// [eventId] - UUID if clicked item is an event
  /// [venueId] - UUID if clicked item is a place
  /// [intent] - "search_events" or "search_places"
  /// [resultPosition] - 0-indexed position in results
  Future<void> trackSearchResultClick({
    String? eventId,
    String? venueId,
    String? intent,
    int? resultPosition,
  }) async {
    await _api.trackSearchResultClick(
      sessionId: _sessionId,
      eventId: eventId,
      venueId: venueId,
      intent: intent,
      resultPosition: resultPosition,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track external click - Google Maps
  /// [venueId] or [eventId] - ID of the related item
  /// [originSource] - Use OriginSource constants
  /// [originEntityId] - e.g., list_id if from a shared list
  Future<void> trackGoogleMapsClick({
    required String url,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    await _trackExternalClick(
      destinationType: ExternalDestination.googleMaps,
      destinationUrl: url,
      eventId: eventId,
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  /// Track external click - Website
  Future<void> trackWebsiteClick({
    required String url,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    await _trackExternalClick(
      destinationType: ExternalDestination.website,
      destinationUrl: url,
      eventId: eventId,
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  /// Track external click - Ticketing/Booking
  Future<void> trackTicketingClick({
    required String url,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    await _trackExternalClick(
      destinationType: ExternalDestination.ticketing,
      destinationUrl: url,
      eventId: eventId,
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  /// Track external click - Calendar (Google Calendar, etc.)
  Future<void> trackCalendarClick({
    required String url,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    await _trackExternalClick(
      destinationType: ExternalDestination.calendar,
      destinationUrl: url,
      eventId: eventId,
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  Future<void> trackPhoneClick({
    required String phoneNumber,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    await _trackExternalClick(
      destinationType: ExternalDestination.phone,
      destinationUrl: 'tel:$phoneNumber',
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  /// Track external click - Generic
  Future<void> trackExternalClick({
    required String destinationType,
    required String url,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    await _trackExternalClick(
      destinationType: destinationType,
      destinationUrl: url,
      eventId: eventId,
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  /// Internal method for external click tracking
  Future<void> _trackExternalClick({
    required String destinationType,
    required String destinationUrl,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    await _api.trackExternalClick(
      sessionId: _sessionId,
      destinationType: destinationType,
      destinationUrl: destinationUrl,
      eventId: eventId,
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track list link clicked item
  /// Called when viewing a public list (via share link) and user taps an item.
  /// Works for both authenticated and anonymous users.
  Future<void> trackListItemClick({
    required String listId,
    required String itemType,
    String? eventId,
    String? venueId,
  }) async {
    await _api.trackListLinkClickedItem(
      listId: listId,
      itemType: itemType,
      eventId: eventId,
      venueId: venueId,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ NEW ANALYTICS METHODS ============

  /// Track sign out event
  /// Called when user taps logout button.
  Future<void> trackSignOut() async {
    await _api.trackSignOut(
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track message sent event
  /// Called when user sends a message or when AI response is received.
  ///
  /// [sender] - 'user' or 'soko'
  /// [messageType] - Optional: 'text', 'image', 'voice'
  Future<void> trackMessageSent({
    required String sender,
    String? messageType,
  }) async {
    final sessionId = _sessionId;
    if (sessionId == null) {
      debugPrint('BackendAnalytics: No session ID for message_sent, skipping');
      return;
    }
    await _api.trackMessageSent(
      sessionId: sessionId,
      sender: sender,
      messageType: messageType,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track memories page open
  /// Called when user navigates to the memories/profile screen.
  /// NOTE: Must be called explicitly - backend no longer auto-logs on memory fetch.
  Future<void> trackMemoriesOpen() async {
    await _api.trackMemoriesOpen(
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track note added/updated on list item
  /// Called when user saves a note on a list item.
  ///
  /// [itemType] - 'event' or 'place'
  Future<void> trackListElementNote({
    required String listId,
    required String itemType,
    String? eventId,
    String? venueId,
  }) async {
    await _api.trackListElementNote(
      listId: listId,
      itemType: itemType,
      eventId: eventId,
      venueId: venueId,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track item removed from list
  /// Called when user removes an item from a list.
  ///
  /// [itemType] - 'event' or 'place'
  Future<void> trackListItemRemove({
    required String listId,
    required String itemType,
    String? eventId,
    String? venueId,
  }) async {
    await _api.trackListItemRemove(
      listId: listId,
      itemType: itemType,
      eventId: eventId,
      venueId: venueId,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track list unfollow
  /// Called when user unfollows/unbookmarks a list.
  Future<void> trackListUnfollow({required String listId}) async {
    await _api.trackListUnfollow(
      listId: listId,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track list share button click
  /// Called when user clicks the share button inside a list.
  ///
  /// [shareMethod] - Optional: 'copy_link', 'social', 'whatsapp', 'email', 'other'
  Future<void> trackListShare({
    required String listId,
    String? shareMethod,
  }) async {
    await _api.trackListShare(
      listId: listId,
      shareMethod: shareMethod,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track memories download/export
  /// Called when user exports/downloads their memories.
  ///
  /// [format] - Optional: 'pdf', 'json', 'txt'
  Future<void> trackMemoriesDownload({String? format}) async {
    await _api.trackMemoriesDownload(
      format: format,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track theme change
  /// Called when user toggles light/dark mode.
  ///
  /// [theme] - 'light' or 'dark'
  Future<void> trackThemeChange({required String theme}) async {
    await _api.trackThemeChange(
      theme: theme,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track language change
  /// Called when user changes language in settings.
  ///
  /// [language] - e.g., 'en', 'pt'
  /// [previousLanguage] - Optional: previous language code
  Future<void> trackLanguageChange({
    required String language,
    String? previousLanguage,
  }) async {
    await _api.trackLanguageChange(
      language: language,
      previousLanguage: previousLanguage,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track chat history open
  /// Called when user selects a previous chat session.
  ///
  /// [sessionId] - The session being opened (not the current session)
  Future<void> trackChatHistoryOpen({required String sessionId}) async {
    await _api.trackChatHistoryOpen(
      sessionId: sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track page open (pre-auth, no authentication required)
  /// Called on landing/login/signup page load.
  ///
  /// [page] - 'landing', 'login', 'signup', 'forgot_password'
  /// [referrer] - Optional: where the user came from
  Future<void> trackPageOpen({required String page, String? referrer}) async {
    await _api.trackPageOpen(
      page: page,
      referrer: referrer,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track map view open
  /// Called when user opens the map view.
  ///
  /// [context] - 'chat', 'list', 'search'
  /// [listId] - Optional: if opened from a list context
  Future<void> trackOpenMap({required String context, String? listId}) async {
    await _api.trackOpenMap(
      context: context,
      listId: listId,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track lists menu open
  /// Called when user navigates to lists screen.
  Future<void> trackOpenLists() async {
    await _api.trackOpenLists(
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track specific list open
  /// Called when user taps on a list to view it.
  ///
  /// [isOwnList] - Whether the list belongs to the current user
  Future<void> trackListOpen({
    required String listId,
    bool isOwnList = true,
  }) async {
    await _api.trackListOpen(
      listId: listId,
      isOwnList: isOwnList,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ ONBOARDING FUNNEL EVENTS ============
  // These events don't require authentication - used during pre-auth flow

  /// Track onboarding carousel step view/interaction
  /// Called when user views, advances, or skips an onboarding step.
  ///
  /// [step] - 'hello_1', 'hello_2', 'hello_3', 'hello_4'
  /// [action] - 'view', 'next', 'skip'
  Future<void> trackOnboardingStep({
    required String step,
    required String action,
  }) async {
    await _api.trackOnboardingStep(
      step: step,
      action: action,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track onboarding flow completion
  /// Called when user completes or skips the entire onboarding.
  ///
  /// [completedSteps] - List of steps completed
  /// [skippedAtStep] - Step where user skipped (null if completed all)
  /// [totalTimeSeconds] - Time spent in onboarding
  Future<void> trackOnboardingComplete({
    required List<String> completedSteps,
    String? skippedAtStep,
    int? totalTimeSeconds,
  }) async {
    await _api.trackOnboardingComplete(
      completedSteps: completedSteps,
      skippedAtStep: skippedAtStep,
      totalTimeSeconds: totalTimeSeconds,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track location permission flow
  /// Called at various points in the location permission flow.
  ///
  /// [action] - 'prompt_shown', 'allowed', 'denied', 'skipped', 'settings_opened'
  /// [permissionStatus] - 'granted', 'denied', 'restricted', 'limited'
  /// [isFirstPrompt] - Whether this is the first time showing the prompt
  Future<void> trackLocationPermission({
    required String action,
    String? permissionStatus,
    bool isFirstPrompt = true,
  }) async {
    await _api.trackLocationPermission(
      action: action,
      permissionStatus: permissionStatus,
      isFirstPrompt: isFirstPrompt,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track auth page views and method selection
  /// Called when user views auth pages or selects an auth method.
  ///
  /// [page] - 'login', 'signup'
  /// [action] - 'view', 'method_selected'
  /// [method] - 'google', 'apple', 'phone', 'email' (for method_selected)
  /// [referrer] - 'onboarding', 'deep_link', 'direct'
  Future<void> trackAuthPrompt({
    required String page,
    required String action,
    String? method,
    String? referrer,
  }) async {
    await _api.trackAuthPrompt(
      page: page,
      action: action,
      method: method,
      referrer: referrer,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ LOCATION SUGGESTION CARD EVENTS ============

  /// Track in-chat location suggestion card interactions
  /// Called when the card is displayed, user taps "Share my location", or "Not now".
  ///
  /// [action] - 'impression', 'share_tapped', 'dismissed'
  Future<void> trackLocationSuggestion({required String action}) async {
    await _api.trackLocationSuggestion(
      action: action,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ SPLIT MESSAGE EVENTS ============

  /// Track user message sent event
  /// Called when user sends a message (text, image, or voice).
  ///
  /// [messageType] - Optional: 'text', 'image', 'voice'
  Future<void> trackMessageSentUser({String? messageType}) async {
    final sessionId = _sessionId;
    if (sessionId == null) {
      debugPrint(
        'BackendAnalytics: No session ID for message_sent_user, skipping',
      );
      return;
    }
    await _api.trackMessageSentUser(
      sessionId: sessionId,
      messageType: messageType,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track Soko (AI) message sent event
  /// Called when AI response is received/displayed.
  ///
  /// [messageType] - Optional: 'text', 'image', 'voice'
  Future<void> trackMessageSentSoko({String? messageType}) async {
    final sessionId = _sessionId;
    if (sessionId == null) {
      debugPrint(
        'BackendAnalytics: No session ID for message_sent_soko, skipping',
      );
      return;
    }
    await _api.trackMessageSentSoko(
      sessionId: sessionId,
      messageType: messageType,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ MENU/PROFILE EVENTS ============

  /// Track account menu opened
  /// Called when user navigates to Account section in profile.
  Future<void> trackAccountOpen() async {
    await _api.trackAccountOpen(
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track preferences menu opened
  /// Called when user navigates to Preferences/Settings section in profile.
  Future<void> trackPreferencesOpen() async {
    await _api.trackPreferencesOpen(
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track support menu opened
  /// Called when user navigates to Support section in profile.
  Future<void> trackSupportOpen() async {
    await _api.trackSupportOpen(
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track support email link clicked
  /// Called when user clicks the mailto: support link.
  Future<void> trackSupportEmailClick() async {
    await _api.trackSupportEmailClick(
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ LIST VIEW MODE EVENTS ============

  /// Track list calendar view opened
  /// Called when user switches to Calendar view in a list.
  Future<void> trackListCalendar({required String listId}) async {
    await _api.trackListCalendar(
      listId: listId,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  /// Track list map view opened
  /// Called when user switches to Map view in a list.
  Future<void> trackListMap({required String listId}) async {
    await _api.trackListMap(
      listId: listId,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ LIST CRUD EVENTS ============

  Future<void> trackListCreate({
    required String listId,
    required bool isPublic,
    bool hasDescription = false,
    bool hasPrompt = false,
    String? source,
    String? listName,
  }) async {
    await _api.trackListCreate(
      listId: listId,
      isPublic: isPublic,
      hasDescription: hasDescription,
      hasPrompt: hasPrompt,
      source: source,
      listName: listName,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackListUpdate({
    required String listId,
    String? listName,
  }) async {
    await _api.trackListUpdate(
      listId: listId,
      listName: listName,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackListDelete({
    required String listId,
    int? itemCount,
    String? listName,
  }) async {
    await _api.trackListDelete(
      listId: listId,
      itemCount: itemCount,
      listName: listName,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackListFollow({
    required String listId,
    String? listName,
  }) async {
    await _api.trackListFollow(
      listId: listId,
      listName: listName,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackListItemAdd({
    required String listId,
    required String itemType,
    String? source,
    String? eventId,
    String? venueId,
    String? itemName,
  }) async {
    await _api.trackListItemAdd(
      listId: listId,
      itemType: itemType,
      source: source,
      eventId: eventId,
      venueId: venueId,
      itemName: itemName,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ LIST SEARCH EVENTS ============

  Future<void> trackListSearch({
    required String query,
    required String tab,
    required int resultCount,
    required String listId,
  }) async {
    await _api.trackListSearch(
      query: query,
      tab: tab,
      resultCount: resultCount,
      listId: listId,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ LISTS HUB EVENTS ============

  Future<void> trackListsHubFilter({required String filter}) async {
    await _api.trackListsHubFilter(
      filter: filter,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackListsHubSearch({
    required String query,
    required int resultCount,
  }) async {
    await _api.trackListsHubSearch(
      query: query,
      resultCount: resultCount,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ LIST MANAGEMENT EVENTS ============

  Future<void> trackListReorder({
    required String listId,
    String? listName,
  }) async {
    await _api.trackListReorder(
      listId: listId,
      listName: listName,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackListCoverChange({
    required String listId,
    String? listName,
  }) async {
    await _api.trackListCoverChange(
      listId: listId,
      listName: listName,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackListVisibilityChange({
    required String listId,
    required String visibility,
    String? listName,
  }) async {
    await _api.trackListVisibilityChange(
      listId: listId,
      visibility: visibility,
      listName: listName,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ LIST IMPORT EVENTS ============

  Future<void> trackListImportStart({required String url}) async {
    await _api.trackListImportStart(
      url: url,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackListImportComplete({
    required String listId,
    required int itemCount,
    String? listName,
  }) async {
    await _api.trackListImportComplete(
      listId: listId,
      itemCount: itemCount,
      listName: listName,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ SUGGESTION EVENTS ============

  Future<void> trackSuggestionAccept({
    required String listId,
    required String itemType,
    String? itemName,
  }) async {
    await _api.trackSuggestionAccept(
      listId: listId,
      itemType: itemType,
      itemName: itemName,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackSuggestionDismiss({
    required String listId,
    required String itemType,
    String? itemName,
  }) async {
    await _api.trackSuggestionDismiss(
      listId: listId,
      itemType: itemType,
      itemName: itemName,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  // ============ DAILY DROP EVENTS ============

  Future<void> trackDailyDropOpen({
    String? recommendationId,
    String? itemType,
    String? category,
  }) async {
    await _api.trackDailyDropOpen(
      recommendationId: recommendationId,
      itemType: itemType,
      category: category,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }
  // PROD-2565 — react/save/share/cta/close removed with the deprecated overlay.

  // ============ WEEKLY BUNDLE EVENTS ============

  Future<void> trackWeeklyBundleOpen({
    String? batchId,
    int? itemCount,
    int? pageCount,
  }) async {
    await _api.trackWeeklyBundleOpen(
      batchId: batchId,
      itemCount: itemCount,
      pageCount: pageCount,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackWeeklyBundlePageView({
    String? batchId,
    int? pageIndex,
    int? pageCount,
  }) async {
    await _api.trackWeeklyBundlePageView(
      batchId: batchId,
      pageIndex: pageIndex,
      pageCount: pageCount,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackWeeklyBundleItemTap({
    String? batchId,
    String? recommendationId,
    String? itemType,
    String? itemName,
  }) async {
    await _api.trackWeeklyBundleItemTap(
      batchId: batchId,
      recommendationId: recommendationId,
      itemType: itemType,
      itemName: itemName,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackWeeklyBundleItemsToggle({
    String? batchId,
    String? view,
  }) async {
    await _api.trackWeeklyBundleItemsToggle(
      batchId: batchId,
      view: view,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }

  Future<void> trackWeeklyBundleClose({
    String? batchId,
    int? lastPageViewed,
    int? pageCount,
  }) async {
    await _api.trackWeeklyBundleClose(
      batchId: batchId,
      lastPageViewed: lastPageViewed,
      pageCount: pageCount,
      sessionId: _sessionId,
      visitorId: await _getVisitorId(),
    );
  }
}
