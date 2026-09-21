import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'mock_data.dart';

/// Mock implementation of Sessions API
class MockSessionsApi implements ISessionsApi {
  final List<Session> _sessions = List.from(MockData.mockSessions);
  final Map<String, List<ChatMessage>> _sessionMessages = {};

  /// List sessions with pagination
  @override
  Future<SessionsListResponse> listSessions({
    int limit = 20,
    String? cursor,
  }) async {
    await _simulateDelay();

    // Sort by lastMessageAt descending (null values go last)
    final sorted = List<Session>.from(_sessions)
      ..sort((a, b) {
        final aTime = a.lastMessageAt ?? DateTime(1970);
        final bTime = b.lastMessageAt ?? DateTime(1970);
        return bTime.compareTo(aTime);
      });

    // Find start index based on cursor
    int startIndex = 0;
    if (cursor != null) {
      final cursorIndex = sorted.indexWhere((s) => s.sessionId == cursor);
      if (cursorIndex != -1) {
        startIndex = cursorIndex + 1;
      }
    }

    // Get page of results
    final pageItems = sorted.skip(startIndex).take(limit).toList();
    final hasMore = startIndex + pageItems.length < sorted.length;
    final nextCursor = hasMore ? pageItems.last.sessionId : null;

    return SessionsListResponse(
      items: pageItems,
      total: sorted.length,
      cursor: nextCursor,
      hasMore: hasMore,
    );
  }

  /// Create a new session (always creates fresh - no rolling window)
  @override
  Future<Session> createSession({
    String? title,
    String? visitorId,
    LocationSnapshot? initialLocation,
  }) async {
    await _simulateDelay();

    final session = Session(
      sessionId: 'webapp:mock:session_${DateTime.now().millisecondsSinceEpoch}',
      sessionUuid: DateTime.now().millisecondsSinceEpoch.toString(),
      userId: MockData.mockUser.id,
      createdAt: DateTime.now(),
      lastMessageAt: DateTime.now(),
      channel: SessionChannel.webapp,
      title: title,
    );

    _sessions.insert(0, session);
    _sessionMessages[session.sessionId] = [];

    return session;
  }

  /// Get session detail with messages
  @override
  Future<({Session session, List<ChatMessage> messages})> getSession(
    String sessionId, {
    int limit = 50,
    String? cursor,
  }) async {
    await _simulateDelay();

    final session = _sessions.firstWhere(
      (s) => s.sessionId == sessionId,
      orElse: () => throw Exception('Session not found'),
    );

    final messages = _sessionMessages[sessionId] ?? [];

    return (session: session, messages: messages);
  }

  @override
  Future<SessionSearchCenter> updateSearchCenter(
    String sessionId, {
    required double latitude,
    required double longitude,
    String? label,
  }) async {
    await _simulateDelay(milliseconds: 100);
    final index = _sessions.indexWhere((s) => s.sessionId == sessionId);
    if (index == -1) throw Exception('Session not found');

    final center = SessionSearchCenter(
      latitude: latitude,
      longitude: longitude,
      label: label,
    );
    _sessions[index] = _sessions[index].copyWith(searchCenter: center);
    return center;
  }

  /// Update session (e.g., update title)
  Future<Session> updateSession(String sessionId, {String? title}) async {
    await _simulateDelay(milliseconds: 200);

    final index = _sessions.indexWhere((s) => s.sessionId == sessionId);
    if (index == -1) {
      throw Exception('Session not found');
    }

    final updated = _sessions[index].copyWith(title: title);
    _sessions[index] = updated;

    return updated;
  }

  /// Add a message to a session (internal helper)
  @override
  void addMessage(String sessionId, ChatMessage message) {
    _sessionMessages.putIfAbsent(sessionId, () => []);
    _sessionMessages[sessionId]!.add(message);

    // Update session's lastMessageAt
    final index = _sessions.indexWhere((s) => s.sessionId == sessionId);
    if (index != -1) {
      _sessions[index] = _sessions[index].copyWith(
        lastMessageAt: message.createdAt,
      );
    }
  }

  /// Get messages for a session
  @override
  List<ChatMessage> getMessages(String sessionId) {
    return _sessionMessages[sessionId] ?? [];
  }

  /// List messages for a session from API (mock just returns local messages)
  @override
  Future<List<ChatMessage>> listMessages(
    String sessionId, {
    int limit = 50,
    String? cursor,
  }) async {
    await _simulateDelay();
    final messages = _sessionMessages[sessionId] ?? [];
    // Sort by created_at (oldest first)
    messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return messages.take(limit).toList();
  }

  /// Clear messages for a session
  @override
  void clearMessages(String sessionId) {
    _sessionMessages[sessionId] = [];
  }

  @override
  void clearCache() {
    _sessionMessages.clear();
  }

  /// Update the last message in a session
  @override
  void updateLastMessage(String sessionId, ChatMessage message) {
    final messages = _sessionMessages[sessionId];
    if (messages != null && messages.isNotEmpty) {
      messages[messages.length - 1] = message;
    }
  }

  Future<void> _simulateDelay({int milliseconds = 300}) async {
    await Future.delayed(Duration(milliseconds: milliseconds));
  }
}
