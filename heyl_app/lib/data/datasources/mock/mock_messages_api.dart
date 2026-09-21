import 'dart:math';

import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'mock_data.dart';
import 'mock_sessions_api.dart';

/// Mock implementation of Messages API
class MockMessagesApi implements IMessagesApi {
  final MockSessionsApi _sessionsApi;
  final _random = Random();

  MockMessagesApi(this._sessionsApi);

  /// Get message starters
  Future<List<MessageStarter>> getMessageStarters({String? context}) async {
    await _simulateDelay(milliseconds: 200);
    return MockData.mockMessageStarters;
  }

  /// Send a text message and get AI response
  Future<MessageAcceptedResponse> sendTextMessage(
    String sessionId,
    String text, {
    LocationSnapshot? location,
    String? locale,
    String? visitorId,
  }) async {
    await _simulateDelay(milliseconds: 100);

    // Add user message
    final userMessage = ChatMessage.userText(text);
    _sessionsApi.addMessage(sessionId, userMessage);

    // Simulate AI thinking and responding
    Future.delayed(const Duration(milliseconds: 800), () {
      final response = _generateAIResponse(text);
      _sessionsApi.addMessage(sessionId, response);
    });

    return MessageAcceptedResponse(
      messageId: userMessage.messageId,
      status: 'queued',
      sessionId: sessionId,
    );
  }

  /// Send an image message
  Future<MessageAcceptedResponse> sendImageMessage(
    String sessionId, {
    required String imagePath,
    String? caption,
    LocationSnapshot? location,
    String? locale,
  }) async {
    await _simulateDelay(milliseconds: 500);

    final userMessage = ChatMessage(
      messageId: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      role: MessageRole.user,
      userMessageType: UserMessageType.image,
      text: caption,
      mediaUrl: imagePath,
      createdAt: DateTime.now(),
    );

    _sessionsApi.addMessage(sessionId, userMessage);

    // Simulate AI response
    Future.delayed(const Duration(seconds: 1), () {
      final response = ChatMessage.assistantText(
        'Nice! I can see the image. Let me find some related places for you.',
        places: MockData.mockItemSuggestions.take(2).toList(),
      );
      _sessionsApi.addMessage(sessionId, response);
    });

    return MessageAcceptedResponse(
      messageId: userMessage.messageId,
      status: 'queued',
      sessionId: sessionId,
    );
  }

  /// Send a voice message
  Future<MessageAcceptedResponse> sendVoiceMessage(
    String sessionId, {
    required String audioPath,
    String? transcriptHint,
    LocationSnapshot? location,
    String? locale,
  }) async {
    await _simulateDelay(milliseconds: 500);

    final userMessage = ChatMessage(
      messageId: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      role: MessageRole.user,
      userMessageType: UserMessageType.voice,
      mediaUrl: audioPath,
      createdAt: DateTime.now(),
    );

    _sessionsApi.addMessage(sessionId, userMessage);

    // Simulate transcription and response
    Future.delayed(const Duration(seconds: 2), () {
      final response = ChatMessage.assistantText(
        'I heard you! Let me process that and find some recommendations.',
      );
      _sessionsApi.addMessage(sessionId, response);
    });

    return MessageAcceptedResponse(
      messageId: userMessage.messageId,
      status: 'queued',
      sessionId: sessionId,
    );
  }

  /// Generate AI response based on user message
  ChatMessage _generateAIResponse(String userText) {
    final lowerText = userText.toLowerCase();

    // Restaurant-related queries
    if (lowerText.contains('restaurant') ||
        lowerText.contains('food') ||
        lowerText.contains('eat')) {
      return ChatMessage.assistantText(
        'I love helping with food choices! Here are some great options for you:',
        places: MockData.mockItemSuggestions
            .where((p) =>
                p.tags.any((t) => t.toLowerCase().contains('food') ||
                    t.toLowerCase().contains('wine') ||
                    t.toLowerCase().contains('romantic')))
            .take(3)
            .toList(),
      );
    }

    // Music-related queries
    if (lowerText.contains('music') ||
        lowerText.contains('jazz') ||
        lowerText.contains('concert') ||
        lowerText.contains('live')) {
      return ChatMessage.assistantText(
        'Great taste! Here are some live music spots I think you\'ll love:',
        places: MockData.mockItemSuggestions
            .where((p) => p.tags.any((t) => t.toLowerCase().contains('music')))
            .take(3)
            .toList(),
      );
    }

    // Date-related queries
    if (lowerText.contains('date') || lowerText.contains('romantic')) {
      return ChatMessage.assistantText(
        'I know just the spots for a perfect date night:',
        places: MockData.mockItemSuggestions.take(3).toList(),
      );
    }

    // Weekend queries
    if (lowerText.contains('weekend') || lowerText.contains('happening')) {
      return ChatMessage.assistantText(
        'Here\'s what\'s happening this weekend that I think you\'d enjoy:',
        places: MockData.mockItemSuggestions
            .where((p) => p.type == 'event')
            .take(3)
            .toList(),
      );
    }

    // Running/exercise queries
    if (lowerText.contains('run') ||
        lowerText.contains('exercise') ||
        lowerText.contains('yoga')) {
      return ChatMessage.assistantText(
        'Great that you\'re staying active! Here are some options near you:',
        places: [
          ItemSuggestion(
            id: 'running_1',
            name: 'Lisbon Runners Club',
            imageUrl: 'https://images.unsplash.com/photo-1571008887538-b36bb32f4571?w=400',
            tags: ['Running', 'Group', 'Free'],
            type: 'event',
          ),
        ],
      );
    }

    // Default response
    final responses = [
      'Let me find something great for you!',
      'I\'ve got some ideas for you.',
      'Here are some suggestions based on what I know you like:',
      'I think you\'ll enjoy these:',
    ];

    return ChatMessage.assistantText(
      responses[_random.nextInt(responses.length)],
      places: MockData.mockItemSuggestions.take(2).toList(),
    );
  }

  Future<void> _simulateDelay({int milliseconds = 300}) async {
    await Future.delayed(Duration(milliseconds: milliseconds));
  }

  /// Stream message response (mock SSE simulation)
  @override
  Stream<MessageStreamEvent> streamMessageResponse(
    String sessionId,
    String messageId,
  ) async* {
    // Simulate streaming delay
    await _simulateDelay(milliseconds: 500);

    // Simulate text chunks
    final chunks = [
      'Let me check what\'s happening nearby...',
      '\n\nI found some great options for you!',
      '\n\nHere are my top picks:',
    ];

    for (var i = 0; i < chunks.length; i++) {
      await _simulateDelay(milliseconds: 300);
      yield MessageStreamEvent(
        type: MessageStreamEventType.chunk,
        text: chunks[i],
        sequence: i,
      );
    }

    // Simulate final message with place suggestions
    await _simulateDelay(milliseconds: 200);
    yield MessageStreamEvent(
      type: MessageStreamEventType.done,
      text: '',
      itemSuggestions: MockData.mockItemSuggestions.take(3).toList(),
    );
  }
}
