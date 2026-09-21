import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/services/attribution_service.dart';
import '../core/services/feed_impression_sender.dart';
import '../core/services/discovery_engagement_sender.dart';
import '../core/services/discovery_session_tracker.dart';
import '../core/services/auth_diagnostics_service.dart';
import '../core/services/auth_event_service.dart';
import '../core/services/refresh_coordinator.dart';
import '../core/services/storage_service.dart';
import '../core/services/token_refresh_service.dart';
import '../data/datasources/api/api.dart';
import '../data/datasources/api/memory_twin_api.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import '../data/datasources/interfaces/campaign_api.dart';
import '../data/datasources/interfaces/eula_api.dart';
import '../data/datasources/interfaces/feature_spotlights_api.dart';
import '../data/datasources/interfaces/memory_twin_api.dart';
import '../data/datasources/interfaces/moderation_api.dart';
import '../data/datasources/interfaces/venue_claim_api.dart';
import '../data/datasources/mock/mock_api.dart';
import '../data/datasources/mock/mock_memory_twin_api.dart';
import '../shared/widgets/impression_detector.dart';
import 'auth_provider.dart';
import 'locale_provider.dart';
import '../features/discovery/feed_v2/providers/feed_filter_provider.dart';

/// Provider for mock API toggle - set to true for mock, false for real API
final useMockApiProvider = StateProvider<bool>((ref) => false);

/// Provider for cookie jar (for refresh token persistence).
/// Uses PersistCookieJar on native platforms so refresh token cookies
/// survive app restarts. In-memory CookieJar on web (browser handles cookies).
final cookieJarProvider = FutureProvider<CookieJar>((ref) async {
  if (kIsWeb) {
    return CookieJar();
  }
  final dir = await getApplicationDocumentsDirectory();
  return PersistCookieJar(storage: FileStorage('${dir.path}/.cookies/'));
});

/// PROD-2095 — Single-flight refresh coordinator. The single owner of
/// `Future<RefreshOutcome>? _inflight`, the dedicated refresh Dio, and
/// the `/auth/refresh` POST. Every refresh entry point delegates here:
/// [RefreshInterceptor] on 401, [TokenSchedulerService] proactively,
/// `AuthNotifier._attemptTokenRefresh` on startup `/auth/me` 401,
/// `AuthNotifier.ensureFreshToken` before Instagram external nav.
final refreshCoordinatorProvider = Provider<RefreshCoordinator>((ref) {
  final storage = ref.watch(storageServiceProvider);
  final tokenRefresh = ref.read(tokenRefreshServiceProvider.notifier);
  final diagnostics = ref.watch(authDiagnosticsProvider);
  final cookieJar = ref.watch(cookieJarProvider).valueOrNull;

  return RefreshCoordinator(
    storageService: storage,
    tokenRefreshService: tokenRefresh,
    diagnostics: diagnostics,
    cookieJar: cookieJar,
  );
});

/// Provider for API client
final apiClientProvider = Provider<ApiClient>((ref) {
  final storageService = ref.watch(storageServiceProvider);
  final authEventService = ref.watch(authEventServiceProvider);
  final tokenRefreshService = ref.watch(tokenRefreshServiceProvider.notifier);
  final diagnostics = ref.watch(authDiagnosticsProvider);
  final refreshCoordinator = ref.watch(refreshCoordinatorProvider);
  // cookieJarProvider is pre-resolved in main() and overridden in ProviderScope,
  // so it should always resolve synchronously. The loading/error fallbacks are
  // a safety net — if they fire, cookies won't persist across restarts.
  final cookieJar = ref
      .watch(cookieJarProvider)
      .when(
        data: (jar) => jar,
        loading: () {
          assert(
            false,
            'cookieJarProvider should be pre-resolved — using transient fallback',
          );
          return CookieJar();
        },
        error: (e, __) {
          assert(
            false,
            'cookieJarProvider failed: $e — using transient fallback',
          );
          return CookieJar();
        },
      );
  return ApiClient(
    storageService: storageService,
    authEventService: authEventService,
    tokenRefreshService: tokenRefreshService,
    diagnostics: diagnostics,
    refreshCoordinator: refreshCoordinator,
    cookieJar: cookieJar,
    // PROD-1979 — guest re-mint needs the persisted visitor_id.
    // Reading via `ref.read` inside the closure breaks the otherwise
    // circular dependency (attribution_service depends on
    // attributionApiProvider which depends on apiClientProvider).
    // Late resolution is fine because the closure only runs from the
    // refresh interceptor — long after providers have been initialized.
    getVisitorId: () => _readAttributionVisitorId(ref),
    // PROD-2037 — Accept-Language header sourced from the normalized
    // app locale. Same late-binding rationale as getVisitorId:
    // `localeProvider` depends on `authMethodsApiProvider` (for syncing
    // user-driven locale changes), which itself depends on this client.
    // Reading via `ref.read` inside the closure breaks the cycle at
    // construction time.
    getLocaleCode: () => ref.read(apiLocaleCodeProvider),
  );
});

/// PROD-1979 — late-bound lookup so we don't form a top-level cycle
/// between `apiClientProvider`, `attributionApiProvider` and
/// `attributionServiceProvider` at construction time.
Future<String> _readAttributionVisitorId(Ref ref) {
  final service = ref.read(attributionServiceProvider);
  return service.getVisitorId();
}

// ============ Auth API ============

/// Provider for Mock Auth API
final mockAuthApiProvider = Provider<MockAuthApi>((ref) {
  return MockAuthApi();
});

/// Provider for Real Auth API
final realAuthApiProvider = Provider<AuthApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return AuthApi(apiClient: apiClient);
});

/// Provider for Auth API (mock or real based on toggle)
final authApiProvider = Provider<IAuthApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return ref.watch(mockAuthApiProvider);
  }
  return ref.watch(realAuthApiProvider);
});

// ============ Sessions API ============

/// Provider for Mock Sessions API
final mockSessionsApiProvider = Provider<MockSessionsApi>((ref) {
  return MockSessionsApi();
});

/// Provider for Real Sessions API
final realSessionsApiProvider = Provider<SessionsApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SessionsApi(apiClient: apiClient);
});

/// Provider for Sessions API (mock or real based on toggle)
final sessionsApiProvider = Provider<ISessionsApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return ref.watch(mockSessionsApiProvider);
  }
  return ref.watch(realSessionsApiProvider);
});

// ============ Messages API ============

/// Provider for Mock Messages API
final mockMessagesApiProvider = Provider<MockMessagesApi>((ref) {
  final sessionsApi = ref.watch(mockSessionsApiProvider);
  return MockMessagesApi(sessionsApi);
});

/// Provider for Real Messages API
final realMessagesApiProvider = Provider<MessagesApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final storageService = ref.watch(storageServiceProvider);
  return MessagesApi(apiClient: apiClient, storageService: storageService);
});

/// Provider for Messages API (mock or real based on toggle)
final messagesApiProvider = Provider<IMessagesApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return ref.watch(mockMessagesApiProvider);
  }
  return ref.watch(realMessagesApiProvider);
});

// ============ Events API ============

/// Provider for Mock Events API
final mockEventsApiProvider = Provider<MockEventsApi>((ref) {
  return MockEventsApi();
});

/// Provider for Real Events API
final realEventsApiProvider = Provider<EventsApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return EventsApi(apiClient: apiClient);
});

/// Provider for Events API (mock or real based on toggle)
final eventsApiProvider = Provider<IEventsApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return ref.watch(mockEventsApiProvider);
  }
  return ref.watch(realEventsApiProvider);
});

// ============ Venues API ============

/// Provider for Mock Venues API
final mockVenuesApiProvider = Provider<MockVenuesApi>((ref) {
  return MockVenuesApi();
});

/// Provider for Real Venues API
final realVenuesApiProvider = Provider<VenuesApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return VenuesApi(apiClient: apiClient);
});

/// Provider for Venues API (mock or real based on toggle)
final venuesApiProvider = Provider<IVenuesApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return ref.watch(mockVenuesApiProvider);
  }
  return ref.watch(realVenuesApiProvider);
});

// ============ Business ownership / claims API ============

final venueClaimApiProvider = Provider<IVenueClaimApi>((ref) {
  return VenueClaimApi(apiClient: ref.watch(apiClientProvider));
});

// ============ Saved API ============

/// Provider for Mock Saved API
final mockSavedApiProvider = Provider<MockSavedApi>((ref) {
  return MockSavedApi();
});

/// Provider for Real Saved API
final realSavedApiProvider = Provider<SavedApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SavedApi(apiClient: apiClient);
});

/// Provider for Saved API (mock or real based on toggle)
final savedApiProvider = Provider<ISavedApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return ref.watch(mockSavedApiProvider);
  }
  return ref.watch(realSavedApiProvider);
});

final mockLibraryApiProvider = Provider<MockLibraryApi>((ref) {
  return MockLibraryApi();
});

final realLibraryApiProvider = Provider<LibraryApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return LibraryApi(apiClient: apiClient);
});

final libraryApiProvider = Provider<ILibraryApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return ref.watch(mockLibraryApiProvider);
  }
  return ref.watch(realLibraryApiProvider);
});

// ============ Lists API ============

/// Provider for Mock Lists API
final mockListsApiProvider = Provider<MockListsApi>((ref) {
  return MockListsApi();
});

/// Provider for Real Lists API
final realListsApiProvider = Provider<ListsApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return ListsApi(apiClient: apiClient);
});

/// Provider for Lists API (mock or real based on toggle)
final listsApiProvider = Provider<IListsApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return ref.watch(mockListsApiProvider);
  }
  return ref.watch(realListsApiProvider);
});

// ============ Memory API ============

/// Provider for Mock Memory API
final mockMemoryApiProvider = Provider<MockMemoryApi>((ref) {
  return MockMemoryApi();
});

/// Provider for Real Memory API
final realMemoryApiProvider = Provider<MemoryApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return MemoryApi(apiClient: apiClient);
});

/// Provider for Memory API (mock or real based on toggle)
final memoryApiProvider = Provider<IMemoryApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return ref.watch(mockMemoryApiProvider);
  }
  return ref.watch(realMemoryApiProvider);
});

// ============ Memory Twin API (PROD-1617 / PROD-1914) ============

final mockMemoryTwinApiProvider = Provider<MockMemoryTwinApi>((ref) {
  return MockMemoryTwinApi();
});

final realMemoryTwinApiProvider = Provider<MemoryTwinApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return MemoryTwinApi(apiClient: apiClient);
});

final memoryTwinApiProvider = Provider<IMemoryTwinApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return ref.watch(mockMemoryTwinApiProvider);
  }
  return ref.watch(realMemoryTwinApiProvider);
});

// ============ Location API ============

/// Provider for Mock Location API
final mockLocationApiProvider = Provider<MockLocationApi>((ref) {
  return MockLocationApi();
});

/// Provider for Real Location API
final realLocationApiProvider = Provider<LocationApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return LocationApi(apiClient: apiClient);
});

/// Provider for Location API (mock or real based on toggle)
final locationApiProvider = Provider<ILocationApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return ref.watch(mockLocationApiProvider);
  }
  return ref.watch(realLocationApiProvider);
});

// ============ Account API ============

/// Provider for Mock Account API
final mockAccountApiProvider = Provider<MockAccountApi>((ref) {
  return MockAccountApi();
});

/// Provider for Real Account API
final realAccountApiProvider = Provider<AccountApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return AccountApi(apiClient: apiClient);
});

/// Provider for Account API (mock or real based on toggle)
final accountApiProvider = Provider<IAccountApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return ref.watch(mockAccountApiProvider);
  }
  return ref.watch(realAccountApiProvider);
});

// ============ Preferences API ============

final preferencesApiProvider = Provider<IPreferencesApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return PreferencesApi(apiClient: apiClient);
});

// ============ Auth Methods API ============

/// Provider for Real Auth Methods API
final realAuthMethodsApiProvider = Provider<AuthMethodsApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return AuthMethodsApi(apiClient: apiClient);
});

/// Provider for Auth Methods API (always uses real API)
final authMethodsApiProvider = Provider<IAuthMethodsApi>((ref) {
  return ref.watch(realAuthMethodsApiProvider);
});

// ============ Locales API ============

/// Provider for Real Locales API
final realLocalesApiProvider = Provider<LocalesApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return LocalesApi(apiClient: apiClient);
});

/// Provider for Locales API (always uses real API - public endpoint)
final localesApiProvider = Provider<ILocalesApi>((ref) {
  return ref.watch(realLocalesApiProvider);
});

// ============ WhatsApp API ============

/// Provider for Real WhatsApp API
final realWhatsAppApiProvider = Provider<WhatsAppApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return WhatsAppApi(apiClient: apiClient);
});

/// Provider for WhatsApp API (always uses real API - public endpoint)
final whatsAppApiProvider = Provider<IWhatsAppApi>((ref) {
  return ref.watch(realWhatsAppApiProvider);
});

// ============ Instagram API ============

/// Provider for Real Instagram API
final realInstagramApiProvider = Provider<InstagramApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return InstagramApi(apiClient: apiClient);
});

/// Provider for Instagram API
final instagramApiProvider = Provider<IInstagramApi>((ref) {
  return ref.watch(realInstagramApiProvider);
});

// ============ Referrals API ============

/// Provider for Real Referrals API
final realReferralsApiProvider = Provider<ReferralsApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return ReferralsApi(apiClient: apiClient);
});

/// Provider for Referrals API (always uses real API - public endpoint)
final referralsApiProvider = Provider<IReferralsApi>((ref) {
  return ref.watch(realReferralsApiProvider);
});

// ============ Search API ============

/// Provider for Search API (places and events search)
final searchApiProvider = Provider<SearchApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SearchApi(apiClient: apiClient);
});

// ============ Map API ============

/// Provider for Map API (maps v0: /map/pins + /map/hydrate).
final mapApiProvider = Provider<MapApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return MapApi(apiClient: apiClient);
});

// ============ Geo API ============

/// Provider for Geo API (areas autocomplete for location scope picker)
final geoApiProvider = Provider<GeoApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return GeoApi(apiClient: apiClient);
});

// ============ Map Search History API ============

/// Provider for the v2 map search bar's past-searches history
/// (PROD-3495/PROD-3499).
final mapSearchHistoryApiProvider = Provider<MapSearchHistoryApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return MapSearchHistoryApi(apiClient: apiClient);
});

// ============ Feed API ============

/// Provider for Discovery feed API (Near-You, future Em destaque / Espaços).
final feedApiProvider = Provider<IFeedApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return FeedApi(apiClient: apiClient);
});

// ============ Daily Drop API ============

/// Provider for Daily Drop (recommendations) API
final dailyDropApiProvider = Provider<DailyDropApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return DailyDropApi(apiClient: apiClient);
});

/// Provider for Weekly Bundle (recommendations) API
final weeklyBundleApiProvider = Provider<WeeklyBundleApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return WeeklyBundleApi(apiClient: apiClient);
});

/// Provider for User Activity API (Discovery History grid, PROD-1521)
final userActivityApiProvider = Provider<UserActivityApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return UserActivityApi(apiClient: apiClient);
});

// ============ App Feedback API (PROD-2900) ============

/// Provider for App-wide Feedback API (mock or real based on toggle)
final appFeedbackApiProvider = Provider<IAppFeedbackApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) {
    return MockAppFeedbackApi();
  }
  final apiClient = ref.watch(apiClientProvider);
  return AppFeedbackApi(apiClient: apiClient);
});

// ============ Detail API ============

/// Provider for Detail API (event/venue detail with social proof)
final detailApiProvider = Provider<DetailApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return DetailApi(apiClient: apiClient);
});

/// Provider for Signal API (entity relationship signals, PROD-2930)
final signalApiProvider = Provider<SignalApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SignalApi(apiClient: apiClient);
});

// ============ Analytics Events API ============

/// Provider for Analytics Events API (backend analytics tracking)
final analyticsEventsApiProvider = Provider<AnalyticsEventsApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return AnalyticsEventsApi(apiClient: apiClient);
});

// ============ Feed Impressions (seen-suppression) ============

/// Fire-and-forget client for POST /feed/impressions.
final feedImpressionsApiProvider = Provider<FeedImpressionsApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return FeedImpressionsApi(apiClient: apiClient);
});

/// Long-lived batching sender for viewport impressions. Registers an app
/// lifecycle observer, so it must outlive the shelves that feed it.
final feedImpressionSenderProvider = Provider<FeedImpressionSender>((ref) {
  final sender = FeedImpressionSender(ref.watch(feedImpressionsApiProvider));
  ref.onDispose(sender.dispose);
  ref.keepAlive();
  return sender;
});

// ============ Discovery engagement (PROD-4257) ============

/// Fire-and-forget client for POST /app/discovery/engagement.
final discoveryEngagementApiProvider = Provider<DiscoveryEngagementApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return DiscoveryEngagementApi(apiClient: apiClient);
});

/// Long-lived batching sender for discovery-session engagement. Registers an
/// app lifecycle observer, so it must outlive the feed that feeds it. Resolves
/// the anonymous visitor id at flush time.
final discoveryEngagementSenderProvider = Provider<DiscoveryEngagementSender>((
  ref,
) {
  final sender = DiscoveryEngagementSender(
    // Lazy: resolved at flush, so building the sender (and the session tracker
    // that owns it, read from feed card widgets) touches no api-client chain.
    () => ref.read(discoveryEngagementApiProvider),
    visitorId: () => ref.read(attributionServiceProvider).cachedVisitorId,
  );
  ref.onDispose(sender.dispose);
  ref.keepAlive();
  return sender;
});

/// The discovery-session tracker — one feed visit's engagement, keyed by a
/// client-minted `session_id`. Long-lived (observes app lifecycle) and shared
/// across the feed's blocks; the discovery screen drives its start/end.
final discoverySessionTrackerProvider = Provider<DiscoverySessionTracker>((
  ref,
) {
  final tracker = DiscoverySessionTracker(
    ref.watch(discoveryEngagementSenderProvider),
  );
  // Before a session closes, resolve every open exposure episode INTO it —
  // the card detectors' zero-visibility callbacks arrive after the session
  // wrapper's in the same sweep and would otherwise be dropped (PROD-4306).
  tracker.beforeClose = ImpressionDetector.resolveAllOpenEpisodes;
  // PROD-4532 — stamp the filter on screen as each visit OPENS, so per-filter
  // dwell (the gap between consecutive `context_changed` beats) has something
  // to measure the first segment from. `.wire`, not `.name`: they agree for all
  // four filters today, and `.wire` is the value the contract and
  // `feed_slate_advance` already use, so a future rename cannot split them.
  //
  // Wired here rather than at the screen because `_open()` has three entry
  // points — a surface acquire, a foreground resume, and an identity change —
  // and only the first goes through a widget's `initState`.
  tracker.onOpen = () => ref.read(feedFilterProvider).wire;
  // Identity-epoch boundary (PROD-4308): a sign-out or account switch drops
  // the buffered events AND abandons the live session state without emitting
  // — nothing observed under the old actor may post under the new token, and
  // the old session id must not leak into the new actor's visit.
  ref.listen(authStateProvider.select((s) => s.user?.id), (prev, next) {
    if (prev != next) tracker.handleIdentityChange();
  });
  ref.onDispose(tracker.dispose);
  ref.keepAlive();
  return tracker;
});

// ============ Instagram Share API ============

/// Provider for Instagram Share API (share extension endpoints)
final instagramShareApiProvider = Provider<InstagramShareApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return InstagramShareApi(apiClient: apiClient);
});

// ============ Contributions API ============

/// Provider for the photo→event contribution API (PROD-2404).
/// Endpoints: `POST/GET /api/v1/app/contributions/events`.
final contributionsApiProvider = Provider<ContributionsApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return ContributionsApi(apiClient: apiClient);
});

// ============ Shares API (PROD-2785) ============

/// Provider for the channel-aware share-asset API (PROD-2785 / PROD-2784).
/// Hits `GET /api/v1/app/shares/{context}/{subject_id}/channels/{channel}`
/// and returns the canonical backend-rendered card.
final sharesApiProvider = Provider<SharesApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return DioSharesApi(apiClient: apiClient);
});

// ============ Onboarding API ============

/// Provider for Real Onboarding API
final realUserProfilingApiProvider = Provider<UserProfilingApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return UserProfilingApi(apiClient: apiClient);
});

/// Provider for Onboarding API.
///
/// Always uses the real backend. Onboarding completion is server-gated via
/// `/auth/me.onboarding_complete`, so a client-only submit can leave the app
/// stuck in the onboarding gate even when the UI appears to finish.
final userProfilingApiProvider = Provider<IUserProfilingApi>((ref) {
  return ref.watch(realUserProfilingApiProvider);
});

/// Resumable chat-onboarding state API (PROD-3882 / BE-1) —
/// `GET`/`PUT /api/v1/app/onboarding/state`. Always the real backend; the
/// backend is the source of truth for onboarding progress.
final onboardingStateApiProvider = Provider<IOnboardingStateApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return OnboardingStateApi(apiClient: apiClient);
});

// ============ EULA API (PROD-2264) ============

final mockEulaApiProvider = Provider<MockEulaApi>((ref) => MockEulaApi());

final realEulaApiProvider = Provider<EulaApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return EulaApi(apiClient: apiClient);
});

final eulaApiProvider = Provider<IEulaApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) return ref.watch(mockEulaApiProvider);
  return ref.watch(realEulaApiProvider);
});

// ============ Feature Spotlights API (PROD-2808) ============

final mockFeatureSpotlightsApiProvider = Provider<MockFeatureSpotlightsApi>(
  (ref) => MockFeatureSpotlightsApi(),
);

final realFeatureSpotlightsApiProvider = Provider<FeatureSpotlightsApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return FeatureSpotlightsApi(apiClient: apiClient);
});

final featureSpotlightsApiProvider = Provider<IFeatureSpotlightsApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) return ref.watch(mockFeatureSpotlightsApiProvider);
  return ref.watch(realFeatureSpotlightsApiProvider);
});

// ============ Moderation API (PROD-2264) ============

final mockModerationApiProvider = Provider<MockModerationApi>(
  (ref) => MockModerationApi(),
);

final realModerationApiProvider = Provider<ModerationApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return ModerationApi(apiClient: apiClient);
});

final moderationApiProvider = Provider<IModerationApi>((ref) {
  final useMock = ref.watch(useMockApiProvider);
  if (useMock) return ref.watch(mockModerationApiProvider);
  return ref.watch(realModerationApiProvider);
});

// ============ Notifications inbox API (PROD-2524 T-E) ============

/// Provider for the in-app notifications inbox API (PROD-2514 T-C backend).
/// Endpoints: list / unread-count / mark-read / read-all / dismiss /
/// per-category preferences.
final notificationsApiProvider = Provider<NotificationsApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return NotificationsApi(apiClient: apiClient);
});

// ============ Event reminders API (PROD-2525 T-K3) ============

/// Provider for the per-event reminder subscriptions API (PROD-2516 T-K1).
/// Endpoints: list-by-event / create / delete / list-upcoming.
final eventRemindersApiProvider = Provider<EventRemindersApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return EventRemindersApi(apiClient: apiClient);
});

// ============ Social profile (admin-gated pilot) ============

/// By-handle public profile + its sections (PROD-2775/2815/2816/2819/2822).
final socialProfileApiProvider = Provider<SocialProfileApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SocialProfileApi(apiClient: apiClient);
});

/// User→user follow graph + private-account request flow (PROD-2776/2819).
final followsApiProvider = Provider<FollowsApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return FollowsApi(apiClient: apiClient);
});

/// People discovery — search + suggestions (PROD-2777/2821).
final peopleApiProvider = Provider<PeopleApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return PeopleApi(apiClient: apiClient);
});

// ============ Fake-door campaigns API ============

/// Client for `GET /campaigns/active`, `GET /campaigns/{key}`, and
/// `POST /campaigns/{key}/responses`. Always uses the real backend — there
/// is no client-side campaign catalog to mock against.
final campaignApiProvider = Provider<ICampaignApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return CampaignApi(apiClient: apiClient);
});
