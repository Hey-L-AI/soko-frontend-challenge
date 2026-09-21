import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/api_constants.dart';
import 'api_client.dart';

/// API for tracking analytics events to the backend.
/// All endpoints use fire-and-forget pattern - they return 202 Accepted immediately
/// and should never block the UI or have their errors propagated.
class AnalyticsEventsApi {
  final ApiClient _apiClient;

  AnalyticsEventsApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Generic event tracking via the unified analytics endpoint.
  ///
  /// All events can be dispatched through this single method.
  /// Backend validates event_name against its registry allowlist.
  Future<void> trackGeneric({
    required String eventName,
    Map<String, dynamic>? properties,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsTrack,
        data: {
          'event_name': eventName,
          if (properties != null && properties.isNotEmpty)
            'properties': properties,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      if (kDebugMode) {
        debugPrint('📊 Backend Analytics: $eventName tracked');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('📊 Backend Analytics: $eventName failed - $e');
      }
    }
  }

  /// Track app open event
  /// Called on app startup/foreground after authentication is confirmed.
  Future<void> trackAppOpen({
    String? appVersion,
    String? sessionId,
    String? authMethod,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsAppOpen,
        data: {
          if (appVersion != null) 'app_version': appVersion,
          if (sessionId != null) 'session_id': sessionId,
          if (authMethod != null) 'auth_method': authMethod,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: app_open tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: app_open failed - $e');
    }
  }

  /// Track search result click
  /// Called when user taps/clicks a search result item to view details.
  Future<void> trackSearchResultClick({
    String? sessionId,
    String? eventId,
    String? venueId,
    String? intent,
    int? resultPosition,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsSearchResultClick,
        data: {
          if (sessionId != null) 'session_id': sessionId,
          if (eventId != null) 'event_id': eventId,
          if (venueId != null) 'venue_id': venueId,
          if (intent != null) 'intent': intent,
          if (resultPosition != null) 'result_position': resultPosition,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: search_result_click tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: search_result_click failed - $e');
    }
  }

  /// Track external click event
  /// Called when user clicks a link that opens outside the app (Google Maps, website, ticketing, etc.)
  Future<void> trackExternalClick({
    String? sessionId,
    required String destinationType,
    required String destinationUrl,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsExternalClick,
        data: {
          if (sessionId != null) 'session_id': sessionId,
          'destination_type': destinationType,
          'destination_url': destinationUrl,
          if (eventId != null) 'event_id': eventId,
          if (venueId != null) 'venue_id': venueId,
          if (originSource != null) 'origin_source': originSource,
          if (originEntityId != null) 'origin_entity_id': originEntityId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint(
        '📊 Backend Analytics: external_click tracked ($destinationType)',
      );
    } catch (e) {
      debugPrint('📊 Backend Analytics: external_click failed - $e');
    }
  }

  /// Track list link clicked item event
  /// Called when viewing a public list (via share link) and user taps an item.
  /// Auth is optional - works for anonymous users viewing public lists.
  Future<void> trackListLinkClickedItem({
    required String listId,
    required String itemType,
    String? eventId,
    String? venueId,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListLinkClickedItem,
        data: {
          'list_id': listId,
          'item_type': itemType,
          if (eventId != null) 'event_id': eventId,
          if (venueId != null) 'venue_id': venueId,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_link_clicked_item tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_link_clicked_item failed - $e');
    }
  }

  // ============ NEW ANALYTICS ENDPOINTS ============

  /// Track sign out event
  /// Called when user taps logout button.
  Future<void> trackSignOut({String? sessionId, String? visitorId}) async {
    try {
      await _dio.post(
        ApiConstants.analyticsSignOut,
        data: {
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: sign_out tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: sign_out failed - $e');
    }
  }

  /// Track message sent event
  /// Called when user sends a message or when AI response is received.
  Future<void> trackMessageSent({
    required String sessionId,
    required String sender,
    String? messageType,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsMessageSent,
        data: {
          'session_id': sessionId,
          'sender': sender,
          if (messageType != null) 'message_type': messageType,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint(
        '📊 Backend Analytics: message_sent tracked (sender: $sender)',
      );
    } catch (e) {
      debugPrint('📊 Backend Analytics: message_sent failed - $e');
    }
  }

  /// Track memories page open
  /// Called when user navigates to the memories/profile screen.
  Future<void> trackMemoriesOpen({String? sessionId, String? visitorId}) async {
    try {
      await _dio.post(
        ApiConstants.analyticsMemoriesOpen,
        data: {
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: memories_open tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: memories_open failed - $e');
    }
  }

  /// Track note added/updated on list item
  /// Called when user saves a note on a list item.
  Future<void> trackListElementNote({
    required String listId,
    required String itemType,
    String? eventId,
    String? venueId,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListElementNote,
        data: {
          'list_id': listId,
          'item_type': itemType,
          if (eventId != null) 'event_id': eventId,
          if (venueId != null) 'venue_id': venueId,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_element_note tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_element_note failed - $e');
    }
  }

  /// Track item removed from list
  /// Called when user removes an item from a list.
  Future<void> trackListItemRemove({
    required String listId,
    required String itemType,
    String? eventId,
    String? venueId,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListItemRemove,
        data: {
          'list_id': listId,
          'item_type': itemType,
          if (eventId != null) 'event_id': eventId,
          if (venueId != null) 'venue_id': venueId,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_item_remove tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_item_remove failed - $e');
    }
  }

  /// Track list unfollow
  /// Called when user unfollows/unbookmarks a list.
  Future<void> trackListUnfollow({
    required String listId,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListUnfollow,
        data: {
          'list_id': listId,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_unfollow tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_unfollow failed - $e');
    }
  }

  /// Track list share button click
  /// Called when user clicks the share button inside a list.
  Future<void> trackListShare({
    required String listId,
    String? shareMethod,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListShare,
        data: {
          'list_id': listId,
          if (shareMethod != null) 'share_method': shareMethod,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_share tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_share failed - $e');
    }
  }

  /// Track memories download/export
  /// Called when user exports/downloads their memories.
  Future<void> trackMemoriesDownload({
    String? format,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsMemoriesDownload,
        data: {
          if (format != null) 'format': format,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: memories_download tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: memories_download failed - $e');
    }
  }

  /// Track theme change
  /// Called when user toggles light/dark mode.
  Future<void> trackThemeChange({
    required String theme,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsThemeChange,
        data: {
          'theme': theme,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: theme_change tracked ($theme)');
    } catch (e) {
      debugPrint('📊 Backend Analytics: theme_change failed - $e');
    }
  }

  /// Track language change
  /// Called when user changes language in settings.
  Future<void> trackLanguageChange({
    required String language,
    String? previousLanguage,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsLanguageChange,
        data: {
          'language': language,
          if (previousLanguage != null) 'previous_language': previousLanguage,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: language_change tracked ($language)');
    } catch (e) {
      debugPrint('📊 Backend Analytics: language_change failed - $e');
    }
  }

  /// Track chat history open
  /// Called when user selects a previous chat session.
  Future<void> trackChatHistoryOpen({
    required String sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsChatHistoryOpen,
        data: {
          'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: chat_history_open tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: chat_history_open failed - $e');
    }
  }

  /// Track page open (pre-auth, no authentication required)
  /// Called on landing/login/signup page load.
  Future<void> trackPageOpen({
    required String page,
    String? referrer,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      // Use unauthenticated request for pre-auth pages
      await _dio.post(
        ApiConstants.analyticsPageOpen,
        data: {
          'page': page,
          if (referrer != null) 'referrer': referrer,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: page_open tracked ($page)');
    } catch (e) {
      debugPrint('📊 Backend Analytics: page_open failed - $e');
    }
  }

  /// Track map view open
  /// Called when user opens the map view.
  Future<void> trackOpenMap({
    required String context,
    String? listId,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsOpenMap,
        data: {
          'context': context,
          if (listId != null) 'list_id': listId,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: open_map tracked ($context)');
    } catch (e) {
      debugPrint('📊 Backend Analytics: open_map failed - $e');
    }
  }

  /// Track lists menu open
  /// Called when user navigates to lists screen.
  Future<void> trackOpenLists({String? sessionId, String? visitorId}) async {
    try {
      await _dio.post(
        ApiConstants.analyticsOpenLists,
        data: {
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: open_lists tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: open_lists failed - $e');
    }
  }

  /// Track specific list open
  /// Called when user taps on a list to view it.
  Future<void> trackListOpen({
    required String listId,
    bool isOwnList = true,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListOpen,
        data: {
          'list_id': listId,
          'is_own_list': isOwnList,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_open tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_open failed - $e');
    }
  }

  // ============ ONBOARDING FUNNEL EVENTS ============

  /// Track onboarding carousel step view/interaction
  /// Called when user views, advances, or skips an onboarding step.
  ///
  /// [step] - 'hello_1', 'hello_2', 'hello_3', 'hello_4'
  /// [action] - 'view', 'next', 'skip'
  Future<void> trackOnboardingStep({
    required String step,
    required String action,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsOnboardingStep,
        data: {
          'step': step,
          'action': action,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint(
        '📊 Backend Analytics: onboarding_step tracked ($step, $action)',
      );
    } catch (e) {
      debugPrint('📊 Backend Analytics: onboarding_step failed - $e');
    }
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
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsOnboardingComplete,
        data: {
          'completed_steps': completedSteps,
          if (skippedAtStep != null) 'skipped_at_step': skippedAtStep,
          if (totalTimeSeconds != null) 'total_time_seconds': totalTimeSeconds,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: onboarding_complete tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: onboarding_complete failed - $e');
    }
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
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsLocationPermission,
        data: {
          'action': action,
          if (permissionStatus != null) 'permission_status': permissionStatus,
          'is_first_prompt': isFirstPrompt,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: location_permission tracked ($action)');
    } catch (e) {
      debugPrint('📊 Backend Analytics: location_permission failed - $e');
    }
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
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsAuthPrompt,
        data: {
          'page': page,
          'action': action,
          if (method != null) 'method': method,
          if (referrer != null) 'referrer': referrer,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: auth_prompt tracked ($page, $action)');
    } catch (e) {
      debugPrint('📊 Backend Analytics: auth_prompt failed - $e');
    }
  }

  // ============ LOCATION SUGGESTION CARD EVENTS ============

  /// Track in-chat location suggestion card interactions
  /// Called when the card is displayed, user taps "Share my location", or "Not now".
  ///
  /// [action] - 'impression', 'share_tapped', 'dismissed'
  Future<void> trackLocationSuggestion({
    required String action,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsLocationSuggestion,
        data: {
          'action': action,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: location_suggestion tracked ($action)');
    } catch (e) {
      debugPrint('📊 Backend Analytics: location_suggestion failed - $e');
    }
  }

  // ============ SPLIT MESSAGE EVENTS ============

  /// Track user message sent event
  /// Called when user sends a message (text, image, or voice).
  Future<void> trackMessageSentUser({
    required String sessionId,
    String? messageType,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsMessageSentUser,
        data: {
          'session_id': sessionId,
          if (messageType != null) 'message_type': messageType,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: message_sent_user tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: message_sent_user failed - $e');
    }
  }

  /// Track Soko (AI) message sent event
  /// Called when AI response is received/displayed.
  Future<void> trackMessageSentSoko({
    required String sessionId,
    String? messageType,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsMessageSentSoko,
        data: {
          'session_id': sessionId,
          if (messageType != null) 'message_type': messageType,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: message_sent_soko tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: message_sent_soko failed - $e');
    }
  }

  // ============ MENU/PROFILE EVENTS ============

  /// Track account menu opened
  /// Called when user navigates to Account section in profile.
  Future<void> trackAccountOpen({String? sessionId, String? visitorId}) async {
    try {
      await _dio.post(
        ApiConstants.analyticsAccountOpen,
        data: {
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: account_open tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: account_open failed - $e');
    }
  }

  /// Track preferences menu opened
  /// Called when user navigates to Preferences/Settings section in profile.
  Future<void> trackPreferencesOpen({
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsPreferencesOpen,
        data: {
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: preferences_open tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: preferences_open failed - $e');
    }
  }

  /// Track support menu opened
  /// Called when user navigates to Support section in profile.
  Future<void> trackSupportOpen({String? sessionId, String? visitorId}) async {
    try {
      await _dio.post(
        ApiConstants.analyticsSupportOpen,
        data: {
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: support_open tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: support_open failed - $e');
    }
  }

  /// Track support email link clicked
  /// Called when user clicks the mailto: support link.
  Future<void> trackSupportEmailClick({
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsSupportEmailClick,
        data: {
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: support_email_click tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: support_email_click failed - $e');
    }
  }

  // ============ LIST VIEW MODE EVENTS ============

  /// Track list calendar view opened
  /// Called when user switches to Calendar view in a list.
  Future<void> trackListCalendar({
    required String listId,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListCalendar,
        data: {
          'list_id': listId,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_calendar tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_calendar failed - $e');
    }
  }

  /// Track list map view opened
  /// Called when user switches to Map view in a list.
  Future<void> trackListMap({
    required String listId,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListMap,
        data: {
          'list_id': listId,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_map tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_map failed - $e');
    }
  }

  // ============ LIST CRUD EVENTS ============

  Future<void> trackListCreate({
    required String listId,
    required bool isPublic,
    bool hasDescription = false,
    bool hasPrompt = false,
    String? source,
    String? listName,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListCreate,
        data: {
          'list_id': listId,
          'is_public': isPublic,
          'has_description': hasDescription,
          'has_prompt': hasPrompt,
          if (source != null) 'source': source,
          if (listName != null) 'list_name': listName,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_create tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_create failed - $e');
    }
  }

  Future<void> trackListUpdate({
    required String listId,
    String? listName,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListUpdate,
        data: {
          'list_id': listId,
          if (listName != null) 'list_name': listName,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_update tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_update failed - $e');
    }
  }

  Future<void> trackListDelete({
    required String listId,
    int? itemCount,
    String? listName,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListDelete,
        data: {
          'list_id': listId,
          if (itemCount != null) 'item_count': itemCount,
          if (listName != null) 'list_name': listName,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_delete tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_delete failed - $e');
    }
  }

  Future<void> trackListFollow({
    required String listId,
    String? listName,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListFollow,
        data: {
          'list_id': listId,
          if (listName != null) 'list_name': listName,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_follow tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_follow failed - $e');
    }
  }

  Future<void> trackListItemAdd({
    required String listId,
    required String itemType,
    String? source,
    String? eventId,
    String? venueId,
    String? itemName,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListItemAdd,
        data: {
          'list_id': listId,
          'item_type': itemType,
          if (source != null) 'source': source,
          if (eventId != null) 'event_id': eventId,
          if (venueId != null) 'venue_id': venueId,
          if (itemName != null) 'item_name': itemName,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_item_add tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_item_add failed - $e');
    }
  }

  // ============ LIST SEARCH EVENTS ============

  Future<void> trackListSearch({
    required String query,
    required String tab,
    required int resultCount,
    required String listId,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListSearch,
        data: {
          'query': query,
          'tab': tab,
          'result_count': resultCount,
          'list_id': listId,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_search tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_search failed - $e');
    }
  }

  // ============ LISTS HUB EVENTS ============

  Future<void> trackListsHubFilter({
    required String filter,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListsHubFilter,
        data: {
          'filter': filter,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: lists_hub_filter tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: lists_hub_filter failed - $e');
    }
  }

  Future<void> trackListsHubSearch({
    required String query,
    required int resultCount,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListsHubSearch,
        data: {
          'query': query,
          'result_count': resultCount,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: lists_hub_search tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: lists_hub_search failed - $e');
    }
  }

  // ============ LIST MANAGEMENT EVENTS ============

  Future<void> trackListReorder({
    required String listId,
    String? listName,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListReorder,
        data: {
          'list_id': listId,
          if (listName != null) 'list_name': listName,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_reorder tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_reorder failed - $e');
    }
  }

  Future<void> trackListCoverChange({
    required String listId,
    String? listName,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListCoverChange,
        data: {
          'list_id': listId,
          if (listName != null) 'list_name': listName,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_cover_change tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_cover_change failed - $e');
    }
  }

  Future<void> trackListVisibilityChange({
    required String listId,
    required String visibility,
    String? listName,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListVisibilityChange,
        data: {
          'list_id': listId,
          'visibility': visibility,
          if (listName != null) 'list_name': listName,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_visibility_change tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_visibility_change failed - $e');
    }
  }

  // ============ LIST IMPORT EVENTS ============

  Future<void> trackListImportStart({
    required String url,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListImportStart,
        data: {
          'url': url,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_import_start tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_import_start failed - $e');
    }
  }

  Future<void> trackListImportComplete({
    required String listId,
    required int itemCount,
    String? listName,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsListImportComplete,
        data: {
          'list_id': listId,
          'item_count': itemCount,
          if (listName != null) 'list_name': listName,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: list_import_complete tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: list_import_complete failed - $e');
    }
  }

  // ============ SUGGESTION EVENTS ============

  Future<void> trackSuggestionAccept({
    required String listId,
    required String itemType,
    String? itemName,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsSuggestionAccept,
        data: {
          'list_id': listId,
          'item_type': itemType,
          if (itemName != null) 'item_name': itemName,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: suggestion_accept tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: suggestion_accept failed - $e');
    }
  }

  Future<void> trackSuggestionDismiss({
    required String listId,
    required String itemType,
    String? itemName,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsSuggestionDismiss,
        data: {
          'list_id': listId,
          'item_type': itemType,
          if (itemName != null) 'item_name': itemName,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: suggestion_dismiss tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: suggestion_dismiss failed - $e');
    }
  }

  // ============ DAILY DROP EVENTS ============

  Future<void> trackDailyDropOpen({
    String? recommendationId,
    String? itemType,
    String? category,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsDailyDropOpen,
        data: {
          if (recommendationId != null) 'recommendation_id': recommendationId,
          if (itemType != null) 'item_type': itemType,
          if (category != null) 'category': category,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: daily_drop_open tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: daily_drop_open failed - $e');
    }
  }

  // PROD-2565 — daily_drop react/save/share/cta/close removed with the
  // deprecated overlay; only daily_drop_open remains.

  // ============ WEEKLY BUNDLE EVENTS ============

  Future<void> trackWeeklyBundleOpen({
    String? batchId,
    int? itemCount,
    int? pageCount,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsWeeklyBundleOpen,
        data: {
          if (batchId != null) 'batch_id': batchId,
          if (itemCount != null) 'item_count': itemCount,
          if (pageCount != null) 'page_count': pageCount,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: weekly_bundle_open tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: weekly_bundle_open failed - $e');
    }
  }

  Future<void> trackWeeklyBundlePageView({
    String? batchId,
    int? pageIndex,
    int? pageCount,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsWeeklyBundlePageView,
        data: {
          if (batchId != null) 'batch_id': batchId,
          if (pageIndex != null) 'page_index': pageIndex,
          if (pageCount != null) 'page_count': pageCount,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: weekly_bundle_page_view tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: weekly_bundle_page_view failed - $e');
    }
  }

  Future<void> trackWeeklyBundleItemTap({
    String? batchId,
    String? recommendationId,
    String? itemType,
    String? itemName,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsWeeklyBundleItemTap,
        data: {
          if (batchId != null) 'batch_id': batchId,
          if (recommendationId != null) 'recommendation_id': recommendationId,
          if (itemType != null) 'item_type': itemType,
          if (itemName != null) 'item_name': itemName,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: weekly_bundle_item_tap tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: weekly_bundle_item_tap failed - $e');
    }
  }

  Future<void> trackWeeklyBundleItemsToggle({
    String? batchId,
    String? view,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsWeeklyBundleItemsToggle,
        data: {
          if (batchId != null) 'batch_id': batchId,
          if (view != null) 'view': view,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: weekly_bundle_items_toggle tracked');
    } catch (e) {
      debugPrint(
        '📊 Backend Analytics: weekly_bundle_items_toggle failed - $e',
      );
    }
  }

  Future<void> trackWeeklyBundleClose({
    String? batchId,
    int? lastPageViewed,
    int? pageCount,
    String? sessionId,
    String? visitorId,
  }) async {
    try {
      await _dio.post(
        ApiConstants.analyticsWeeklyBundleClose,
        data: {
          if (batchId != null) 'batch_id': batchId,
          if (lastPageViewed != null) 'last_page_viewed': lastPageViewed,
          if (pageCount != null) 'page_count': pageCount,
          if (sessionId != null) 'session_id': sessionId,
          if (visitorId != null) 'visitor_id': visitorId,
        },
      );
      debugPrint('📊 Backend Analytics: weekly_bundle_close tracked');
    } catch (e) {
      debugPrint('📊 Backend Analytics: weekly_bundle_close failed - $e');
    }
  }
}
