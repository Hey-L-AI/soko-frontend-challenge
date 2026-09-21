import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Sessions API
class SessionsApi implements ISessionsApi {
  final ApiClient _apiClient;

  // Local cache for messages (for optimistic UI updates)
  final Map<String, List<ChatMessage>> _sessionMessages = {};

  SessionsApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<SessionsListResponse> listSessions({
    int limit = 20,
    String? cursor,
  }) async {
    final queryParams = <String, dynamic>{'limit': limit};
    if (cursor != null) {
      queryParams['cursor'] = cursor;
    }

    final response = await _dio.get(
      ApiConstants.sessions,
      queryParameters: queryParams,
    );

    final data = response.data as Map<String, dynamic>;
    return SessionsListResponse.fromJson(data);
  }

  @override
  Future<Session> createSession({
    String? title,
    String? visitorId,
    LocationSnapshot? initialLocation,
  }) async {
    final request = SessionCreateRequest(
      title: title,
      visitorId: visitorId,
      initialLocation: initialLocation,
    );

    final response = await _dio.post(
      ApiConstants.sessions,
      data: request.toJson(),
    );

    final data = response.data as Map<String, dynamic>;

    // Create response has session_id, session_uuid, created
    // Build a Session object with available data and defaults
    final session = Session(
      sessionId: data['session_id'] as String,
      sessionUuid: data['session_uuid'] as String?,
      channel: SessionChannel.webapp,
      title: title,
      createdAt: DateTime.now(),
      lastMessageAt: DateTime.now(),
    );

    // Clear local message cache for this session
    // Messages will be loaded fresh from API when viewing the session
    _sessionMessages[session.sessionId] = [];

    return session;
  }

  @override
  Future<({Session session, List<ChatMessage> messages})> getSession(
    String sessionId, {
    int limit = 50,
    String? cursor,
  }) async {
    final queryParams = <String, dynamic>{'limit': limit};
    if (cursor != null) {
      queryParams['cursor'] = cursor;
    }

    final response = await _dio.get(
      ApiConstants.session(sessionId),
      queryParameters: queryParams,
    );

    final data = response.data as Map<String, dynamic>;

    // Backend returns session data at root level, not nested under 'session'
    final session = Session.fromJson(data);

    // Backend returns messages nested inside runs: runs[].messages[]
    // Only use messages from completed runs to avoid duplicates from failed runs
    final runsData = (data['runs'] as List<dynamic>?) ?? [];
    var apiMessages = <ChatMessage>[];

    for (final run in runsData) {
      final runMap = run as Map<String, dynamic>;
      final runStatus = runMap['status'] as String?;

      // Skip failed runs - they contain consolidated duplicates of completed run messages
      if (runStatus == 'failed') continue;

      // Attach the parent run's number so messages sort by turn order
      // (run_number ASC) rather than the coarse/tie-prone created_at — a user
      // message and its assistant reply often share a second, which inverted
      // them under the old timestamp sort.
      final runNumber = runMap['run_number'] as int?;
      final runMessages = (runMap['messages'] as List<dynamic>?) ?? [];
      for (final msg in runMessages) {
        apiMessages.add(
          ChatMessage.fromJson(
            msg as Map<String, dynamic>,
          ).copyWith(runNumber: runNumber),
        );
      }
    }

    // If no messages found in runs (e.g., WhatsApp sessions), fetch directly via listMessages
    if (apiMessages.isEmpty) {
      apiMessages = await listMessages(sessionId, limit: limit, cursor: cursor);
    }

    // Deduplicate messages by ID (in case runs contain overlapping messages)
    final seenIds = <String>{};
    apiMessages.retainWhere((msg) {
      if (seenIds.contains(msg.messageId)) {
        return false; // Remove duplicate
      }
      seenIds.add(msg.messageId);
      return true; // Keep first occurrence
    });

    // Order by turn (run_number ASC), preserving the backend's within-run
    // message array order — see [_sortStableByRunOrder]. This replaces the old
    // created_at sort, which inverted a user message and its same-second
    // assistant reply.
    _sortStableByRunOrder(apiMessages);

    // Merge with local optimistic messages (for messages not yet confirmed by API)
    final existingLocal = _sessionMessages[sessionId] ?? [];

    // Create set of API message IDs for deduplication
    final apiMessageIds = apiMessages.map((m) => m.messageId).toSet();

    // Keep local messages that aren't in API yet (by ID)
    // Also filter out temp IDs (msg_*) that haven't been confirmed by API
    final localOnlyMessages = existingLocal.where((m) {
      // Skip if API already has this message
      if (apiMessageIds.contains(m.messageId)) return false;
      // Skip temp messages that were likely already persisted with different IDs
      if (m.messageId.startsWith('msg_')) return false;
      return true;
    }).toList();

    // Combine: API messages first, then local-only messages
    final mergedMessages = [...apiMessages, ...localOnlyMessages];
    _sortStableByRunOrder(mergedMessages);

    // Cache merged messages
    _sessionMessages[sessionId] = mergedMessages;

    return (session: session, messages: mergedMessages);
  }

  @override
  Future<SessionSearchCenter> updateSearchCenter(
    String sessionId, {
    required double latitude,
    required double longitude,
    String? label,
  }) async {
    final response = await _dio.put(
      ApiConstants.sessionSearchCenter(sessionId),
      data: {
        'latitude': latitude,
        'longitude': longitude,
        if (label != null && label.isNotEmpty) 'label': label,
      },
    );

    return SessionSearchCenter.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<List<ChatMessage>> listMessages(
    String sessionId, {
    int limit = 50,
    String? cursor,
  }) async {
    final queryParams = <String, dynamic>{'limit': limit};
    if (cursor != null) {
      queryParams['cursor'] = cursor;
    }

    final response = await _dio.get(
      ApiConstants.messages(sessionId),
      queryParameters: queryParams,
    );

    final data = response.data as Map<String, dynamic>;
    final items = (data['items'] as List<dynamic>?) ?? [];

    // Flat message list (WhatsApp sessions / pagination) — no run grouping, so
    // these carry no run_number and fall back to the created_at branch of
    // [_sortStableByRunOrder]. API returns newest-first; we want oldest-first.
    final messages = items
        .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
        .toList();
    _sortStableByRunOrder(messages);

    return messages;
  }

  /// Stable in-place ordering for a transcript.
  ///
  /// Primary key is the parent run's `run_number` (turn order; higher = newer),
  /// with the backend's within-run `messages[]` array order preserved via the
  /// original index. This is authoritative and immune to the coarse,
  /// second-granularity `created_at` the backend emits — a user message and its
  /// same-second assistant reply used to invert under a pure timestamp sort,
  /// floating the reply above the turn that prompted it.
  ///
  /// Messages without a run (optimistic/streaming, or the flat WhatsApp
  /// `listMessages` path) sort after run-grouped ones (they're the newest,
  /// not-yet-persisted turn), falling back among themselves to `createdAt`
  /// ascending — the previous behaviour for those paths. Dart's `List.sort` is
  /// not stable, hence the explicit index tie-break throughout.
  static void _sortStableByRunOrder(List<ChatMessage> messages) {
    final indexed = [
      for (var i = 0; i < messages.length; i++) (i, messages[i]),
    ];
    indexed.sort((a, b) {
      final ar = a.$2.runNumber;
      final br = b.$2.runNumber;
      if (ar != null && br != null) {
        if (ar != br) return ar.compareTo(br); // turn order (older runs first)
        return a.$1.compareTo(b.$1); // within a run: backend array order
      }
      if (ar != null) return -1; // run-grouped before local-only (newest)
      if (br != null) return 1;
      // Neither has run context: created_at asc, tie-broken by parse index.
      final byTime = a.$2.createdAt.compareTo(b.$2.createdAt);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
    for (var i = 0; i < indexed.length; i++) {
      messages[i] = indexed[i].$2;
    }
  }

  @override
  void addMessage(String sessionId, ChatMessage message) {
    _sessionMessages.putIfAbsent(sessionId, () => []);
    _sessionMessages[sessionId]!.add(message);
  }

  @override
  List<ChatMessage> getMessages(String sessionId) {
    return _sessionMessages[sessionId] ?? [];
  }

  @override
  void clearMessages(String sessionId) {
    _sessionMessages[sessionId] = [];
  }

  @override
  void clearCache() {
    _sessionMessages.clear();
  }

  @override
  void updateLastMessage(String sessionId, ChatMessage message) {
    final messages = _sessionMessages[sessionId];
    if (messages != null && messages.isNotEmpty) {
      messages[messages.length - 1] = message;
    }
  }
}
