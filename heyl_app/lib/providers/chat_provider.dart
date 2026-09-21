import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/attribution_service.dart';
import '../core/services/storage_service.dart';
import '../core/services/unified_analytics_service.dart';
import '../data/models/models.dart';
import '../data/models/rich_message.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import 'api_provider.dart';
import 'locale_provider.dart';
import 'location_provider.dart';
import 'memory_provider.dart';
import 'session_provider.dart';

/// State for chat messages
class ChatState {
  final List<ChatMessage> messages;
  final bool isLoading;
  final bool isSending;
  final bool isStreaming;
  final String? streamingText; // Accumulated streaming text
  final String? searchStatusText; // Transient search trace status text
  final String? error;
  final double? uploadProgress; // Image upload progress (0.0 to 1.0)
  final String? pendingImagePath; // Image being uploaded

  const ChatState({
    this.messages = const [],
    this.isLoading = false,
    this.isSending = false,
    this.isStreaming = false,
    this.streamingText,
    this.searchStatusText,
    this.error,
    this.uploadProgress,
    this.pendingImagePath,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isLoading,
    bool? isSending,
    bool? isStreaming,
    String? streamingText,
    String? searchStatusText,
    String? error,
    double? uploadProgress,
    String? pendingImagePath,
    bool clearUpload = false,
    bool clearSearchStatus = false,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      isSending: isSending ?? this.isSending,
      isStreaming: isStreaming ?? this.isStreaming,
      streamingText: streamingText,
      searchStatusText: clearSearchStatus
          ? null
          : (searchStatusText ?? this.searchStatusText),
      error: error,
      uploadProgress: clearUpload
          ? null
          : (uploadProgress ?? this.uploadProgress),
      pendingImagePath: clearUpload
          ? null
          : (pendingImagePath ?? this.pendingImagePath),
    );
  }
}

/// Notifier for chat messages
class ChatNotifier extends StateNotifier<ChatState> {
  final IMessagesApi _messagesApi;
  final ISessionsApi _sessionsApi;
  final String sessionId;
  final Ref _ref;
  final UnifiedAnalyticsService _analytics;
  bool _isDisposed = false;

  ChatNotifier(
    this._messagesApi,
    this._sessionsApi,
    this.sessionId,
    this._ref,
    this._analytics,
  ) : super(const ChatState()) {
    _ref.onDispose(() {
      _isDisposed = true;
    });
  }

  /// The live device location (U) to attach to every outgoing chat message,
  /// for **both** guest and authed cohorts (design D7).
  ///
  /// The backend resolver uses it to honor "near me" and to let the chat
  /// search center (C) follow the user as they move; when the message names a
  /// place or reuses the session center, the backend ignores it. Previously
  /// authed sends passed `null` and the backend scoped on the tagged
  /// `current` location, so the picker-seeded center could never take effect —
  /// see PROD-3129. No auth branch: the value is always the last known fix.
  @visibleForTesting
  LocationSnapshot? chatOutgoingLocation() {
    return _ref.read(locationProvider).lastLocation;
  }

  /// Safely refresh memory provider, handling disposal during async operations
  void _safeRefreshMemory() {
    if (!mounted || _isDisposed) return;
    try {
      _ref.invalidate(memoryProvider);
      final locale = _ref.read(apiLocaleCodeProvider);
      _ref.read(memoryProvider.notifier).refresh(locale: locale);
    } catch (e) {
      debugPrint('[ChatProvider] Could not refresh memory (disposed): $e');
    }
  }

  /// Pushes the authoritative search center from a `getSession` read into
  /// sessions state, so a backend-driven recenter (e.g. "restaurants in
  /// Austin") updates the composer location label and map camera without a full
  /// sessions reload. [revisionAtStart] must be captured *before* the read so
  /// the notifier can defer to a fresher explicit picker commit.
  void _syncSearchCenter(
    SessionSearchCenter? searchCenter,
    int revisionAtStart,
  ) {
    if (!mounted || _isDisposed) return;
    try {
      _ref
          .read(sessionsProvider.notifier)
          .syncSessionSearchCenterFromServer(
            sessionId,
            searchCenter,
            sinceRevision: revisionAtStart,
          );
    } catch (e) {
      debugPrint('[ChatProvider] Could not sync search center (disposed): $e');
    }
  }

  /// Load messages for session
  Future<void> loadMessages() async {
    debugPrint('[ChatProvider] loadMessages called for session: $sessionId');
    state = state.copyWith(isLoading: true, error: null);

    try {
      // Get session detail which includes messages
      debugPrint('[ChatProvider] Fetching session from API...');
      final revisionAtStart = _ref
          .read(sessionsProvider.notifier)
          .searchCenterRevision;
      final result = await _sessionsApi.getSession(sessionId);
      debugPrint('[ChatProvider] Got ${result.messages.length} messages');
      state = state.copyWith(messages: result.messages, isLoading: false);
      _syncSearchCenter(result.session.searchCenter, revisionAtStart);
    } catch (e) {
      debugPrint('[ChatProvider] Error loading messages: $e');
      // Fall back to local cache if API fails
      final messages = _sessionsApi.getMessages(sessionId);
      state = state.copyWith(
        messages: messages,
        isLoading: false,
        error: messages.isEmpty ? e.toString() : null,
      );
    }
  }

  /// Send a text message with SSE streaming support
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    state = state.copyWith(isSending: true, error: null);

    try {
      // Optimistically add user message to UI
      final userMessage = ChatMessage.userText(text);
      _sessionsApi.addMessage(sessionId, userMessage);
      _refreshMessages();

      // Update session preview in sidebar
      _ref
          .read(sessionsProvider.notifier)
          .updateSession(
            sessionId,
            firstMessagePreview: text,
            lastMessageAt: DateTime.now(),
          );

      // Send to API and get message_id for streaming
      final locale = _ref.read(apiLocaleCodeProvider);
      final visitorId = _ref.read(attributionServiceProvider).cachedVisitorId;
      final response = await _messagesApi.sendTextMessage(
        sessionId,
        text,
        location: chatOutgoingLocation(),
        locale: locale,
        visitorId: visitorId,
      );
      final messageId = response.messageId;

      // Track user message sent (Firebase + Backend - new split endpoint)
      await _analytics.trackMessageSentUser(
        messageType: MessageType.text,
        sessionId: sessionId,
        turnIndex: state.messages.length,
      );

      // Switch to streaming mode (clear stale search status from previous query)
      state = state.copyWith(
        isSending: false,
        isStreaming: true,
        streamingText: null,
        clearSearchStatus: true,
      );

      // Stream response via SSE - supports both new 'message' events and legacy 'chunk' events
      List<ItemSuggestion>? itemSuggestions;
      int messageCount = 0;

      print('[ChatProvider] Starting SSE stream for message $messageId');
      await for (final event in _messagesApi.streamMessageResponse(
        sessionId,
        messageId,
      )) {
        print('[ChatProvider] Received event: type=${event.type}');
        if (event.isStatus) {
          // Search trace status — update transient status text
          print(
            '[ChatProvider] Search status: step=${event.statusStepName}, status=${event.statusStatus}',
          );
          state = state.copyWith(searchStatusText: event.text);
          continue;
        } else if (event.isMessage) {
          // Don't clear searchStatusText here — let it persist until isDone
          // so the indicator doesn't flash back to dots between last status and done.
          // New structured message event - add RichMessage as assistant message
          final richMessage = event.richMessage!;
          messageCount++;
          print(
            '[ChatProvider] Adding rich message $messageCount: type=${richMessage.type}',
          );
          final assistantMessage = ChatMessage.assistantRich(richMessage);
          _sessionsApi.addMessage(sessionId, assistantMessage);
          _refreshMessages();
          // Track each Soko message individually with actual rich message type
        } else if (event.isChunk) {
          // Legacy text chunk - add as separate assistant message bubble
          final chunkText = event.text ?? '';
          if (chunkText.isNotEmpty) {
            messageCount++;
            print(
              '[ChatProvider] Adding legacy chunk $messageCount: ${chunkText.length} chars',
            );
            final chunkMessage = ChatMessage.assistantText(chunkText);
            _sessionsApi.addMessage(sessionId, chunkMessage);
            _refreshMessages();
          }
        } else if (event.isDone) {
          // Done event - may contain richMessages array or legacy itemSuggestions
          print(
            '[ChatProvider] Done event, richMessages=${event.richMessages?.length ?? 0}, itemSuggestions=${event.itemSuggestions?.length ?? 0}',
          );

          // Handle rich messages in done event (webapp channel)
          // Only process if no individual message events were received (avoid duplicates)
          if (messageCount == 0 &&
              event.richMessages != null &&
              event.richMessages!.isNotEmpty) {
            for (final richMessage in event.richMessages!) {
              messageCount++;
              print(
                '[ChatProvider] Adding rich message from done: type=${richMessage.type}',
              );
              final assistantMessage = ChatMessage.assistantRich(
                richMessage,
                language: event.language,
              );
              _sessionsApi.addMessage(sessionId, assistantMessage);
            }
            _refreshMessages();
          }

          // Handle legacy: attach place suggestions to the last message
          itemSuggestions = event.itemSuggestions;
          if (messageCount == 0 && (event.text?.isNotEmpty ?? false)) {
            // No messages received - add the full response as a message
            final finalMessage = ChatMessage.assistantText(
              event.text!,
              places: itemSuggestions,
              language: event.language,
            );
            _sessionsApi.addMessage(sessionId, finalMessage);
            _refreshMessages();
          } else if (messageCount > 0 &&
              itemSuggestions != null &&
              itemSuggestions.isNotEmpty) {
            // Messages were received - update the last message with place suggestions
            final messages = _sessionsApi.getMessages(sessionId);
            if (messages.isNotEmpty) {
              final lastMessage = messages.last;
              // Replace last message with one that includes place suggestions
              final updatedMessage = ChatMessage.assistantText(
                lastMessage.displayText ?? '',
                places: itemSuggestions,
                language: event.language,
              );
              _sessionsApi.updateLastMessage(sessionId, updatedMessage);
              _refreshMessages();
              print(
                '[ChatProvider] Updated last message with ${itemSuggestions.length} place suggestions',
              );
            }
          }
          break;
        } else if (event.isError) {
          print('[ChatProvider] Error event: ${event.errorMessage}');
          state = state.copyWith(
            isStreaming: false,
            streamingText: null,
            clearSearchStatus: true,
            error: event.errorMessage,
          );
          return;
        }
      }
      print(
        '[ChatProvider] SSE stream completed, $messageCount messages received',
      );

      // Track Soko response (PostHog only, with session_id)
      if (messageCount > 0) {
        await _analytics.trackMessageSentSoko(sessionId: sessionId);
      }

      // Clear streaming state
      state = state.copyWith(
        isStreaming: false,
        streamingText: null,
        clearSearchStatus: true,
      );

      // Clear local cache - API now persists streaming chunks in DB, so on
      // next load the API will return the same separated messages. Local cache
      // is only used during streaming for immediate UI feedback.
      _sessionsApi.clearMessages(sessionId);

      // Fetch messages from API to ensure state matches what's persisted
      // (including the user message which was also saved by the backend)
      await _fetchMessages();

      // Refresh memories as the AI may have learned something new
      _safeRefreshMemory();
    } catch (e) {
      // SSE or send failed - try to recover by fetching from API
      state = state.copyWith(
        isSending: false,
        isStreaming: false,
        streamingText: null,
        clearSearchStatus: true,
      );

      // Try to fetch messages from API as fallback
      try {
        await _fetchMessages();
      } catch (_) {
        // If that fails too, show the original error
        state = state.copyWith(error: e.toString());
      }
    }
  }

  /// Send an image message with optimistic UI updates
  Future<void> sendImage(String imagePath, {String? caption}) async {
    debugPrint('[ChatProvider] sendImage called with path: $imagePath');
    state = state.copyWith(
      isSending: true,
      error: null,
      pendingImagePath: imagePath,
      uploadProgress: 0.0,
    );

    try {
      // Optimistically add user image message to UI
      final userMessage = ChatMessage.userImage(imagePath, caption: caption);
      _sessionsApi.addMessage(sessionId, userMessage);
      _refreshMessages();
      debugPrint('[ChatProvider] Added optimistic image message to UI');

      // Update session preview in sidebar
      _ref
          .read(sessionsProvider.notifier)
          .updateSession(
            sessionId,
            firstMessagePreview: caption ?? '📷 Image',
            lastMessageAt: DateTime.now(),
          );

      // Simulate upload progress (actual progress would require API changes)
      // For now, we show indeterminate progress by setting to null after start
      state = state.copyWith(uploadProgress: null);

      // Send to API
      debugPrint('[ChatProvider] Calling messagesApi.sendImageMessage...');
      final locale = _ref.read(apiLocaleCodeProvider);
      final response = await _messagesApi.sendImageMessage(
        sessionId,
        imagePath: imagePath,
        caption: caption,
        location: chatOutgoingLocation(),
        locale: locale,
      );
      final messageId = response.messageId;
      debugPrint(
        '[ChatProvider] sendImageMessage completed, messageId: $messageId',
      );

      // Track user image message sent (Firebase + Backend - new split endpoint)
      await _analytics.trackMessageSentUser(
        messageType: MessageType.image,
        sessionId: sessionId,
        turnIndex: state.messages.length,
      );

      // Clear upload state and switch to streaming mode
      state = state.copyWith(
        isSending: false,
        isStreaming: true,
        streamingText: null,
        clearUpload: true,
      );

      // Stream response via SSE - supports both new 'message' events and legacy 'chunk' events
      List<ItemSuggestion>? itemSuggestions;
      int messageCount = 0;

      debugPrint(
        '[ChatProvider] Starting SSE stream for image message $messageId',
      );
      await for (final event in _messagesApi.streamMessageResponse(
        sessionId,
        messageId,
      )) {
        debugPrint('[ChatProvider] Received event: type=${event.type}');
        if (event.isMessage) {
          // New structured message event
          final richMessage = event.richMessage!;
          messageCount++;
          debugPrint(
            '[ChatProvider] Adding rich message $messageCount: type=${richMessage.type}',
          );
          final assistantMessage = ChatMessage.assistantRich(richMessage);
          _sessionsApi.addMessage(sessionId, assistantMessage);
          _refreshMessages();
        } else if (event.isChunk) {
          // Legacy text chunk
          final chunkText = event.text ?? '';
          if (chunkText.isNotEmpty) {
            messageCount++;
            debugPrint(
              '[ChatProvider] Adding legacy chunk $messageCount: ${chunkText.length} chars',
            );
            final chunkMessage = ChatMessage.assistantText(chunkText);
            _sessionsApi.addMessage(sessionId, chunkMessage);
            _refreshMessages();
          }
        } else if (event.isDone) {
          debugPrint(
            '[ChatProvider] Done event, richMessages=${event.richMessages?.length ?? 0}, itemSuggestions=${event.itemSuggestions?.length ?? 0}',
          );

          // Handle rich messages in done event
          // Only process if no individual message events were received (avoid duplicates)
          if (messageCount == 0 &&
              event.richMessages != null &&
              event.richMessages!.isNotEmpty) {
            for (final richMessage in event.richMessages!) {
              messageCount++;
              final assistantMessage = ChatMessage.assistantRich(
                richMessage,
                language: event.language,
              );
              _sessionsApi.addMessage(sessionId, assistantMessage);
            }
            _refreshMessages();
          }

          itemSuggestions = event.itemSuggestions;
          if (messageCount == 0 && (event.text?.isNotEmpty ?? false)) {
            final finalMessage = ChatMessage.assistantText(
              event.text!,
              places: itemSuggestions,
              language: event.language,
            );
            _sessionsApi.addMessage(sessionId, finalMessage);
            _refreshMessages();
          } else if (messageCount > 0 &&
              itemSuggestions != null &&
              itemSuggestions.isNotEmpty) {
            final messages = _sessionsApi.getMessages(sessionId);
            if (messages.isNotEmpty) {
              final lastMessage = messages.last;
              final updatedMessage = ChatMessage.assistantText(
                lastMessage.displayText ?? '',
                places: itemSuggestions,
                language: event.language,
              );
              _sessionsApi.updateLastMessage(sessionId, updatedMessage);
              _refreshMessages();
              debugPrint(
                '[ChatProvider] Updated last message with ${itemSuggestions.length} place suggestions',
              );
            }
          }
          break;
        } else if (event.isError) {
          debugPrint('[ChatProvider] Error event: ${event.errorMessage}');
          state = state.copyWith(
            isStreaming: false,
            streamingText: null,
            clearSearchStatus: true,
            error: event.errorMessage,
          );
          return;
        }
      }
      debugPrint(
        '[ChatProvider] SSE stream completed, $messageCount messages received',
      );

      // Track Soko response (PostHog only, with session_id)
      if (messageCount > 0) {
        await _analytics.trackMessageSentSoko(sessionId: sessionId);
      }

      // Clear streaming state
      state = state.copyWith(
        isStreaming: false,
        streamingText: null,
        clearSearchStatus: true,
      );

      // NOTE: For image messages, we DON'T clear local cache and refetch from API
      // because the backend doesn't store/return media_url. The local cache
      // already has the correct user image message with the blob URL and
      // the assistant response chunks from streaming.
      // Just refresh from local cache to ensure UI is in sync.
      _refreshMessages();

      // Refresh memories
      _safeRefreshMemory();
    } catch (e, stackTrace) {
      debugPrint('[ChatProvider] sendImage error: $e');
      debugPrint('[ChatProvider] Stack trace: $stackTrace');
      state = state.copyWith(
        isSending: false,
        isStreaming: false,
        streamingText: null,
        clearUpload: true,
        clearSearchStatus: true,
      );

      // Try to fetch messages from API as fallback
      try {
        await _fetchMessages();
      } catch (_) {
        state = state.copyWith(error: e.toString());
      }
    }
  }

  /// Send a voice message with SSE streaming support
  /// Note: Backend now supports SSE streaming for voice messages (same as text).
  /// The only difference is the initial transcription step on the backend.
  Future<void> sendVoice(String audioPath, {String? transcriptHint}) async {
    debugPrint('[ChatProvider] sendVoice called with path: $audioPath');
    state = state.copyWith(isSending: true, error: null);

    try {
      // Optimistically add user voice message to UI
      final userMessage = ChatMessage.userVoice();
      _sessionsApi.addMessage(sessionId, userMessage);
      _refreshMessages();
      debugPrint('[ChatProvider] Added optimistic voice message to UI');

      // Update session preview in sidebar
      _ref
          .read(sessionsProvider.notifier)
          .updateSession(
            sessionId,
            firstMessagePreview: '🎤 Voice message',
            lastMessageAt: DateTime.now(),
          );

      // Send to API and get message_id for streaming
      debugPrint('[ChatProvider] Calling messagesApi.sendVoiceMessage...');
      final locale = _ref.read(apiLocaleCodeProvider);
      final response = await _messagesApi.sendVoiceMessage(
        sessionId,
        audioPath: audioPath,
        transcriptHint: transcriptHint,
        location: chatOutgoingLocation(),
        locale: locale,
      );
      final messageId = response.messageId;
      debugPrint(
        '[ChatProvider] sendVoiceMessage completed, messageId: $messageId',
      );

      // Track user voice message sent (Firebase + Backend - new split endpoint)
      await _analytics.trackMessageSentUser(
        messageType: MessageType.voice,
        sessionId: sessionId,
        turnIndex: state.messages.length,
      );

      // Switch to streaming mode
      state = state.copyWith(
        isSending: false,
        isStreaming: true,
        streamingText: null,
      );

      // Stream response via SSE - supports both new 'message' events and legacy 'chunk' events
      List<ItemSuggestion>? itemSuggestions;
      int messageCount = 0;

      print('[ChatProvider] Starting SSE stream for voice message $messageId');
      await for (final event in _messagesApi.streamMessageResponse(
        sessionId,
        messageId,
      )) {
        print('[ChatProvider] Received event: type=${event.type}');
        if (event.isMessage) {
          // New structured message event
          final richMessage = event.richMessage!;
          messageCount++;
          print(
            '[ChatProvider] Adding rich message $messageCount: type=${richMessage.type}',
          );
          final assistantMessage = ChatMessage.assistantRich(richMessage);
          _sessionsApi.addMessage(sessionId, assistantMessage);
          _refreshMessages();
        } else if (event.isChunk) {
          // Legacy text chunk
          final chunkText = event.text ?? '';
          if (chunkText.isNotEmpty) {
            messageCount++;
            print(
              '[ChatProvider] Adding legacy chunk $messageCount: ${chunkText.length} chars',
            );
            final chunkMessage = ChatMessage.assistantText(chunkText);
            _sessionsApi.addMessage(sessionId, chunkMessage);
            _refreshMessages();
          }
        } else if (event.isDone) {
          print(
            '[ChatProvider] Done event, richMessages=${event.richMessages?.length ?? 0}, itemSuggestions=${event.itemSuggestions?.length ?? 0}',
          );

          // Handle rich messages in done event
          // Only process if no individual message events were received (avoid duplicates)
          if (messageCount == 0 &&
              event.richMessages != null &&
              event.richMessages!.isNotEmpty) {
            for (final richMessage in event.richMessages!) {
              messageCount++;
              final assistantMessage = ChatMessage.assistantRich(
                richMessage,
                language: event.language,
              );
              _sessionsApi.addMessage(sessionId, assistantMessage);
            }
            _refreshMessages();
          }

          itemSuggestions = event.itemSuggestions;
          if (messageCount == 0 && (event.text?.isNotEmpty ?? false)) {
            final finalMessage = ChatMessage.assistantText(
              event.text!,
              places: itemSuggestions,
              language: event.language,
            );
            _sessionsApi.addMessage(sessionId, finalMessage);
            _refreshMessages();
          } else if (messageCount > 0 &&
              itemSuggestions != null &&
              itemSuggestions.isNotEmpty) {
            final messages = _sessionsApi.getMessages(sessionId);
            if (messages.isNotEmpty) {
              final lastMessage = messages.last;
              final updatedMessage = ChatMessage.assistantText(
                lastMessage.displayText ?? '',
                places: itemSuggestions,
                language: event.language,
              );
              _sessionsApi.updateLastMessage(sessionId, updatedMessage);
              _refreshMessages();
              print(
                '[ChatProvider] Updated last message with ${itemSuggestions.length} place suggestions',
              );
            }
          }
          break;
        } else if (event.isError) {
          print('[ChatProvider] Error event: ${event.errorMessage}');
          state = state.copyWith(
            isStreaming: false,
            streamingText: null,
            clearSearchStatus: true,
            error: event.errorMessage,
          );
          return;
        }
      }
      print(
        '[ChatProvider] SSE stream completed, $messageCount messages received',
      );

      // Track Soko response (PostHog only, with session_id)
      if (messageCount > 0) {
        await _analytics.trackMessageSentSoko(sessionId: sessionId);
      }

      // Clear streaming state
      state = state.copyWith(
        isStreaming: false,
        streamingText: null,
        clearSearchStatus: true,
      );

      // Clear local cache - API now persists streaming chunks in DB, so on
      // next load the API will return the same separated messages. Local cache
      // is only used during streaming for immediate UI feedback.
      _sessionsApi.clearMessages(sessionId);

      // Fetch messages from API to ensure state matches what's persisted
      // (including the user message which was also saved by the backend)
      await _fetchMessages();

      // Refresh memories as the AI may have learned something new
      _safeRefreshMemory();
    } catch (e, stackTrace) {
      debugPrint('[ChatProvider] sendVoice error: $e');
      debugPrint('[ChatProvider] Stack trace: $stackTrace');
      // SSE or send failed - try to recover by fetching from API
      state = state.copyWith(
        isSending: false,
        isStreaming: false,
        streamingText: null,
        clearSearchStatus: true,
      );

      // Try to fetch messages from API as fallback
      try {
        await _fetchMessages();
      } catch (_) {
        // If that fails too, show the original error
        state = state.copyWith(error: e.toString());
      }
    }
  }

  /// Refresh messages from local cache
  void _refreshMessages() {
    final messages = _sessionsApi.getMessages(sessionId);
    state = state.copyWith(messages: List.from(messages));
  }

  /// Fetch messages from API
  Future<void> _fetchMessages() async {
    try {
      final revisionAtStart = _ref
          .read(sessionsProvider.notifier)
          .searchCenterRevision;
      final result = await _sessionsApi.getSession(sessionId);
      state = state.copyWith(messages: result.messages);
      _syncSearchCenter(result.session.searchCenter, revisionAtStart);
    } catch (e) {
      // Fall back to local cache
      _refreshMessages();
    }
  }

  /// Start polling for messages (for real-time updates)
  void startPolling() {
    // In a real app, this would use WebSocket or SSE
    // For now, we just refresh periodically
  }
}

/// Provider for chat state, keyed by session ID
final chatProvider =
    StateNotifierProvider.family<ChatNotifier, ChatState, String>((
      ref,
      sessionId,
    ) {
      final messagesApi = ref.watch(messagesApiProvider);
      final sessionsApi = ref.watch(sessionsApiProvider);
      final analytics = ref.watch(unifiedAnalyticsProvider);
      final notifier = ChatNotifier(
        messagesApi,
        sessionsApi,
        sessionId,
        ref,
        analytics,
      );
      // Don't auto-load messages - let caller decide when to load
      // This prevents a race condition when creating new sessions where
      // loadMessages() would overwrite optimistic messages from sendMessage()
      return notifier;
    });

/// State for message starters with local caching
class MessageStartersState {
  final List<MessageStarter> starters;
  final bool isLoading;
  final bool isRefreshing; // Background refresh in progress

  const MessageStartersState({
    this.starters = const [],
    this.isLoading =
        true, // Start with loading=true to show skeletons until initialized
    this.isRefreshing = false,
  });

  MessageStartersState copyWith({
    List<MessageStarter>? starters,
    bool? isLoading,
    bool? isRefreshing,
  }) {
    return MessageStartersState(
      starters: starters ?? this.starters,
      isLoading: isLoading ?? this.isLoading,
      isRefreshing: isRefreshing ?? this.isRefreshing,
    );
  }

  bool get hasData => starters.isNotEmpty;
}

/// Notifier for message starters with local caching and background refresh
class MessageStartersNotifier extends StateNotifier<MessageStartersState> {
  final IMessagesApi _api;
  final StorageService _storage;
  bool _initialized = false;

  MessageStartersNotifier(this._api, this._storage)
    : super(const MessageStartersState()) {
    // Auto-initialize on creation - load cache synchronously
    _initializeSync();
  }

  /// Synchronous initialization - loads cache immediately on provider creation
  void _initializeSync() {
    final cached = _storage.loadMessageStarters();
    print(
      '[MessageStarters] _initializeSync: cached=${cached.length} starters',
    );
    if (cached.isNotEmpty) {
      print(
        '[MessageStarters] _initializeSync: first cached="${cached.first.text}"',
      );
      // Have cache - show it immediately, no loading state
      state = MessageStartersState(
        starters: cached,
        isLoading: false,
        isRefreshing: false,
      );
    }
    // If no cache, keep isLoading=true (default state)
  }

  /// Initialize async part - check staleness and refresh if needed
  Future<void> initialize() async {
    print('[MessageStarters] initialize: _initialized=$_initialized');
    if (_initialized) return;
    _initialized = true;

    // Check if we need to refresh (stale cache or no cache)
    final isStale = _storage.isMessageStartersCacheStale();
    print(
      '[MessageStarters] initialize: isStale=$isStale, hasData=${state.hasData}',
    );
    if (isStale || !state.hasData) {
      print('[MessageStarters] initialize: will refresh from API');
      await _refreshFromApi();
    } else {
      print(
        '[MessageStarters] initialize: using cached data, no refresh needed',
      );
    }
  }

  /// Force refresh from API (e.g., after locale change)
  Future<void> refresh() async {
    print('[MessageStarters] refresh: forcing API refresh');
    _initialized = false;
    await _refreshFromApi();
  }

  /// Fetch fresh starters from API and update cache
  Future<void> _refreshFromApi() async {
    print('[MessageStarters] _refreshFromApi: starting...');
    // If we have cached data, show "refreshing" state (not blocking loading)
    // If no cached data, isLoading is already true from initial state
    if (state.hasData) {
      state = state.copyWith(isRefreshing: true);
    }

    try {
      final freshStarters = await _api.getMessageStarters();

      // Update state and cache
      state = state.copyWith(
        starters: freshStarters,
        isLoading: false,
        isRefreshing: false,
      );

      // Persist to local storage
      await _storage.saveMessageStarters(freshStarters);
    } catch (e) {
      print('[MessageStarters] API error: $e');
      // On error, keep showing cached data (if any)
      // Just clear the loading/refreshing state
      state = state.copyWith(isLoading: false, isRefreshing: false);
    }
  }
}

/// Provider for message starters with local caching
/// Pre-fetch this after auth to ensure instant display when user opens new chat
final messageStartersProvider =
    StateNotifierProvider<MessageStartersNotifier, MessageStartersState>((ref) {
      final api = ref.watch(messagesApiProvider);
      final storage = ref.watch(storageServiceProvider);
      return MessageStartersNotifier(api, storage);
    });
