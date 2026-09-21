import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../models/attribution_data.dart';
import '../../models/models.dart';
import '../../models/social/follow_user_summary.dart';

/// Abstract interface for Auth API
abstract class IAuthApi {
  // ========== Phone OTP Authentication ==========

  /// Start phone login — sends OTP via SMS (default) or WhatsApp.
  /// Returns [PhoneStartResponse] carrying `status` + `channel` (actually
  /// attempted) + `sms_fallback_available` so the OTP screen can drive
  /// the channel-aware UX (PROD-2632 infrastructure; default reverted to
  /// SMS pending production BE verification).
  /// [appHash] - Android SMS Retriever signing hash (PROD-3323). Sent only on
  /// native Android so Twilio appends it and the code auto-reads; null
  /// elsewhere leaves the SMS unchanged.
  Future<PhoneStartResponse> startPhoneLogin(
    String phone, {
    String channel = 'sms',
    String? appHash,
  });

  /// Verify OTP and login
  /// [attribution] - Optional attribution data for tracking marketing campaigns
  /// [returnTo]/[claimIntent] - PROD-4040 T2.4 Business Connect return-state;
  /// the backend validates them and echoes `business_return_to`.
  Future<LoginResponse> verifyOtp(
    String phone,
    String code, {
    AttributionData? attribution,
    String? returnTo,
    String? claimIntent,
  });

  // ========== Passwordless Email-OTP Login (PROD-3595) ==========

  /// Start a passwordless email-OTP login — the email fallback rung of the
  /// phone-login channel ladder (PROD-3594). Sends a one-time code to [email].
  /// Response is generic (`status: "sent"`) regardless of whether the email
  /// maps to an account; a rate-limit hit throws (429). Distinct from the
  /// authenticated add-email flow.
  Future<EmailLoginStartResponse> startEmailLogin(String email);

  /// Verify an email-OTP login and log in. On success the backend
  /// finds-or-creates the user by email auth method and issues tokens (same
  /// contract as phone verify).
  /// [attribution] - Optional attribution data for tracking marketing campaigns
  /// [returnTo]/[claimIntent] - PROD-4040 T2.4 Business Connect return-state;
  /// the backend validates them and echoes `business_return_to` (symmetric to
  /// [verifyOtp]).
  Future<LoginResponse> verifyEmailLogin(
    String email,
    String code, {
    AttributionData? attribution,
    String? returnTo,
    String? claimIntent,
  });

  // ========== Email/Password Authentication ==========

  /// Register with email and password
  /// [attribution] - Optional attribution data for tracking marketing campaigns
  Future<RegisterResponse> register({
    required String email,
    required String password,
    String? fullName,
    AttributionData? attribution,
  });

  /// Login with email and password
  /// [attribution] - Optional attribution data for tracking marketing campaigns
  Future<LoginResponse> loginWithEmail({
    required String email,
    required String password,
    AttributionData? attribution,
  });

  /// Activate account with token from email
  Future<ActivationResponse> activateAccount(String token);

  /// Resend activation email
  Future<ResendActivationResponse> resendActivation(String email);

  /// Request password reset email
  Future<ForgotPasswordResponse> forgotPassword(String email, {String? origin});

  /// Reset password with token
  Future<ResetPasswordResponse> resetPassword({
    required String token,
    required String newPassword,
  });

  // ========== OAuth Authentication ==========

  /// Login with Apple Sign-In credentials
  /// [attribution] - Optional attribution data for tracking marketing campaigns
  Future<LoginResponse> loginWithApple({
    required String identityToken,
    required String authorizationCode,
    String? email,
    String? fullName,
    String? nonce,
    AttributionData? attribution,
  });

  /// Login with Google Sign-In native SDK credentials
  /// [attribution] - Optional attribution data for tracking marketing campaigns
  Future<LoginResponse> loginWithGoogle({
    required String idToken,
    String? nonce,
    AttributionData? attribution,
  });

  // ========== Common ==========

  /// Get current authenticated user
  Future<UserProfile> getMe();

  /// Logout current user
  Future<MessageResponse> logout();

  // ========== Guest Session (PROD-1979) ==========

  /// Mint a stateless guest session JWT keyed off [visitorId]. When
  /// `visitorId` is null the server generates one and returns it. The
  /// token has a 24 h TTL and is valid for public + optional-auth
  /// endpoints; real-user endpoints reject it with
  /// `error_code: AUTH_TOKEN_INVALID`.
  Future<GuestSessionResponse> createGuestSession({String? visitorId});
}

/// Abstract interface for Sessions API
abstract class ISessionsApi {
  /// List user's chat sessions with pagination
  Future<SessionsListResponse> listSessions({int limit = 20, String? cursor});

  /// Create a new session (always creates fresh - no rolling window)
  Future<Session> createSession({
    String? title,
    String? visitorId,
    LocationSnapshot? initialLocation,
  });

  /// Get session detail with messages
  Future<({Session session, List<ChatMessage> messages})> getSession(
    String sessionId, {
    int limit = 50,
    String? cursor,
  });

  /// Persist the conversation's Search Center (C) after an explicit picker
  /// confirmation. This is deliberately separate from outgoing message
  /// location (U), which must never move a chat map.
  Future<SessionSearchCenter> updateSearchCenter(
    String sessionId, {
    required double latitude,
    required double longitude,
    String? label,
  });

  /// List messages for a session directly (useful for WhatsApp sessions that don't have runs)
  Future<List<ChatMessage>> listMessages(
    String sessionId, {
    int limit = 50,
    String? cursor,
  });

  /// Add a message to a session (for local state management)
  void addMessage(String sessionId, ChatMessage message);

  /// Get messages for a session (for local state management)
  List<ChatMessage> getMessages(String sessionId);

  /// Clear messages for a session (for starting fresh chats)
  void clearMessages(String sessionId);

  /// Clear all cached messages (for logout / user switch)
  void clearCache();

  /// Update the last message in a session (for attaching place suggestions)
  void updateLastMessage(String sessionId, ChatMessage message);
}

/// Abstract interface for Messages API
abstract class IMessagesApi {
  /// Get message starters
  Future<List<MessageStarter>> getMessageStarters({String? context});

  /// Send a text message
  Future<MessageAcceptedResponse> sendTextMessage(
    String sessionId,
    String text, {
    LocationSnapshot? location,
    String? locale,
    String? visitorId,
  });

  /// Send an image message
  Future<MessageAcceptedResponse> sendImageMessage(
    String sessionId, {
    required String imagePath,
    String? caption,
    LocationSnapshot? location,
    String? locale,
  });

  /// Send a voice message
  Future<MessageAcceptedResponse> sendVoiceMessage(
    String sessionId, {
    required String audioPath,
    String? transcriptHint,
    LocationSnapshot? location,
    String? locale,
  });

  /// Stream message response via SSE
  /// Returns a stream of MessageStreamEvent (chunk, done, or error)
  Stream<MessageStreamEvent> streamMessageResponse(
    String sessionId,
    String messageId,
  );
}

/// Event types for SSE message streaming
enum MessageStreamEventType { message, chunk, done, error, status }

/// Event received from SSE message streaming
class MessageStreamEvent {
  final MessageStreamEventType type;
  final String? text;
  final int? sequence;

  /// For 'message' events: structured rich message content
  final RichMessage? richMessage;

  /// For 'done' events: array of rich messages (webapp channel)
  final List<RichMessage>? richMessages;

  /// Legacy: place suggestions in done event
  final List<ItemSuggestion>? itemSuggestions;

  /// ISO 639-1 language code detected from assistant response (from done event)
  final String? language;

  final String? errorMessage;

  /// For 'status' events: pipeline step name (e.g., "intent", "local_search")
  final String? statusStepName;

  /// For 'status' events: step status ("active", "completed", "failed", "skipped")
  final String? statusStatus;

  const MessageStreamEvent({
    required this.type,
    this.text,
    this.sequence,
    this.richMessage,
    this.richMessages,
    this.itemSuggestions,
    this.language,
    this.errorMessage,
    this.statusStepName,
    this.statusStatus,
  });

  /// Parse from SSE event data
  factory MessageStreamEvent.fromJson(
    String eventType,
    Map<String, dynamic> data,
  ) {
    switch (eventType) {
      case 'message':
        // New structured message event
        return MessageStreamEvent(
          type: MessageStreamEventType.message,
          sequence: data['sequence'] as int?,
          richMessage: RichMessage.fromJson(data),
        );
      case 'chunk':
        // Legacy text chunk
        return MessageStreamEvent(
          type: MessageStreamEventType.chunk,
          text: data['text'] as String?,
          sequence: data['sequence'] as int?,
        );
      case 'done':
        final suggestionsJson = data['place_suggestions'] as List<dynamic>?;
        final messagesJson = data['messages'] as List<dynamic>?;
        return MessageStreamEvent(
          type: MessageStreamEventType.done,
          text: data['text'] as String?,
          itemSuggestions: suggestionsJson
              ?.map((e) => ItemSuggestion.fromJson(e as Map<String, dynamic>))
              .toList(),
          richMessages: messagesJson
              ?.map((e) => RichMessage.fromJson(e as Map<String, dynamic>))
              .toList(),
          language: data['language'] as String?,
        );
      case 'status':
        final richContent = data['rich_content'] as Map<String, dynamic>?;
        return MessageStreamEvent(
          type: MessageStreamEventType.status,
          text: data['text'] as String?,
          sequence: data['sequence'] as int?,
          statusStepName: richContent?['step_name'] as String?,
          statusStatus: richContent?['status'] as String?,
        );
      case 'error':
        return MessageStreamEvent(
          type: MessageStreamEventType.error,
          errorMessage: data['message'] as String?,
        );
      default:
        // Unknown event types are silently treated as status (not error)
        // to avoid killing the stream when the backend adds new event types.
        return MessageStreamEvent(
          type: MessageStreamEventType.status,
          text: data['text'] as String?,
        );
    }
  }

  bool get isMessage => type == MessageStreamEventType.message;
  bool get isChunk => type == MessageStreamEventType.chunk;
  bool get isDone => type == MessageStreamEventType.done;
  bool get isError => type == MessageStreamEventType.error;
  bool get isStatus => type == MessageStreamEventType.status;
}

/// Abstract interface for Events API
abstract class IEventsApi {
  /// List events with optional filters
  Future<EventListResponse> listEvents({
    String? city,
    String? startDate,
    String? endDate,
    int limit = 100,
    String? cursor,
  });

  /// Get a single event by ID, including its occurrences
  Future<EventDetailResponse> getEvent(
    String eventId, {
    String? startDate,
    String? endDate,
  });
}

/// Abstract interface for Venues API
abstract class IVenuesApi {
  /// List venues with optional city filter
  Future<VenueListResponse> listVenues({
    String? city,
    int limit = 100,
    String? cursor,
  });

  /// Resolve a Google Maps URL to a venue, OR start a shared-list import.
  ///
  /// The backend (PROD-3903) resolves a single place synchronously (200/201)
  /// but, when the URL is a shared Google Maps *list*, starts an async import
  /// job and returns 202. Callers switch on the returned [ResolveUrlResult]:
  /// [ResolveUrlPlace] renders the venue; [ResolveUrlListImport] hands the
  /// `job_id` to the import poller (`importListProvider`).
  ///
  /// Throws a [ResolveUrlFailure] subtype on non-2xx responses or network
  /// errors — callers should switch on the failure type to show specific
  /// error copy.
  Future<ResolveUrlResult> resolveVenueFromUrl(String url);

  /// Resolve a chat place card's `google_place_id` to a real venue (PROD-4380).
  ///
  /// Chat venue-search cards for places not yet in our DB carry a
  /// `google_place_id` but no `venue_id`, so the client has no in-app entity to
  /// open or add. This resolves the place id to an [ItemSuggestion] carrying the
  /// venue UUID (creating the venue from Google on a DB miss). Throws a
  /// [ResolveUrlFailure] subtype on non-2xx / network errors.
  Future<ItemSuggestion> resolvePlaceId(String googlePlaceId);
}

/// Abstract interface for Saved Items API
abstract class ISavedApi {
  /// List saved items
  Future<SavedListResponse> listSaved({
    String? type,
    int limit = 50,
    String? cursor,
  });

  /// Save an item
  Future<SavedItem> saveItem(SavedCreateRequest request);

  /// Delete a saved item
  Future<void> deleteSaved(String savedId);

  /// Check if an item is saved (local helper)
  bool isSaved({String? eventId, String? venueId});

  /// Clear cached data (call on logout)
  void clearCache();
}

/// Merged library feed (PROD-4103) — `GET /users/me/library`.
abstract class ILibraryApi {
  Future<LibraryFeedOut> getLibrary({
    int limit = 20,
    String? cursor,
    String? types,
    String sort = 'recent',
    String? q,
    String? membership,
    String? when,
    String? fromDate,
    String? toDate,
    String? direction,
  });

  Future<LibraryPinOut> pinLibraryItem({
    required LibraryFeedItemType type,
    required String id,
  });

  Future<LibraryPinOut> unpinLibraryItem({
    required LibraryFeedItemType type,
    required String id,
  });
}

/// Abstract interface for Lists API
abstract class IListsApi {
  /// List user's lists.
  ///
  /// The `containsVenueId` / `containsEventId` / `containsGooglePlaceId`
  /// filters are used by the bookmark sheet (PROD-1430/PROD-1435) to fetch
  /// the set of lists already containing a given item for accurate
  /// pre-selection. Only one should be set per call — the backend ANDs
  /// them together if multiple are set.
  Future<UserListsResponse> listMyLists({
    String? q,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? scope,
    String? containsVenueId,
    String? containsEventId,
    String? containsGooglePlaceId,
    int limit = 50,
    int offset = 0,
  });

  /// Slim list of every place the caller has saved in the selected city.
  /// Powers the map surface of the `/lists` hub. Server applies the same
  /// ~25 km radius + ownership/collaborative scope as the deleted
  /// `/lists/items` endpoint.
  ///
  /// `cityId` accepts the same shape as `/geo/cities/{id}` — a local UUID
  /// or a Google `place_id`. Optional since PROD-2145: when omitted, the
  /// BE returns the caller's pins across all cities (no spatial filter).
  ///
  /// `sessionToken` threads through the picker's Google billing session
  /// when the city resolution needs a fresh Place Details lookup —
  /// optional cost-optimization, the endpoint works without it.
  Future<ListsMapPinsResponse> getListsMapPins({
    String? cityId,
    bool? includeCollaborative,
    String? sessionToken,
    String? locale,
    String? scope,
    int limit = 1000,
    int offset = 0,
  });

  /// Slim list of saved events with their qualifying occurrences nested.
  /// Powers the calendar surface of the `/lists` hub. Each occurrence
  /// carries its own venue lat/lng so the FE can pin event venues on the
  /// map alongside the place pins from [getListsMapPins] (deduped client-
  /// side).
  ///
  /// `cityId` is optional (PROD-2145): when omitted, the BE returns the
  /// caller's events across all cities. `fromDate` is inclusive, `toDate`
  /// exclusive; BE returns 422 if `toDate <= fromDate`. Past occurrences
  /// are never returned regardless of `fromDate`.
  Future<ListsCalendarEventsResponse> getListsCalendarEvents({
    String? cityId,
    required DateTime fromDate,
    required DateTime toDate,
    bool? includeCollaborative,
    String? sessionToken,
    String? locale,
    String? scope,
    int limit = 500,
    int offset = 0,
  });

  /// Search saved items inside the caller's lists by text query (PROD-1934).
  /// Unifies the searchable field set with `listMyLists(q=…)` — events
  /// and places now match across title, venue name/city/address/type,
  /// event categories/vibes/tags, and the user's `tip`. No location or
  /// date filter; past-only events + soft-deleted items + canonical-
  /// merged events are excluded server-side.
  ///
  /// Replaces the FE's previous `listMyLists(q) + per-list listItems`
  /// fan-out for the Eventos / Sítios tabs of the `/lists` hub. `q` is
  /// required (1..255); pass [itemType] to narrow to one type, or omit
  /// to return both.
  Future<SavedSearchItemsResponse> searchSavedItems({
    required String q,
    SavedItemType? itemType,
    bool? includeCollaborative,
    String? locale,
    String? scope,
    int limit = 100,
    int offset = 0,
  });

  /// Get all discovery sections (10 items each)
  ///
  /// [locationMode] (`around` | `contain`, PROD-3196) selects the recommended
  /// section's geo mode; `contain` requires [adminBoundaryId] (the public
  /// boundary token) and is a no-op until the server-side flag flips.
  Future<DiscoverListsResponse> discoverLists({
    String? q,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? searchRange,
    String? scope,
    String? locationMode,
    String? adminBoundaryId,
  });

  /// Get curated Soko editorial lists
  Future<UserListsResponse> listCuratedLists({
    String? q,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? searchRange,
    String? scope,
    int limit = 10,
    int offset = 0,
  });

  /// Browse/search public lists for discovery.
  ///
  /// Discovery flag filters (PROD-1513): pass `true`/`false` to constrain to
  /// lists with that exact value, or `null` to skip the filter. They
  /// AND-combine.
  ///
  /// `sort` accepts the OpenAPI enum values `'recent'` (default),
  /// `'popular'` (all-time follower count), or `'popular_last_week'`
  /// (last 7 days). Ignored when `q` is provided.
  ///
  /// Geo filtering (PROD-1999) uses the shared `SearchLocation*` param
  /// group: pass `cityId` (local-source UUID) or `latitude`/`longitude`,
  /// optionally with `radiusKm`. No location params → no geo filter (the
  /// legacy `scope=local` stored-location fallback was removed).
  /// `locationSource` is analytics-only: `picker`, `gps`, `ip`, `profile`,
  /// `default`.
  ///
  /// `searchRange` (PROD-3156) is a named `SEARCH_RANGE_CONFIG` tier
  /// (`near_me`…`metro`, see the `SearchRange` enum) resolved to a radius
  /// server-side; it takes precedence over `radiusKm`. Omit → the `radiusKm`
  /// default applies.
  Future<UserListsResponse> listPublicLists({
    String? q,
    String? cityId,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? searchRange,
    String? locationSource,
    String? sort,
    bool? editorPick,
    bool? cityGuide,
    bool? verified,
    int limit = 50,
    int offset = 0,
    // Optional cancel hook for callers that fire request-per-keystroke
    // searches (Discovery action bar) and want to drop in-flight requests
    // when the user retypes. Most callers leave this null.
    CancelToken? cancelToken,
  });

  /// Get a user's public lists by handle (PROD-1516, PROD-1573, PROD-1999).
  ///
  /// Powers the Discovery Page "Recomendado" shelf, which calls this with
  /// Soko's handle. Returns 404 when no active user matches the handle.
  /// Default ordering on the backend is `created_at DESC`.
  ///
  /// `editorPick` / `cityGuide` are server-side AND filters with identical
  /// semantics to `/lists/public`: omit = no filter, `false` = exclude flagged
  /// lists, `true` = only flagged lists. Recomendado passes both as `false`
  /// so it doesn't overlap the Editor Picks and City Guides shelves.
  ///
  /// Geo filtering (PROD-1999) accepts the shared `SearchLocation*` param
  /// group — without it, all of the handle's public lists are returned (no
  /// implicit stored-location fallback).
  Future<UserListsResponse> listPublicListsByHandle({
    required String handle,
    bool? editorPick,
    bool? cityGuide,
    String? cityId,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? searchRange,
    String? locationSource,
    int limit = 50,
    int offset = 0,
  });

  /// Create a new list
  Future<UserList> createList(UserListCreate request);

  /// Get default list (lazy creation)
  Future<UserList> getDefaultList();

  /// Get a specific list
  Future<UserList> getList(String listId);

  /// Update list settings
  Future<UserList> updateList(String listId, UserListUpdate request);

  /// Upload a custom cover image for a list
  Future<UserList> uploadListCover(String listId, String imagePath);

  /// PROD-3217 — upload the app-rendered 4:5 zine-cover PNG that the
  /// IG-Story share card composites. Owner-only. Returns the updated list
  /// carrying the new `cover_share_render_url`.
  Future<UserList> uploadListCoverShareRender(
    String listId,
    Uint8List pngBytes,
  );

  /// Delete a list
  Future<void> deleteList(String listId);

  /// List items in a list
  Future<UserListItemsResponse> listItems(
    String listId, {
    SavedItemType? itemType,
    int limit = 50,
    int offset = 0,
  });

  /// Slim variant of [listItems] — drops the embedded `venue`/`event`
  /// blobs in favour of pre-resolved flat fields, and returns a
  /// server-deduped `map_pins` array. Pagination shape A: `map_pins` is
  /// the full whole-list set on every response, so the FE never has to
  /// reconcile pin sets across pages (see PROD-1966 § Pagination).
  /// `limit` accepts up to 500 on the BE side.
  ///
  /// [sort] overrides the list's stored `sort_mode` for this request only and
  /// writes nothing back. Pass `null` (the default) to keep the list's own
  /// order — including an owner's hand-arranged `custom` sequence, which has
  /// no wire value of its own.
  Future<UserListItemsSlimOut> listItemsSlim(
    String listId, {
    SavedItemType? itemType,
    int limit = 500,
    int offset = 0,
    ZineItemSort? sort,
  });

  /// Add item to a list.
  ///
  /// Returns the written item plus the backend's authoritative post-write
  /// `list_item_count` and `created` flag (PROD-3295) — see
  /// [UserListItemAddResult]. Analytics must use those rather than a
  /// locally-derived count.
  Future<UserListItemAddResult> addItem(
    String listId,
    UserListItemCreate request,
  );

  /// Quicksave — save an item without choosing a list (PROD-3873).
  ///
  /// `POST /app/lists/items`. The server resolves the caller's Saved Items
  /// list (creating it lazily) and files the item there; read the resolved
  /// list id off the returned item (`result.item.listId`). Same request body
  /// and [UserListItemAddResult] as [addItem], and the same 30/min rate
  /// bucket — the two routes are not separate budgets.
  Future<UserListItemAddResult> addItemToDefaultDestination(
    UserListItemCreate request,
  );

  /// Update item tip. Returns the echoed membership row plus the backend's
  /// authoritative note transition ([UserListItemWriteResult.noteAction],
  /// PROD-4552) so the caller can emit the right `list_element_note` and
  /// suppress no-op edits without inferring the change from a stale local tip.
  Future<UserListItemWriteResult> updateItem(
    String listId,
    String itemId,
    UserListItemUpdate request,
  );

  /// Remove item from list
  Future<void> removeItem(String listId, String itemId);

  /// Bulk-remove items from a list in a single request (PROD-1722).
  /// Returns the partition of `deleted` vs `skipped` ids per the OpenAPI
  /// contract. Spec is shipped; backend deployment is tracked in PROD-1722.
  Future<BulkDeleteItemsResponse> bulkDeleteItems(
    String listId,
    List<String> itemIds,
  );

  /// Reorder items in a list (owner only)
  Future<void> reorderItems(String listId, List<String> itemIds);

  /// Check if an item is in a specific list (local helper)
  bool isInList(
    String listId, {
    String? eventId,
    String? venueId,
    String? googlePlaceId,
  });

  /// Check if an item is in default list (local helper)
  bool isInDefaultList({String? eventId, String? venueId});

  /// Check if an item is in ANY owned list (local helper)
  /// Returns true if the item exists in any of the user's owned lists
  bool isInAnyOwnedList({String? eventId, String? venueId});

  /// Get the item ID for an event/venue/place in a specific list
  /// Returns null if the item is not in the list or not cached
  String? getItemId(
    String listId, {
    String? eventId,
    String? venueId,
    String? googlePlaceId,
  });

  /// Warm the global saved-state cache (owned event/venue/google-place ids)
  /// from the bulk `getSavedEntityIds` endpoint. Call on app startup / after
  /// login and on pull-to-refresh. See PROD-2845.
  Future<void> loadAllOwnedItems();

  /// Get all event IDs saved in any owned list (read-only access to cache)
  Set<String> get allOwnedEventIds;

  /// Get all venue IDs saved in any owned list (read-only access to cache)
  Set<String> get allOwnedVenueIds;

  /// Get all Google Place IDs saved in any owned list (read-only access to cache)
  Set<String> get allOwnedGooglePlaceIds;

  /// Add a Google Place ID to the owned items cache (for immediate UI update after save)
  void addGooglePlaceIdToCache(String googlePlaceId);

  /// Clear cached data (call on logout)
  void clearCache();

  // ============================================================================
  // Import Methods
  // ============================================================================

  /// Start an async Google Maps list import
  ///
  /// Returns a job ID to poll for status.
  Future<ImportJobCreatedResponse> importGoogleMapsList(
    String url, {
    String? listName,
  });

  /// Get the status of an import job
  Future<ImportJobStatusResponse> getImportJobStatus(String jobId);

  // ============================================================================
  // Public List Methods (no authentication required)
  // ============================================================================

  /// Get a public list without authentication
  ///
  /// Returns list details if the list exists and has visibility=public.
  /// Throws 404 if list is private or doesn't exist.
  Future<PublicList> getPublicList(
    String listId, {
    String? ref,
    String? visitorId,
  });

  /// List items in a public list without authentication
  ///
  /// Returns items with expanded event/venue details.
  /// Throws 404 if list is private or doesn't exist.
  Future<PublicListItemsResponse> listPublicItems(
    String listId, {
    SavedItemType? itemType,
    int limit = 50,
    int offset = 0,
    String? ref,
    String? visitorId,
  });

  /// Slim variant of [listPublicItems] for unauthenticated viewers of
  /// public lists. Honors `ref` / `visitor_id` for attribution (the slim
  /// endpoint emits a `list_link_opened` analytics event server-side
  /// when these are provided — see PROD-1966 § 7). `list_id` accepts
  /// either a UUID or a slug.
  Future<UserListItemsSlimOut> listPublicItemsSlim(
    String listId, {
    SavedItemType? itemType,
    int limit = 500,
    int offset = 0,
    String? ref,
    String? visitorId,
    ZineItemSort? sort,
  });

  // ============================================================================
  // Follow Methods
  // ============================================================================

  /// Follow a public list
  ///
  /// Returns true if successfully followed.
  /// Cannot follow your own lists.
  Future<void> followList(String listId);

  /// Unfollow a list
  Future<void> unfollowList(String listId);

  /// Followers of a list (zine). Public zines are viewable by anyone; private
  /// zines are owner-only (403). Rows carry the viewer's follow relationship.
  Future<FollowUserListResponse> getListFollowers(
    String listId, {
    int limit,
    int offset,
  });

  /// List public lists the user is following
  Future<UserListsResponse> listFollowedLists({
    String? q,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? scope,
    int limit = 50,
    int offset = 0,
  });

  // ============================================================================
  // Suggested Lists Methods
  // ============================================================================

  /// Get personalized suggested public lists
  ///
  /// Returns public lists ranked by relevance based on:
  /// 1. Location match (60% weight): Lists with items in user's city
  /// 2. Interest match (40% weight): Lists matching user's interests
  ///
  /// Lists owned by the user or already followed are excluded.
  ///
  /// [locationMode] (`around` | `contain`, PROD-3196) selects the geo mode;
  /// `contain` requires [adminBoundaryId] (the public boundary token). The
  /// endpoint takes no coordinates — `around` uses the user's tagged location
  /// and `contain` uses the boundary centroid, both server-side. No-op until
  /// the server-side flag flips.
  Future<List<SuggestedList>> getSuggestedLists({
    String? q,
    int limit = 40,
    int offset = 0,
    String? locationMode,
    String? adminBoundaryId,
  });

  /// Get suggested public lists for guest (unauthenticated) users
  ///
  /// Uses provided coordinates if available, otherwise falls back to IP geolocation.
  /// No personalization is applied (distance-only scoring).
  ///
  /// [locationMode] (`around` | `contain`, PROD-3196) selects the geo mode;
  /// `contain` requires [adminBoundaryId] (the public boundary token). No-op
  /// until the server-side flag flips.
  ///
  /// Returns empty list if location cannot be determined.
  Future<List<SuggestedList>> getGuestSuggestedLists({
    int limit = 40,
    double? latitude,
    double? longitude,
    String? locationMode,
    String? adminBoundaryId,
  });
}

/// Abstract interface for Memory API
abstract class IMemoryApi {
  /// Get user memory
  Future<UserMemory> getMemory({String? locale});

  /// Get memory items for display
  Future<List<MemoryItem>> getMemoryItems({String? locale});

  /// Delete a memory item
  Future<MessageResponse> deleteMemoryItem(MemoryItemDeleteRequest request);

  /// Ingest memory from conversation
  Future<MessageResponse> ingestMemory(MemoryIngestRequest request);

  /// Export memory as markdown bytes
  /// Returns the raw bytes of the markdown file
  ///
  /// [locale] - Optional locale code (e.g., 'en', 'pt-BR')
  ///           Defaults to user's preferred_locale if not provided
  Future<List<int>> exportMemory({String? locale});

  /// Clear cached data (call on logout)
  void clearCache();
}

/// Abstract interface for Location API
abstract class ILocationApi {
  /// Update user location
  Future<LocationUpdateResponse> updateLocation(LocationUpdateRequest request);

  /// Update tagged location (e.g., "current", "home")
  Future<LocationUpdateResponse> updateTaggedLocation(
    String tag,
    LocationUpdateRequest request,
  );

  /// Get last known location
  Future<LocationSnapshot?> getLocation();

  /// Create share link for location
  Future<Map<String, dynamic>> createShareLink({int expiresInHours = 24});
}

/// Abstract interface for Account API
abstract class IAccountApi {
  /// Delete account
  Future<MessageResponse> deleteAccount(DeleteAccountRequest request);

  /// Get support info
  Future<SupportInfo> getSupportInfo();
}

/// Abstract interface for user marketing preferences and legal acceptance.
abstract class IPreferencesApi {
  Future<UserPreferences> getPreferences();

  Future<UserPreferences> updatePreferences(UpdatePreferencesRequest request);
}

/// Abstract interface for Auth Methods API (add/remove phone/email)
abstract class IAuthMethodsApi {
  /// List all authentication methods
  Future<AuthMethodsListResponse> listAuthMethods();

  /// Remove a secondary authentication method
  Future<RemoveAuthMethodResponse> removeAuthMethod(String methodId);

  /// Start phone verification for adding to account
  /// [appHash] - Android SMS Retriever signing hash (PROD-3323), Android-only.
  Future<OTPStartResponse> startAddPhone(
    String phone, {
    String channel = 'sms',
    String? appHash,
  });

  /// Verify OTP and add phone (or trigger merge flow)
  /// Returns AddAuthMethodResponse or VerifyWithMergeResponse
  Future<dynamic> verifyAddPhone(String phone, String code);

  /// Start email verification for adding to account
  Future<OTPStartResponse> startAddEmail(String email);

  /// Verify OTP and add email (or trigger merge flow)
  /// Returns AddAuthMethodResponse or VerifyWithMergeResponse
  Future<dynamic> verifyAddEmail(String email, String code);

  /// Confirm account merge
  Future<MergeConfirmResponse> confirmMerge(MergeConfirmRequest request);

  /// Update user profile (name, handle, and/or preferred_locale)
  Future<ProfileUpdateResponse> updateProfile(ProfileUpdateRequest request);

  /// Check if a handle is available
  Future<HandleAvailabilityResponse> checkHandleAvailability(String handle);

  /// Update WhatsApp preference (select preferred WhatsApp number)
  Future<void> updateWhatsappPreference(String whatsappPhone);
}

/// Abstract interface for Locales API
abstract class ILocalesApi {
  /// List available locales (public endpoint, no auth required)
  Future<LocaleListResponse> listLocales();
}

/// Abstract interface for WhatsApp API
abstract class IWhatsAppApi {
  /// List available WhatsApp numbers (public endpoint, no auth required)
  Future<List<WhatsAppNumber>> listNumbers();
}

/// Abstract interface for Instagram API
abstract class IInstagramApi {
  /// Get Instagram OAuth authorization URL
  Future<InstagramConnectResponse> getConnectUrl();

  /// List connected Instagram accounts
  Future<InstagramConnectionListResponse> listConnections();

  /// Disconnect an Instagram account
  Future<void> disconnect(String connectionId);

  /// Get pending connection details (duplicate warning)
  Future<PendingConnectionResponse> getPendingConnection(String key);

  /// Confirm a pending connection despite duplicate
  Future<PendingConnectionConfirmResponse> confirmPendingConnection(String key);
}

/// Abstract interface for Referrals API
abstract class IReferralsApi {
  /// Get pending search for a referral slug (public endpoint, no auth required)
  ///
  /// Returns the search query associated with a referral slug.
  /// Called after authentication to retrieve and execute the search.
  Future<PendingSearchResponse> getPendingSearch(String slug);
}

/// Abstract interface for the Discovery feeds API (PROD-1515 / PROD-1553 /
/// PROD-1554 / PROD-1999).
///
/// All three feed methods accept the shared `SearchLocation*` param group
/// from the OpenAPI spec — `cityId`, `latitude`/`longitude`, and
/// `locationSource`. The BE accepts either a `cityId` or coords; coord-
/// scoped feeds (`/feed/near-you`) snap to the nearest seeded city when
/// only `cityId` is supplied, and city-scoped feeds (`/feed/highlighted`,
/// `/feed/venues-with-events`) snap lat/lon to the nearest seeded city
/// within 50 km. `locationSource` is analytics-only and accepts the spec
/// enum values: `picker`, `gps`, `ip`, `profile`, `default`.
abstract class IFeedApi {
  /// Server-driven Discovery feed (PROD-4005, umbrella PROD-3998) —
  /// `GET /api/v1/app/feed/home`. One call returns a typed block list the
  /// backend composed: which elements appear, how many items each carries and
  /// in what order are all backend decisions.
  ///
  /// **There is no `limit`** — page size is server-owned (D26). Page 1 is the
  /// filter's lead block plus one or two headroom blocks.
  ///
  /// Pass [cursor] back verbatim from the previous response's `next_cursor`;
  /// the value encodes an index into a layout the backend owns and expects to
  /// change, so do not parse it. A cursor that is corrupt, from an older
  /// layout, or minted for a different filter **restarts the feed at page 1
  /// rather than erroring** — callers must not treat "page 1 again" as a loop.
  ///
  /// **Send every location signal you hold** (PROD-4291). [cityId] and
  /// [latitude]/[longitude] are resolved *independently* by the backend — a
  /// city-scoped consumer reads the city, a coord-scoped one reads the point —
  /// so they are no longer either/or, and they now travel together wherever
  /// both exist. With neither, the backend answers 400.
  ///
  /// [radiusKm] and [adminBoundaryId] are **accepted and recorded, not yet
  /// honoured** (PROD-4289): the feed is still composed per city, and the
  /// radius is never the snap tolerance. They are carried so the follow-up
  /// that migrates composition onto the radius can be designed against what
  /// clients actually send.
  ///
  /// ⚠️ Every value here must sit inside the bound the endpoint declares —
  /// out-of-range is a 422, which renders as a **blank feed** rather than a
  /// degraded one. The guards live at the call site in `feed_home_provider`.
  Future<FeedHomeOut> getHomeFeed({
    FeedFilter filter = FeedFilter.events,
    String? cityId,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? adminBoundaryId,
    String? cursor,
  });

  /// Get the events-only Near-You feed — Discovery Page "Happening"
  /// shelf (PROD-1963). Items are ranked using the same v1 pipeline as
  /// the combined feed, restricted to the events track. Caller paginates
  /// by passing increasing `offset` values.
  Future<NearYouEventsFeedResponse> getNearYouEventsFeed({
    required double latitude,
    required double longitude,
    int limit = 20,
    int offset = 0,
    String? seed,
    DateTime? snapshotAt,
    bool? personalize,
  });

  /// Get the venues-only Near-You feed — Discovery Page "Near you"
  /// (places) shelf (PROD-1963). Items are ordered by ascending distance
  /// from the requested coordinate within a hard 15 km radius. Caller
  /// paginates by passing increasing `offset` values.
  Future<NearYouPlacesFeedResponse> getNearYouPlacesFeed({
    required double latitude,
    required double longitude,
    int limit = 20,
    int offset = 0,
    String? seed,
    DateTime? snapshotAt,
    bool? personalize,
  });

  /// Run the Discovery API (`POST /api/v1/app/discovery`, PROD-3912) for the
  /// admin-only discovery feed shelves. Personalization is resolved
  /// server-side from the auth token; coords (when available) scope the
  /// results, otherwise the BE falls back to the viewer's memory location.
  ///
  /// [entityTypes] gates the whole pipeline (`events` / `venues` / `both`).
  /// [offset] pages the deterministic V1 ranking: resend the same request with
  /// a growing offset and stop when the response `has_more` is false.
  /// [numResults] is the page size.
  Future<DiscoveryForYouResponse> getDiscoveryForYou({
    String objective = 'for_you',
    String entityTypes = 'both',
    double? latitude,
    double? longitude,
    int numResults = 15,
    int offset = 0,
  });

  /// Get the Em destaque (highlighted) shelf — a marketing-curated ordered
  /// selection resolved server-side via `city → country → hide`
  /// (PROD-1554 → PROD-1986). 0–10 cards; the FE slices to 2. No
  /// pagination.
  ///
  /// `cityId` (a local-source UUID returned by `/geo/cities`) is preferred;
  /// when only coords are supplied the BE snaps to the nearest seeded city
  /// within 50 km. Google place_ids are silently ignored. Empty `cards`
  /// array means neither the per-city nor the per-country scope is
  /// populated — caller hides the shelf.
  Future<HighlightedFeedResponse> getHighlightedFeed({
    String? cityId,
    double? latitude,
    double? longitude,
    String? locationSource,
  });

  /// Get the Espaços (venues-with-events) shelf — venues with ≥ 2 active
  /// scheduled occurrences in the next 15 days, city-scoped (PROD-1553).
  /// Bucket-shuffled by event-count tier. Caller paginates via `offset`.
  ///
  /// `cityId` (local-source UUID) is preferred; coords snap to the nearest
  /// seeded city within 50 km. Limit: max 20, default 10.
  Future<VenuesWithEventsFeedResponse> getVenuesWithEventsFeed({
    String? cityId,
    double? latitude,
    double? longitude,
    String? locationSource,
    int limit = 10,
    int offset = 0,
  });
}

/// Abstract interface for Onboarding API.
///
/// Powers the post-signup vibe flow: morning/activity/food/night vibe picks
/// + 1-2 interest chips → archetype + saved 5-spot itinerary list. See the
/// implementation plan for the full contract.
abstract class IUserProfilingApi {
  /// Fetch the question catalog (5 steps, options, localization keys).
  ///
  /// Cache-friendly: backend returns a `version` so the client can
  /// invalidate when editorial ships new copy.
  Future<UserProfilingQuestions> getQuestions();

  /// Submit the user's answers. Atomic on the backend: persists vibe
  /// selections to the user profile, computes the archetype, generates the
  /// 5-spot itinerary, and creates a Soko list with `source=onboarding`.
  ///
  /// Returns the assigned archetype + the saved itinerary (including the
  /// `list_id` of the newly created list).
  Future<UserProfilingSubmitResponse> submit(
    UserProfilingSubmitRequest request,
  );
}

/// Resumable chat-onboarding state (PROD-3882 / BE-1). The backend is the
/// source of truth for onboarding progress; distinct from the V6
/// `/user_profiling/*` survey surface.
abstract class IOnboardingStateApi {
  /// Read the durable onboarding state. Always 200 — a user who never advanced
  /// gets a null-`state` envelope with `complete` from `onboarding_complete`.
  Future<OnboardingStateDto> getState();

  /// Idempotent per-`(user, step)` upsert; returns the merged state. `step:
  /// "complete"` flips `onboarding_complete`.
  Future<OnboardingStateDto> putState(OnboardingStatePutDto request);

  /// Admin/QA replay: clears state + flips `onboarding_complete` back to false,
  /// returning the fresh (never-advanced) envelope. Lets a finished user re-run
  /// the real gated flow from the top.
  Future<OnboardingStateDto> resetState();
}
