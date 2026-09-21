/// API constants for HeyL app
class ApiConstants {
  ApiConstants._();

  /// This interview repository always uses backend-staging. Build flags cannot
  /// accidentally switch this copy to backend-prod.
  static const String stagingBaseUrl =
      'https://heyl-backend-staging.onrender.com';
  static const String prodBaseUrl = stagingBaseUrl;
  static const String devBaseUrl = stagingBaseUrl;

  /// Share links stay on the candidate's local interview app.
  static const String webappUrl = 'http://localhost:3001';

  /// Generic "download the app" install link (PROD-2298). The bridge at
  /// `soko.fyi/get` deep-links into the native app if installed (soko-website's
  /// AASA claims `/get`), otherwise falls through to the App Store / Play Store.
  /// Shared when inviting non-Soko contacts.
  static const String appInstallUrl = 'https://soko.fyi/get';

  /// Build date (set at compile time via --dart-define=BUILD_DATE=...)
  /// Used to display release info to admin users
  static const String buildDate = String.fromEnvironment(
    'BUILD_DATE',
    defaultValue: '',
  );

  // ---------------------------------------------------------------------------
  // Discovery chat typeahead — relevance-score gating (PROD-1909)
  // ---------------------------------------------------------------------------
  // Float thresholds applied client-side against `relevance_score` (0–1)
  // returned by Meilisearch-backed `events.search` / `places.search`. Tunable
  // via --dart-define so we can adjust strictness without a deploy. Set to
  // `0.0` to disable filtering in QA/debug builds.
  //
  // Dart only supports `String|int|bool.fromEnvironment` for compile-time
  // constants, so the float thresholds are stored as raw strings and parsed
  // once at class load. Malformed values silently fall back to the default.

  // Defaults tuned to favour "almost exact match" on short queries (where
  // partial typos would otherwise surface low-quality matches) and a still-
  // strict floor on longer queries.
  static const String _typeaheadMinScoreShortQueryRaw = String.fromEnvironment(
    'TYPEAHEAD_MIN_SCORE_SHORT_QUERY',
    defaultValue: '0.9',
  );
  static const String _typeaheadMinScoreLongQueryRaw = String.fromEnvironment(
    'TYPEAHEAD_MIN_SCORE_LONG_QUERY',
    defaultValue: '0.8',
  );

  /// Min `relevance_score` for queries shorter than [typeaheadShortQueryThreshold].
  static final double typeaheadMinScoreShortQuery =
      double.tryParse(_typeaheadMinScoreShortQueryRaw) ?? 0.9;

  /// Min `relevance_score` for queries at or above [typeaheadShortQueryThreshold].
  static final double typeaheadMinScoreLongQuery =
      double.tryParse(_typeaheadMinScoreLongQueryRaw) ?? 0.8;

  /// Query-length cutoff between the short- and long-query thresholds.
  static const int typeaheadShortQueryThreshold = int.fromEnvironment(
    'TYPEAHEAD_SHORT_QUERY_THRESHOLD',
    defaultValue: 4,
  );

  /// Max rows rendered per typeahead tab (and per "All" tab total). Caps
  /// the visual list so the user doesn't scroll through long tails of
  /// low-relevance matches even when the backend returns more.
  static const int typeaheadMaxResults = int.fromEnvironment(
    'TYPEAHEAD_MAX_RESULTS',
    defaultValue: 7,
  );

  /// Max zines (lists) ever rendered — applies to the Zines tab AND
  /// caps the zines section inside "All". Tighter than [typeaheadMaxResults]
  /// because zines have no relevance score, so the tail is noisier.
  static const int typeaheadMaxZines = int.fromEnvironment(
    'TYPEAHEAD_MAX_ZINES',
    defaultValue: 4,
  );

  /// API version prefix
  static const String apiPrefix = '/api/v1';

  // Auth endpoints - Phone OTP
  static const String authPhoneStart = '$apiPrefix/auth/phone/start';
  static const String authPhoneVerify = '$apiPrefix/auth/phone/verify';
  static const String authMe = '$apiPrefix/auth/me';
  static const String authLogout = '$apiPrefix/auth/logout';
  static const String authGoogleLogin = '$apiPrefix/auth/google/login';

  // Auth endpoints - Email/Password
  static const String authRegister = '$apiPrefix/auth/register';
  static const String authLogin = '$apiPrefix/auth/login';
  static const String authActivate = '$apiPrefix/auth/activate';
  static const String authResendActivation =
      '$apiPrefix/auth/resend-activation';
  static const String authForgotPassword = '$apiPrefix/auth/forgot-password';
  static const String authResetPassword = '$apiPrefix/auth/reset-password';

  // Auth endpoints - PROD-3595 passwordless email-OTP login (email fallback
  // rung of the phone-login channel ladder; distinct from the authenticated
  // add-email flow under /app/users/me/auth/email/*).
  static const String authEmailLoginStart = '$apiPrefix/auth/email/login/start';
  static const String authEmailLoginVerify =
      '$apiPrefix/auth/email/login/verify';

  // Auth endpoints - OAuth
  static const String authAppleToken = '$apiPrefix/auth/apple/token';
  static const String authGoogleToken = '$apiPrefix/auth/google/token';

  // Auth endpoints - PROD-1979 guest sessions (stateless 24h JWT)
  static const String authGuest = '$apiPrefix/auth/guest';

  // Sessions endpoints
  static const String sessions = '$apiPrefix/app/sessions';
  static String session(String sessionId) =>
      '$apiPrefix/app/sessions/$sessionId';
  static String sessionSearchCenter(String sessionId) =>
      '${session(sessionId)}/search-center';

  // Messages endpoints
  static const String messageStarters =
      '$apiPrefix/app/users/me/message-starters';
  static String messages(String sessionId) =>
      '$apiPrefix/app/sessions/$sessionId/messages';
  static String imageMessage(String sessionId) =>
      '$apiPrefix/app/sessions/$sessionId/messages:image';
  static String voiceMessage(String sessionId) =>
      '$apiPrefix/app/sessions/$sessionId/messages:voice';
  static String messageStream(String sessionId, String messageId) =>
      '$apiPrefix/app/sessions/$sessionId/messages/$messageId/stream';

  // Timeouts for streaming
  static const Duration streamTimeout = Duration(minutes: 5);

  // Location endpoints
  static const String myLocation = '$apiPrefix/app/users/me/location';
  static String myLocationTagged(String tag) =>
      '$apiPrefix/app/users/me/location/tagged/$tag';
  static const String locationShareLink = '$apiPrefix/app/location/share-link';

  // Events & Venues endpoints
  static const String events = '$apiPrefix/events';
  static String event(String eventId) => '$apiPrefix/events/$eventId';
  static const String venues = '$apiPrefix/venues';
  static const String venuesResolveUrl = '$apiPrefix/app/places/resolve-url';
  // PROD-4380: resolve a chat place card's google_place_id to a venue.
  static const String venuesResolvePlaceId =
      '$apiPrefix/app/places/resolve-place-id';

  // Business ownership (PROD-3709). These routes are server-gated and return
  // 404 while BUSINESS_OWNERSHIP_ENABLED is off.
  static String venueClaimState(String venueId) =>
      '$apiPrefix/app/venues/$venueId/claim';
  static String venueClaimInstagram(String venueId) =>
      '$apiPrefix/app/venues/$venueId/claim/instagram';
  static String confirmPendingVenueClaim(String pendingKey) =>
      '$apiPrefix/app/claim/pending/$pendingKey/confirm';
  static const String myBusinesses = '$apiPrefix/app/me/businesses';
  static const String myClaims = '$apiPrefix/app/me/claims';
  static String ownerVenue(String venueId) =>
      '$apiPrefix/app/owner/venues/$venueId';
  static String ownerVenuePhoto(String venueId) =>
      '$apiPrefix/app/owner/venues/$venueId/photo';

  // Business Connect portal (PROD-4039 / PROD-4040). Also server-gated on
  // BUSINESS_OWNERSHIP_ENABLED (404 when off).
  static const String businessVenuesSearch =
      '$apiPrefix/app/business/venues/search';
  // Transient Google name search (PROD-4269 S4). Writes nothing; candidates
  // carry a canonical venue_id/claim_status only when an active venue already
  // holds that place id, otherwise the owner resolves the place id first.
  static const String businessVenuesSearchGoogle =
      '$apiPrefix/app/business/venues/search/google';
  static const String businessVenuesResolve =
      '$apiPrefix/app/business/venues/resolve';
  static String ownerVenueImages(String venueId) =>
      '$apiPrefix/app/owner/venues/$venueId/images';
  static String ownerVenueImage(String venueId, String imageId) =>
      '$apiPrefix/app/owner/venues/$venueId/images/$imageId';
  static String ownerVenueImagesOrder(String venueId) =>
      '$apiPrefix/app/owner/venues/$venueId/images/order';

  // EULA endpoints (PROD-2264)
  static const String eulaAccept = '$apiPrefix/app/eula/accept';
  static const String eulaMe = '$apiPrefix/app/eula/me';

  // Moderation endpoints (PROD-2264)
  static const String moderationReports = '$apiPrefix/app/reports';
  static const String moderationBlocks = '$apiPrefix/app/blocks';
  static String moderationBlock(String blockId) =>
      '$apiPrefix/app/blocks/$blockId';

  // App-wide feedback endpoint (PROD-2900)
  static const String appFeedback = '$apiPrefix/app/app-feedback';

  // Saved & Feedback endpoints
  static const String mySaved = '$apiPrefix/app/users/me/saved';
  static String mySavedItem(String savedId) =>
      '$apiPrefix/app/users/me/saved/$savedId';

  /// Merged library feed (PROD-4103).
  static const String myLibrary = '$apiPrefix/app/users/me/library';
  static String myLibraryPin(String type, String id) =>
      '$apiPrefix/app/users/me/library/$type/$id/pin';

  /// Bulk saved-entity-ids endpoint (`getSavedEntityIds`, PROD-2844) — returns
  /// the caller's deduped saved event/venue/google-place ids in one request,
  /// replacing the per-list `GET /lists/{id}/items` fan-out.
  static const String savedEntityIds =
      '$apiPrefix/app/users/me/saved/entity-ids';

  // Lists endpoints
  static const String myLists = '$apiPrefix/app/users/me/lists';
  static const String myListsMapPins = '$apiPrefix/app/users/me/lists/map-pins';
  static const String myListsCalendarEvents =
      '$apiPrefix/app/users/me/lists/calendar-events';
  static const String myListsSavedItemsSearch =
      '$apiPrefix/app/users/me/lists/saved-items';
  static const String myDefaultList = '$apiPrefix/app/users/me/lists/default';
  static String list(String listId) => '$apiPrefix/app/lists/$listId';
  static String listCoverUpload(String listId) =>
      '$apiPrefix/app/lists/$listId/cover/upload';
  // PROD-3217 — upload the app-rendered zine-cover PNG the IG-Story share
  // card composites. Owner-only. Distinct from cover/upload (which sets the
  // uploaded-photo cover); this is a derived render and never changes
  // cover_type.
  static String listCoverShareRender(String listId) =>
      '$apiPrefix/app/lists/$listId/cover/share-render';
  static String listItems(String listId) =>
      '$apiPrefix/app/lists/$listId/items';
  // Quicksave — save with no list picker; server resolves the caller's
  // Saved Items list and returns its id on the item (PROD-3873).
  static const String defaultListItems = '$apiPrefix/app/lists/items';
  static String listItemsSlim(String listId) =>
      '$apiPrefix/app/lists/$listId/items/slim';
  static String listItem(String listId, String itemId) =>
      '$apiPrefix/app/lists/$listId/items/$itemId';
  static String listItemsReorder(String listId) =>
      '$apiPrefix/app/lists/$listId/items/reorder';
  static String listItemsBulkDelete(String listId) =>
      '$apiPrefix/app/lists/$listId/items/bulk-delete';

  // List suggestions endpoint
  static String listSuggestionsGenerate(String listId) =>
      '$apiPrefix/app/lists/$listId/suggestions/generate';

  // Public list endpoints (no auth required)
  static String publicList(String listId) =>
      '$apiPrefix/app/lists/$listId/public';
  static String publicListItems(String listId) =>
      '$apiPrefix/app/lists/$listId/public/items';
  static String publicListItemsSlim(String listId) =>
      '$apiPrefix/app/lists/$listId/public/items/slim';

  // List follow endpoints
  static String listFollow(String listId) =>
      '$apiPrefix/app/lists/$listId/follow';
  static String listFollowers(String listId) =>
      '$apiPrefix/app/lists/$listId/followers';
  static const String myFollowedLists =
      '$apiPrefix/app/users/me/lists/following';

  // User profiling (V6 questionnaire)
  static const String userProfilingQuestions =
      '$apiPrefix/app/user_profiling/questions';
  static const String userProfilingSubmit =
      '$apiPrefix/app/user_profiling/submit';

  // Chat onboarding — resumable state persistence (PROD-3882 / BE-1).
  // GET reads the durable state; PUT upserts idempotently per (user, step).
  static const String onboardingState = '$apiPrefix/app/onboarding/state';

  // Admin/QA replay: clears state + flips onboarding_complete back to false so
  // the real gated flow can be re-run from the top.
  static const String onboardingReset = '$apiPrefix/app/onboarding/reset';

  // Chat onboarding — bulk-hydrate previously saved/thumbed onboarding entities
  // so a returning user resumes the SAME cards (vibe carousels + search picks)
  // with their 👍/👎. POST {items:[{type,id}]} → cards + the caller's sentiment;
  // the card payloads share the discovery/saved-item shape the app already parses.
  static const String onboardingEntitiesHydrate =
      '$apiPrefix/app/onboarding/entities/hydrate';

  // Chat onboarding — preliminary "zines" step (PROD-3883 / BE-2). GET generates
  // a hidden, NOT auto-saved zine for the user's city; POST .../{id}/save copies
  // it into a new owned list.
  static const String onboardingPreliminaryZines =
      '$apiPrefix/app/onboarding/preliminary-zines';
  static String onboardingPreliminaryZineSave(String listId) =>
      '$apiPrefix/app/onboarding/preliminary-zines/$listId/save';

  // Public lists discovery endpoint
  static const String publicLists = '$apiPrefix/app/lists/public';

  // Public lists by user handle (Discovery: Recomendado shelf, PROD-1516)
  static String publicListsByHandle(String handle) =>
      '$apiPrefix/app/users/by-handle/${Uri.encodeComponent(handle)}/lists/public';

  // Discover (all sections) + curated endpoints
  static const String discoverLists = '$apiPrefix/app/lists/discover';
  static const String curatedLists = '$apiPrefix/app/lists/curated';

  // Near-You discovery feed split into events + places shelves (PROD-1963).
  static const String nearYouEventsFeed = '$apiPrefix/app/feed/near-you/events';
  static const String nearYouPlacesFeed = '$apiPrefix/app/feed/near-you/places';
  // Server-driven Discovery feed (PROD-4005, umbrella PROD-3998). One call
  // whose blocks, item counts and order are all backend decisions — replaces
  // the client-ordered stack of ~12 shelves.
  static const String homeFeed = '$apiPrefix/app/feed/home';
  // Client viewport impressions → seen-suppression store (PROD feed-seen).
  static const String feedImpressions = '$apiPrefix/app/feed/impressions';

  // Em destaque (highlighted) discovery feed (PROD-1554)
  static const String highlightedFeed = '$apiPrefix/app/feed/highlighted';

  // Espaços (venues with events) discovery feed (PROD-1553)
  static const String venuesWithEventsFeed =
      '$apiPrefix/app/feed/venues-with-events';

  // Suggested lists endpoint
  static const String suggestedLists = '$apiPrefix/app/lists/suggested';
  static const String guestSuggestedLists =
      '$apiPrefix/app/lists/suggested/guest';

  // Import endpoints
  static const String importGoogleMapsAsync =
      '$apiPrefix/app/lists/import/google-maps/async';
  static String importJobStatus(String jobId) =>
      '$apiPrefix/app/lists/import/$jobId/status';

  // Notifications inbox (PROD-2514 T-C backend / PROD-2524 T-E FE)
  static const String notifications = '$apiPrefix/app/notifications';
  static const String notificationsUnreadCount =
      '$apiPrefix/app/notifications/unread-count';
  static const String notificationsReadAll =
      '$apiPrefix/app/notifications/read-all';
  static const String notificationsPreferences =
      '$apiPrefix/app/notifications/preferences';
  static String notificationRead(String id) =>
      '$apiPrefix/app/notifications/$id/read';
  static String notificationDismiss(String id) =>
      '$apiPrefix/app/notifications/$id/dismiss';
  static String notificationBundleRead(String bundleKey) =>
      '$apiPrefix/app/notifications/bundles/${Uri.encodeComponent(bundleKey)}/read';

  // Event reminders (PROD-2516 T-K1 + PROD-2517 T-K2 backend / PROD-2525 T-K3 FE)
  static String eventReminders(String eventId) =>
      '$apiPrefix/app/events/$eventId/reminders';
  static String eventReminderById(String reminderId) =>
      '$apiPrefix/app/event-reminders/$reminderId';
  static const String myEventReminders =
      '$apiPrefix/app/users/me/event-reminders';
  static const String myEventsWithReminders =
      '$apiPrefix/app/users/me/events-with-reminders';

  // Profile & Memory endpoints
  static const String myProfile = '$apiPrefix/app/users/me/profile';
  static const String myPreferences = '$apiPrefix/app/users/me/preferences';
  // Discovery — recent user activity (PROD-1514, drives History grid PROD-1521)
  static const String myActivity = '$apiPrefix/app/users/me/activity';
  static const String myWhatsappPreference =
      '$apiPrefix/app/users/me/whatsapp-preference';
  static String handleAvailable(String handle) =>
      '$apiPrefix/app/users/me/handle-available/$handle';
  static const String myAvatarUpload = '$apiPrefix/app/users/me/avatar/upload';
  // DELETE — remove the current user's avatar (PROD-2814).
  static const String myAvatar = '$apiPrefix/app/users/me/avatar';

  // ---- Social profile (admin-gated pilot) --------------------------------
  // By-handle public profile + its sections.
  static String profileByHandle(String handle) =>
      '$apiPrefix/app/users/by-handle/$handle';
  static String profileActivityByHandle(String handle) =>
      '$apiPrefix/app/users/by-handle/$handle/activity';
  static String profileSocialProofByHandle(String handle) =>
      '$apiPrefix/app/users/by-handle/$handle/social-proof';
  static String profileZinesByHandle(String handle) =>
      '$apiPrefix/app/users/by-handle/$handle/zines';
  static String profileTastesByHandle(String handle) =>
      '$apiPrefix/app/users/by-handle/$handle/tastes';
  static String profileSavedByHandle(String handle) =>
      '$apiPrefix/app/users/by-handle/$handle/saved';
  static String profileSavedZinesByHandle(String handle) =>
      '$apiPrefix/app/users/by-handle/$handle/saved-zines';
  static String profileFollowCountsByHandle(String handle) =>
      '$apiPrefix/app/users/by-handle/$handle/follow-counts';
  static String profileFollowersByHandle(String handle) =>
      '$apiPrefix/app/users/by-handle/$handle/followers';
  static String profileFollowingByHandle(String handle) =>
      '$apiPrefix/app/users/by-handle/$handle/following';
  static String profileMutualFollowersByHandle(String handle) =>
      '$apiPrefix/app/users/by-handle/$handle/mutual-followers';

  // Follow graph (user -> user).
  static String followUser(String userId) =>
      '$apiPrefix/app/users/$userId/follow';
  static const String myFollowers = '$apiPrefix/app/users/me/followers';
  static String removeFollower(String followerUserId) =>
      '$apiPrefix/app/users/me/followers/$followerUserId';
  static const String contactsMatch = '$apiPrefix/app/users/contacts/match';
  static const String myFollowRequests =
      '$apiPrefix/app/users/me/follow-requests';
  static String acceptFollowRequest(String followerUserId) =>
      '$apiPrefix/app/users/me/follow-requests/$followerUserId/accept';
  static String rejectFollowRequest(String followerUserId) =>
      '$apiPrefix/app/users/me/follow-requests/$followerUserId/reject';

  // People discovery.
  static const String userSearch = '$apiPrefix/app/users/search';
  static const String suggestedUsers = '$apiPrefix/app/users/suggested';
  static const String myMemory = '$apiPrefix/app/users/me/memory';
  static const String myMemoryIngest = '$apiPrefix/app/users/me/memory:ingest';
  static const String myMemoryItems = '$apiPrefix/app/users/me/memory/items';
  static const String myMemoryExport = '$apiPrefix/app/users/me/memory/export';

  // Twin-shaped memory endpoints (PROD-1617 / PROD-1914)
  // GET /me/memory now returns MemoryTwinResponse; the legacy `myMemory`
  // constant above is reused at the path level. The four delete granularities
  // and the clear-all gate live below.
  static const String myMemoryClear = '$apiPrefix/app/users/me/memory';
  static const String myMemoryFactById =
      '$apiPrefix/app/users/me/memory/facts/{fact_id}';
  static const String myMemoryObservationById =
      '$apiPrefix/app/users/me/memory/facts/observations/{observation_id}';
  static const String myMemoryDimensionByName =
      '$apiPrefix/app/users/me/memory/facts/dimensions/{dimension_name}';
  static const String myMemoryChipSuppress =
      '$apiPrefix/app/users/me/memory/facts/chips/suppress';
  static const String myMemoryChipNudge =
      '$apiPrefix/app/users/me/memory/facts/chips/nudge';
  // "Conta-nos sobre ti": free-text self-description → memory facts (Phase 5).
  static const String myMemoryTellUs = '$apiPrefix/app/users/me/memory/tell-us';
  // Memory-bio ownership (PATCH hide/unhide; POST accept a pending version).
  static const String myMemoryBio = '$apiPrefix/app/users/me/memory-bio';
  static const String myMemoryBioAccept =
      '$apiPrefix/app/users/me/memory-bio/accept';
  static const String myMemoryBioReject =
      '$apiPrefix/app/users/me/memory-bio/reject';

  // Account endpoints
  static const String account = '$apiPrefix/app/account';
  static const String support = '$apiPrefix/app/support';

  // Locales endpoint (public, no auth required)
  static const String locales = '$apiPrefix/app/locales';

  // WhatsApp numbers endpoint (public, no auth required)
  static const String whatsappNumbers = '$apiPrefix/app/whatsapp/numbers';

  // Instagram endpoints
  static const String instagramConnect = '$apiPrefix/instagram/connect';
  static const String instagramConnections = '$apiPrefix/instagram/connections';
  static String instagramConnection(String connectionId) =>
      '$apiPrefix/instagram/connections/$connectionId';
  static String instagramPendingConnection(String key) =>
      '$apiPrefix/instagram/pending-connection/$key';
  static String instagramPendingConnectionConfirm(String key) =>
      '$apiPrefix/instagram/pending-connection/$key/confirm';

  // Instagram share extension endpoints (PROD-1466 / PROD-1572)
  static const String instagramShare = '$apiPrefix/app/instagram/share';
  static const String instagramShares = '$apiPrefix/app/instagram/shares';
  static String instagramShareById(String sharedPostId) =>
      '$instagramShares/$sharedPostId';

  // Event contributions — photo→event ingest (PROD-2147 backend, PROD-2404 FE)
  static const String contributionEvents =
      '$apiPrefix/app/contributions/events';
  static String contributionEventById(String contributionId) =>
      '$contributionEvents/$contributionId';

  // Auth Methods endpoints (add/remove phone/email)
  static const String myAuthMethods = '$apiPrefix/app/users/me/auth-methods';
  static String myAuthMethod(String methodId) =>
      '$apiPrefix/app/users/me/auth-methods/$methodId';
  static const String myAuthPhoneStart =
      '$apiPrefix/app/users/me/auth/phone/start';
  static const String myAuthPhoneVerify =
      '$apiPrefix/app/users/me/auth/phone/verify';
  static const String myAuthEmailStart =
      '$apiPrefix/app/users/me/auth/email/start';
  static const String myAuthEmailVerify =
      '$apiPrefix/app/users/me/auth/email/verify';
  static const String myAuthMerge = '$apiPrefix/app/users/me/auth/merge';

  // Referral endpoints (public, no auth required)
  static String pendingSearch(String slug) =>
      '$apiPrefix/referrals/pending-search/$slug';

  // Detail endpoints (social proof + upcoming events)
  static String eventDetail(String eventId) => '$apiPrefix/app/events/$eventId';

  /// Paginated full list of an event's sharers (PROD-3161), backing the
  /// "and N others" popup. Query: `limit` (1-100, default 20) + `offset`.
  static String eventSharedBy(String eventId) =>
      '$apiPrefix/app/events/$eventId/shared-by';
  static String venueDetail(String venueId) => '$apiPrefix/app/places/$venueId';
  static String venueEvents(String venueId) =>
      '$apiPrefix/app/places/$venueId/events';

  /// Paginated list of everyone who liked an entity (PROD-3779), backing the
  /// "Liked by" row's popup. Same query shape as [eventSharedBy].
  ///
  /// Note the nouns: these sit beside their DETAIL siblings, so a venue is
  /// `places` here — unlike the signal write routes below, which use `venues`.
  static String eventLikedBy(String eventId) =>
      '$apiPrefix/app/events/$eventId/liked-by';
  static String venueLikedBy(String venueId) =>
      '$apiPrefix/app/places/$venueId/liked-by';

  /// The merged "… têm interesse" roster — everyone who liked OR
  /// saved the entity, deduped server-side, backing the row's popup. Same
  /// query shape and the same `places`/`events` nouns as [eventLikedBy].
  static String eventInterestedBy(String eventId) =>
      '$apiPrefix/app/events/$eventId/interested-by';
  static String venueInterestedBy(String venueId) =>
      '$apiPrefix/app/places/$venueId/interested-by';

  // Entity relationship signals (PROD-2930). NOTE: the signal routes use the
  // `venues` noun — NOT `places` like the venue detail endpoint above.
  static String venueSignal(String venueId) =>
      '$apiPrefix/app/venues/$venueId/signal';
  static String eventSignal(String eventId) =>
      '$apiPrefix/app/events/$eventId/signal';

  /// The inverse read (`listMySignals`, PROD-3779) — the caller's OWN rated
  /// entities, as saved-shaped cards. Self-scoped: there is no by-handle
  /// variant because a like is not public.
  static const String mySignals = '$apiPrefix/app/users/me/signals';

  // Search endpoints
  static const String searchPlaces = '$apiPrefix/app/places/search';
  static const String searchEvents = '$apiPrefix/app/events/search';

  // Maps v0 endpoints (PROD-2736): slim count-first pins + by-id grid
  // hydration. `discoveryFacets` is the two-layer facet catalog for the
  // (deferred) two-layer Tema UI.
  static const String mapPins = '$apiPrefix/app/map/pins';
  static const String mapHydrate = '$apiPrefix/app/map/hydrate';

  // v2 map search-bar typed suggestions (PROD-3497 / BE PROD-3494).
  static const String mapSuggest = '$apiPrefix/app/map/suggest';

  // Past-searches history for the v2 map search bar (PROD-3495/PROD-3499):
  // POST = record executed selection, GET = newest 10, DELETE = clear-all;
  // per-entry DELETE via mapSearchHistoryEntry. Real-user-only (guests 401).
  static const String mapSearchHistory = '$apiPrefix/app/map/search-history';
  static String mapSearchHistoryEntry(String entryId) =>
      '$apiPrefix/app/map/search-history/$entryId';
  static const String discoveryFacets = '$apiPrefix/app/discovery/facets';

  // Discovery API — multi-query orchestration layer (PROD-3912). POST with a
  // DiscoveryRequest body ({objective, latitude, longitude, entity_types, …});
  // returns a ranked DiscoveryResult. Powers the admin-only "Discovery (for
  // you)" shelf (PROD-3927) and the onboarding vibe step's Sítios/Eventos
  // carousels.
  static const String discovery = '$apiPrefix/app/discovery';

  // Client-side discovery-session engagement ingest (PROD-4257). Fire-and-
  // forget POST of a session-keyed batch (impression/dwell/tap/scroll_past/
  // action). 202, signed-in gated (guests no-op).
  static const String discoveryEngagement =
      '$apiPrefix/app/discovery/engagement';

  // Event category facet catalog (Discovery Events filter chips, PROD-2369).
  // Backend-owned taxonomy: facet ids map server-side to canonical
  // `events.categories[]` values; the frontend renders chips + sends ids.
  static const String eventCategoryFacets =
      '$apiPrefix/app/events/category-facets';

  // Place type facet catalog (Discovery Places filter chips, PROD-2369).
  // Backend-owned taxonomy: facet ids map server-side to canonical root venue
  // types; the frontend renders chips + sends ids.
  static const String placeTypeFacets = '$apiPrefix/app/places/type-facets';

  // Geographic lookups for the location scope picker (PROD-1397 v2)
  static const String geoCountries = '$apiPrefix/app/geo/countries';
  static const String geoCities = '$apiPrefix/app/geo/cities';
  static String geoCityById(String id) => '$apiPrefix/app/geo/cities/$id';
  // PROD-3109: map-picker point-in-polygon boundary lookup.
  static const String geoBoundaryAt = '$apiPrefix/app/geo/boundary/at';
  // Child neighbourhoods (freguesias) of a city-level boundary, for the
  // picker's tap-to-drill layer. Ids are boundary ids (may be path-unsafe).
  static String geoBoundaryChildren(String id) =>
      '$apiPrefix/app/geo/boundary/${Uri.encodeComponent(id)}/children';
  static const String geoAreas = '$apiPrefix/app/geo/areas';
  static const String geoSearch = '$apiPrefix/app/geo/search';
  // Encodes the id: future provider ids (Google place_ids) contain path-unsafe
  // characters, and this is the one place that leak could reach the client.
  static String geoAreaById(String id) =>
      '$apiPrefix/app/geo/areas/${Uri.encodeComponent(id)}';

  // Daily Drop (recommendations) endpoints
  static const String dailyDrop = '$apiPrefix/app/recommendations/daily';
  static const String dailyDropRequest =
      '$apiPrefix/app/recommendations/daily/request';

  /// PROD-2781 / PROD-3232 — load one historic daily recommendation by id.
  /// Response mirrors [dailyDrop], so it parses into the same `DailyDrop`.
  static String recommendationById(String recommendationId) =>
      '$apiPrefix/app/recommendations/$recommendationId';

  // Weekly Bundle (recommendations) endpoints
  static const String weeklyBundle = '$apiPrefix/app/recommendations/weekly';

  // Attribution tracking endpoint
  static const String attributionTouchpoint =
      '$apiPrefix/app/attribution/touchpoint';

  // Analytics — generic unified track endpoint
  static const String analyticsTrack = '$apiPrefix/app/analytics/track';

  // Analytics events endpoints (legacy — kept for backwards compatibility)
  static const String analyticsAppOpen = '$apiPrefix/app/events/app_open';
  static const String analyticsSearchResultClick =
      '$apiPrefix/app/events/search_result_click';
  static const String analyticsExternalClick =
      '$apiPrefix/app/events/external_click';
  static const String analyticsListLinkClickedItem =
      '$apiPrefix/app/events/list_link_clicked_item';

  // Analytics events endpoints (NEW)
  static const String analyticsSignOut = '$apiPrefix/app/events/sign_out';
  static const String analyticsMessageSent =
      '$apiPrefix/app/events/message_sent';
  static const String analyticsMemoriesOpen =
      '$apiPrefix/app/events/memories_open';
  static const String analyticsListElementNote =
      '$apiPrefix/app/events/list_element_note';
  static const String analyticsListItemRemove =
      '$apiPrefix/app/events/list_item_remove';
  static const String analyticsListUnfollow =
      '$apiPrefix/app/events/list_unfollow';
  static const String analyticsListShare = '$apiPrefix/app/events/list_share';
  static const String analyticsMemoriesDownload =
      '$apiPrefix/app/events/memories_download';
  static const String analyticsThemeChange =
      '$apiPrefix/app/events/theme_change';
  static const String analyticsLanguageChange =
      '$apiPrefix/app/events/language_change';
  static const String analyticsChatHistoryOpen =
      '$apiPrefix/app/events/chat_history_open';
  static const String analyticsPageOpen = '$apiPrefix/app/events/page_open';
  static const String analyticsOpenMap = '$apiPrefix/app/events/open_map';
  static const String analyticsOpenLists = '$apiPrefix/app/events/open_lists';
  static const String analyticsListOpen = '$apiPrefix/app/events/list_open';

  // Onboarding funnel analytics endpoints
  static const String analyticsOnboardingStep =
      '$apiPrefix/app/events/onboarding_step';
  static const String analyticsOnboardingComplete =
      '$apiPrefix/app/events/onboarding_complete';
  static const String analyticsLocationPermission =
      '$apiPrefix/app/events/location_permission';
  static const String analyticsLocationSuggestion =
      '$apiPrefix/app/events/location_suggestion';
  static const String analyticsAuthPrompt = '$apiPrefix/app/events/auth_prompt';

  // Split message events (replaces message_sent)
  static const String analyticsMessageSentUser =
      '$apiPrefix/app/events/message_sent_user';
  static const String analyticsMessageSentSoko =
      '$apiPrefix/app/events/message_sent_soko';

  // Menu/profile events
  static const String analyticsAccountOpen =
      '$apiPrefix/app/events/account_open';
  static const String analyticsPreferencesOpen =
      '$apiPrefix/app/events/preferences_open';
  static const String analyticsSupportOpen =
      '$apiPrefix/app/events/support_open';
  static const String analyticsSupportEmailClick =
      '$apiPrefix/app/events/support_email_click';

  // List view mode events
  static const String analyticsListCalendar =
      '$apiPrefix/app/events/list_calendar';
  static const String analyticsListMap = '$apiPrefix/app/events/list_map';

  // List CRUD events
  static const String analyticsListCreate = '$apiPrefix/app/events/list_create';
  static const String analyticsListUpdate = '$apiPrefix/app/events/list_update';
  static const String analyticsListDelete = '$apiPrefix/app/events/list_delete';
  static const String analyticsListFollow = '$apiPrefix/app/events/list_follow';
  static const String analyticsListItemAdd =
      '$apiPrefix/app/events/list_item_add';

  // List search events
  static const String analyticsListSearch = '$apiPrefix/app/events/list_search';

  // Lists hub events
  static const String analyticsListsHubFilter =
      '$apiPrefix/app/events/lists_hub_filter';
  static const String analyticsListsHubSearch =
      '$apiPrefix/app/events/lists_hub_search';

  // List management events
  static const String analyticsListReorder =
      '$apiPrefix/app/events/list_reorder';
  static const String analyticsListCoverChange =
      '$apiPrefix/app/events/list_cover_change';
  static const String analyticsListVisibilityChange =
      '$apiPrefix/app/events/list_visibility_change';

  // List import events
  static const String analyticsListImportStart =
      '$apiPrefix/app/events/list_import_start';
  static const String analyticsListImportComplete =
      '$apiPrefix/app/events/list_import_complete';

  // Suggestion events
  static const String analyticsSuggestionAccept =
      '$apiPrefix/app/events/suggestion_accept';
  static const String analyticsSuggestionDismiss =
      '$apiPrefix/app/events/suggestion_dismiss';

  // Daily Drop events
  static const String analyticsDailyDropOpen =
      '$apiPrefix/app/events/daily_drop_open';
  static const String analyticsDailyDropSave =
      '$apiPrefix/app/events/daily_drop_save';
  static const String analyticsDailyDropShare =
      '$apiPrefix/app/events/daily_drop_share';
  static const String analyticsDailyDropCta =
      '$apiPrefix/app/events/daily_drop_cta';
  static const String analyticsDailyDropClose =
      '$apiPrefix/app/events/daily_drop_close';

  // Weekly Bundle events
  static const String analyticsWeeklyBundleOpen =
      '$apiPrefix/app/events/weekly_bundle_open';
  static const String analyticsWeeklyBundlePageView =
      '$apiPrefix/app/events/weekly_bundle_page_view';
  static const String analyticsWeeklyBundleItemTap =
      '$apiPrefix/app/events/weekly_bundle_item_tap';
  static const String analyticsWeeklyBundleItemsToggle =
      '$apiPrefix/app/events/weekly_bundle_items_toggle';
  static const String analyticsWeeklyBundleClose =
      '$apiPrefix/app/events/weekly_bundle_close';

  // Feature spotlights (PROD-2808)
  static const String featureSpotlights =
      '$apiPrefix/app/users/me/feature-spotlights';
  static String featureSpotlightSeen(String featureId) =>
      '$featureSpotlights/$featureId/seen';

  // Fake-door campaigns
  static const String campaigns = '$apiPrefix/app/campaigns';
  static const String campaignsActive = '$apiPrefix/app/campaigns/active';
  static String campaign(String key) => '$apiPrefix/app/campaigns/$key';
  static String campaignResponse(String key) =>
      '$apiPrefix/app/campaigns/$key/responses';

  // Timeouts
  static const Duration defaultTimeout = Duration(seconds: 20);
  static const Duration authTimeout = Duration(seconds: 30);
  static const Duration uploadTimeout = Duration(seconds: 60);

  /// Longer timeout for list item operations that may involve backend entity creation
  /// (e.g., when adding external places that don't exist in the database yet)
  static const Duration listItemTimeout = Duration(seconds: 45);

  /// Onboarding step persistence (`GET`/`PUT /app/onboarding/state`). A fast DB
  /// upsert, but bumped above [defaultTimeout] so a cold-started backend has room
  /// to respond instead of surfacing the scary generic retry error mid-step.
  static const Duration onboardingStateTimeout = Duration(seconds: 30);

  /// LLM/discovery-pipeline-backed onboarding calls (`POST /app/discovery`
  /// newcomer vibe carousels, preliminary-zines generation, entity hydrate).
  /// These can legitimately exceed [defaultTimeout] on a cold container, so they
  /// get the same headroom as an upload rather than the 20s default.
  static const Duration onboardingContentTimeout = Duration(seconds: 60);
}
