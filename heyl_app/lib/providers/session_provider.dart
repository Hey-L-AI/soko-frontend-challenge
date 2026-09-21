import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/attribution_service.dart';
import '../core/services/storage_service.dart';
import '../data/models/models.dart';
import '../data/models/resolved_search_location.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import 'api_provider.dart';
import 'auth_provider.dart';
import 'chat_seed_location.dart';
import 'location_provider.dart';
import 'resolved_search_location_provider.dart';

/// State for sessions list with pagination support
class SessionsState {
  final List<Session> sessions;
  final bool isLoading;
  final bool isLoadingMore;
  final String? error;
  final String? cursor;
  final bool hasMore;
  final int total;

  const SessionsState({
    this.sessions = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.error,
    this.cursor,
    this.hasMore = true,
    this.total = 0,
  });

  SessionsState copyWith({
    List<Session>? sessions,
    bool? isLoading,
    bool? isLoadingMore,
    String? error,
    String? cursor,
    bool? hasMore,
    int? total,
  }) {
    return SessionsState(
      sessions: sessions ?? this.sessions,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: error,
      cursor: cursor ?? this.cursor,
      hasMore: hasMore ?? this.hasMore,
      total: total ?? this.total,
    );
  }

  /// Group sessions by time period
  Map<String, List<Session>> get groupedSessions {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final thisWeekStart = today.subtract(Duration(days: today.weekday - 1));

    final grouped = <String, List<Session>>{
      'Today': [],
      'Yesterday': [],
      'This Week': [],
      'Older': [],
    };

    for (final session in sessions) {
      final lastMsgAt =
          session.lastMessageAt ?? session.createdAt ?? DateTime.now();
      final sessionDate = DateTime(
        lastMsgAt.year,
        lastMsgAt.month,
        lastMsgAt.day,
      );

      if (sessionDate == today) {
        grouped['Today']!.add(session);
      } else if (sessionDate == yesterday) {
        grouped['Yesterday']!.add(session);
      } else if (sessionDate.isAfter(thisWeekStart)) {
        grouped['This Week']!.add(session);
      } else {
        grouped['Older']!.add(session);
      }
    }

    // Remove empty groups
    grouped.removeWhere((_, sessions) => sessions.isEmpty);

    return grouped;
  }
}

/// Notifier for sessions with pagination support
/// The chat search center (C) to seed a new session with. It uses the shared
/// resolver while it is fast, then falls back to U/default after the
/// first-send latency budget. Null → the backend applies its own default.
final chatSeedLocationProvider = FutureProvider<LocationSnapshot?>((ref) async {
  final lastLocation = ref.watch(locationProvider).lastLocation;
  return resolveChatSeedLocationWithinBudget(
    searchCenter: ref.watch(resolvedSearchLocationProvider.future),
    lastLocation: lastLocation,
  );
});

class SessionsNotifier extends StateNotifier<SessionsState> {
  final ISessionsApi _api;
  final AttributionService _attribution;
  final Ref _ref;
  int _searchCenterRevision = 0;
  final Map<String, ({int revision, SessionSearchCenter searchCenter})>
  _confirmedSearchCenters = {};

  SessionsNotifier(this._api, this._attribution, this._ref)
    : super(const SessionsState());

  /// Load initial page of sessions
  Future<void> loadSessions() async {
    final searchCenterRevisionAtStart = _searchCenterRevision;
    state = state.copyWith(isLoading: true, error: null);

    try {
      final response = await _api.listSessions();
      state = state.copyWith(
        sessions: _preserveNewerConfirmedSearchCenters(
          response.items,
          searchCenterRevisionAtStart,
        ),
        isLoading: false,
        cursor: response.cursor,
        hasMore: response.hasMore,
        total: response.total,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Load more sessions (for infinite scroll)
  Future<void> loadMore() async {
    // Don't load more if already loading or no more pages
    if (state.isLoadingMore || state.isLoading || !state.hasMore) {
      return;
    }

    final searchCenterRevisionAtStart = _searchCenterRevision;
    state = state.copyWith(isLoadingMore: true, error: null);

    try {
      final response = await _api.listSessions(cursor: state.cursor);
      // Deduplicate by sessionId to prevent the same session appearing twice
      // when pagination boundaries shift (e.g., a session's lastMessageAt
      // changed between page loads).
      final existingIds = state.sessions.map((s) => s.sessionId).toSet();
      final newSessions = _preserveNewerConfirmedSearchCenters(
        response.items,
        searchCenterRevisionAtStart,
      ).where((s) => !existingIds.contains(s.sessionId)).toList();
      state = state.copyWith(
        sessions: [...state.sessions, ...newSessions],
        isLoadingMore: false,
        cursor: response.cursor,
        hasMore: response.hasMore,
        total: response.total,
      );
    } catch (e) {
      state = state.copyWith(isLoadingMore: false, error: e.toString());
    }
  }

  /// Create a new session
  Future<Session?> createSession({String? title}) async {
    try {
      String? visitorId;
      try {
        visitorId = await _attribution.getVisitorId();
      } catch (_) {
        // Non-critical: proceed without visitor_id
      }
      final session = await _api.createSession(
        title: title,
        visitorId: visitorId,
        initialLocation: await _ref.read(chatSeedLocationProvider.future),
      );
      state = state.copyWith(
        sessions: [session, ...state.sessions],
        total: state.total + 1,
      );
      return session;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  /// Refresh sessions (reload from beginning)
  Future<void> refresh() => loadSessions();

  /// Update a session's metadata (e.g., after sending a message)
  /// Note: firstMessagePreview is only set if the session doesn't have one yet
  void updateSession(
    String sessionId, {
    String? firstMessagePreview,
    DateTime? lastMessageAt,
  }) {
    final sessions = state.sessions.map((session) {
      if (session.sessionId == sessionId) {
        return session.copyWith(
          // Only set firstMessagePreview if session doesn't have one yet
          firstMessagePreview:
              session.firstMessagePreview ?? firstMessagePreview,
          lastMessageAt: lastMessageAt ?? session.lastMessageAt,
        );
      }
      return session;
    }).toList();

    state = state.copyWith(sessions: sessions);
  }

  /// Writes an already-resolved Search Center (C) to one session, then makes
  /// the API response the local source of truth. There is intentionally no
  /// optimistic update: on a failed mutation the chat continues to display
  /// its last persisted C instead of pretending that it moved.
  Future<SessionSearchCenter> updateSessionSearchCenter(
    String sessionId, {
    required double latitude,
    required double longitude,
    String? label,
  }) async {
    try {
      final searchCenter = await _api.updateSearchCenter(
        sessionId,
        latitude: latitude,
        longitude: longitude,
        label: label,
      );
      final revision = ++_searchCenterRevision;
      _confirmedSearchCenters[sessionId] = (
        revision: revision,
        searchCenter: searchCenter,
      );
      final sessions = state.sessions
          .map(
            (session) => session.sessionId == sessionId
                ? session.copyWith(searchCenter: searchCenter)
                : session,
          )
          .toList();
      state = state.copyWith(sessions: sessions, error: null);
      return searchCenter;
    } catch (error) {
      state = state.copyWith(error: error.toString());
      rethrow;
    }
  }

  /// The current confirmed-C revision. Capture this *before* issuing an async
  /// server read whose result you intend to feed back through
  /// [syncSessionSearchCenterFromServer], so the read-back can tell whether an
  /// explicit picker commit landed in the meantime.
  int get searchCenterRevision => _searchCenterRevision;

  /// Reconciles a conversation's persisted center (C) from an authoritative
  /// server read — `getSession` after a chat turn — so a backend-driven
  /// recenter (e.g. "restaurants in Austin") updates the composer label and map
  /// camera without waiting for a full sessions reload.
  ///
  /// This is a read-back, NOT a write: it never calls the API and never bumps
  /// the confirmed revision. It defers to any explicit picker commit confirmed
  /// after [sinceRevision] (via [_preserveNewerConfirmedSearchCenters]), so a
  /// slow read cannot clobber a fresher manual pick. A null [searchCenter] (an
  /// uncentered session) is ignored rather than wiping a known center.
  void syncSessionSearchCenterFromServer(
    String sessionId,
    SessionSearchCenter? searchCenter, {
    required int sinceRevision,
  }) {
    if (searchCenter == null) return;

    var changed = false;
    final sessions = state.sessions.map((session) {
      if (session.sessionId != sessionId) return session;
      if (_isSameSearchCenter(session.searchCenter, searchCenter)) {
        return session;
      }
      changed = true;
      return session.copyWith(searchCenter: searchCenter);
    }).toList();
    if (!changed) return;

    state = state.copyWith(
      sessions: _preserveNewerConfirmedSearchCenters(sessions, sinceRevision),
    );
  }

  bool _isSameSearchCenter(SessionSearchCenter? a, SessionSearchCenter? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.latitude == b.latitude &&
        a.longitude == b.longitude &&
        a.label == b.label;
  }

  List<Session> _preserveNewerConfirmedSearchCenters(
    Iterable<Session> sessions,
    int requestStartRevision,
  ) {
    return sessions.map((session) {
      final confirmed = _confirmedSearchCenters[session.sessionId];
      if (confirmed == null || confirmed.revision <= requestStartRevision) {
        return session;
      }
      return session.copyWith(searchCenter: confirmed.searchCenter);
    }).toList();
  }

  /// Syncs C after a confirmed picker change for the currently open chat.
  /// Guests, reset-to-auto, unresolved country picks, and U/device updates do
  /// not satisfy [shouldPersistActiveChatSearchCenter] and cannot reach the
  /// session mutation.
  Future<SessionSearchCenter?> persistActiveChatSearchCenterFromPicker() async {
    final searchCenter = await _ref.read(resolvedSearchLocationProvider.future);
    return persistActiveChatSearchCenter(searchCenter);
  }

  /// Persists a resolved candidate before its picker scope becomes global C.
  /// Callers can therefore abort the global commit on an API failure instead of
  /// leaving the picker and the active conversation on different centers.
  Future<SessionSearchCenter?> persistActiveChatSearchCenter(
    ResolvedSearchLocation searchCenter,
  ) async {
    final sessionId = _ref.read(activeSessionIdProvider);
    // Only persist to a chat this account actually owns. `activeSessionId` is
    // restored from storage and can outlive the account that created it (a
    // second account signed in without a clean logout — PROD-4403), so a
    // non-null id is NOT proof of ownership. Writing to a session owned by a
    // different account 403s and surfaces the "Could not update this chat's
    // search area" error on a chat the user isn't even looking at (PROD-4402).
    //
    // Ownership is decided primarily by the profile id embedded in the backend
    // session id (`webapp:{userProfileId}:{uuid}`), which is independent of the
    // paginated `state.sessions` page: a legitimate same-account chat that is
    // beyond the first page, opened by deep link, or not loaded yet is still
    // recognised as owned. `state.sessions` membership is kept as a fallback
    // for any id shape that does not embed the profile id (e.g. guest ids).
    final currentUserId = _ref.read(currentUserProvider)?.id;
    final belongsToUser =
        sessionId != null &&
        ((currentUserId != null &&
                sessionIdOwnedBy(sessionId, currentUserId)) ||
            state.sessions.any((session) => session.sessionId == sessionId));
    final canPersist = shouldPersistActiveChatSearchCenter(
      isAuthenticated: _ref.read(isAuthenticatedProvider),
      activeSessionId: sessionId,
      activeSessionBelongsToUser: belongsToUser,
      searchCenter: searchCenter,
    );
    if (!canPersist) return null;

    // The active chat may have changed while a city point was resolving.
    if (_ref.read(activeSessionIdProvider) != sessionId) return null;

    return updateSessionSearchCenter(
      sessionId!,
      latitude: searchCenter.centerLat!,
      longitude: searchCenter.centerLon!,
      label: searchCenter.label,
    );
  }
}

/// Whether [sessionId] is a webapp chat owned by [userProfileId].
///
/// Backend session ids are `webapp:{ownerId}:{uuid}` for a signed-in user and
/// `webapp:guest:{guestId}:{uuid}` for a guest (see `_create_webapp_session`).
/// The owner is the segment right after the channel prefix, so it is compared
/// exactly — a substring test would treat `user-1` as owning a `user-10`
/// session, or match an id that merely appears inside the trailing uuid.
/// Guest sessions have `guest` in that segment and never match a real profile
/// id, so they correctly fall through to the `state.sessions` membership check.
bool sessionIdOwnedBy(String sessionId, String userProfileId) {
  final parts = sessionId.split(':');
  return parts.length >= 2 && parts[1] == userProfileId;
}

/// Whether a picker result may persist the active conversation's C.
///
/// Keep this policy narrow: C changes only when an authenticated person
/// explicitly chooses a resolvable area/city while an actual chat that they
/// own is active. It therefore excludes auto cascade changes, the device
/// location U, and a stale session id left over from a previous account
/// ([activeSessionBelongsToUser] is false — PROD-4402).
bool shouldPersistActiveChatSearchCenter({
  required bool isAuthenticated,
  required String? activeSessionId,
  required bool activeSessionBelongsToUser,
  required ResolvedSearchLocation searchCenter,
}) =>
    isAuthenticated &&
    activeSessionId != null &&
    activeSessionId.isNotEmpty &&
    activeSessionBelongsToUser &&
    searchCenter.isExplicit &&
    searchCenter.hasCenter;

/// Provider for sessions state
final sessionsProvider = StateNotifierProvider<SessionsNotifier, SessionsState>(
  (ref) {
    final api = ref.watch(sessionsApiProvider);
    final attribution = ref.watch(attributionServiceProvider);
    final notifier = SessionsNotifier(api, attribution, ref);
    // Load sessions on creation
    notifier.loadSessions();
    return notifier;
  },
);

/// Notifier for active session ID with persistence
class ActiveSessionNotifier extends StateNotifier<String?> {
  final StorageService _storageService;

  ActiveSessionNotifier(this._storageService) : super(null) {
    // Restore from storage on creation
    _initFromStorage();
  }

  void _initFromStorage() {
    final savedSessionId = _storageService.getActiveSessionId();
    if (savedSessionId != null) {
      state = savedSessionId;
    }
  }

  /// Set the active session and persist to storage
  void setActiveSession(String? sessionId) {
    state = sessionId;
    // Persist to storage (fire and forget)
    _storageService.saveActiveSessionId(sessionId);
  }

  /// Clear the active session (convenience method)
  void clearActiveSession() {
    setActiveSession(null);
  }
}

/// Provider for active session ID (persisted to storage)
final activeSessionIdProvider =
    StateNotifierProvider<ActiveSessionNotifier, String?>((ref) {
      final storageService = ref.watch(storageServiceProvider);
      return ActiveSessionNotifier(storageService);
    });

/// Provider for active session
final activeSessionProvider = Provider<Session?>((ref) {
  final sessionId = ref.watch(activeSessionIdProvider);
  if (sessionId == null) return null;

  final sessions = ref.watch(sessionsProvider).sessions;
  return sessions.cast<Session?>().firstWhere(
    (s) => s?.sessionId == sessionId,
    orElse: () => null,
  );
});
