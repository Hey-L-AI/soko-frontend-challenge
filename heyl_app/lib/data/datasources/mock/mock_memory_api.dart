import 'dart:convert';

import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'mock_data.dart';

/// Mock implementation of User Memory API
class MockMemoryApi implements IMemoryApi {
  final UserMemory _memory = MockData.mockUserMemory;
  final List<MemoryItem> _memoryItems = List.from(MockData.mockMemoryItems);

  // Track polling calls for non-English locales
  int _translationPollCount = 0;
  static const _pendingCallsBeforeReady = 3;

  // Track cached locale for consistency with real API
  String? _cachedLocale;

  /// Get user memory
  @override
  Future<UserMemory> getMemory({String? locale}) async {
    await _simulateDelay();
    _cachedLocale = locale;

    // Simulate translation polling for non-English locales
    if (locale != null && locale != 'en' && !locale.startsWith('en')) {
      _translationPollCount++;

      // Return pending for the first few calls, then ready
      if (_translationPollCount <= _pendingCallsBeforeReady) {
        return _memory.copyWith(
          translationStatus: TranslationStatus.pending,
        );
      } else {
        // Reset counter after ready
        _translationPollCount = 0;
        return _memory.copyWith(
          translationStatus: TranslationStatus.ready,
        );
      }
    }

    // English locale or no locale - always ready
    _translationPollCount = 0;
    return _memory;
  }

  /// Get memory items for display
  @override
  Future<List<MemoryItem>> getMemoryItems({String? locale}) async {
    await _simulateDelay(milliseconds: 200);
    return List.from(_memoryItems);
  }

  /// Get memory items by category
  Future<Map<MemoryCategory, List<MemoryItem>>> getMemoryItemsByCategory() async {
    await _simulateDelay(milliseconds: 200);

    final grouped = <MemoryCategory, List<MemoryItem>>{};
    for (final category in MemoryCategory.values) {
      grouped[category] = _memoryItems
          .where((m) => m.category == category)
          .toList();
    }
    return grouped;
  }

  /// Delete a memory item
  @override
  Future<MessageResponse> deleteMemoryItem(MemoryItemDeleteRequest request) async {
    await _simulateDelay();

    if (request.itemType == 'fact' && request.factIndex != null) {
      if (request.factIndex! < _memoryItems.length) {
        _memoryItems.removeAt(request.factIndex!);
      }
    } else if (request.itemType == 'all_facts') {
      _memoryItems.clear();
    }

    return const MessageResponse(message: 'Removed');
  }

  /// Ingest memory from conversation
  Future<MessageResponse> ingestMemory(MemoryIngestRequest request) async {
    await _simulateDelay(milliseconds: 500);

    // In a real implementation, this would process the conversation
    // and extract facts. For mock, we just acknowledge it.
    return const MessageResponse(message: 'Memory update queued');
  }

  /// Add a memory item (internal helper for testing)
  void addMemoryItem(MemoryItem item) {
    _memoryItems.add(item);
  }

  /// Get memory count
  int get memoryCount => _memoryItems.length;

  /// Clear cached data (call on logout)
  @override
  void clearCache() {
    _cachedLocale = null;
    _translationPollCount = 0;
  }

  /// Export memory as markdown bytes
  @override
  Future<List<int>> exportMemory({String? locale}) async {
    await _simulateDelay();

    final markdown = StringBuffer();

    // Add locale-specific title
    final title = _getLocalizedString('title', locale);
    markdown.writeln('# $title');
    markdown.writeln();

    if (_memory.memoryText != null && _memory.memoryText!.isNotEmpty) {
      final aboutMe = _getLocalizedString('aboutMe', locale);
      markdown.writeln('## $aboutMe');
      markdown.writeln(_memory.memoryText);
      markdown.writeln();
    }

    if (_memoryItems.isNotEmpty) {
      final keyFacts = _getLocalizedString('keyFacts', locale);
      markdown.writeln('## $keyFacts');
      for (final item in _memoryItems) {
        markdown.writeln('- ${item.text}');
      }
      markdown.writeln();
    }

    return utf8.encode(markdown.toString());
  }

  /// Helper to return locale-specific strings for mock export
  String _getLocalizedString(String key, String? locale) {
    final isPtBr = locale == 'pt-BR';
    final isPt = locale == 'pt' || isPtBr;

    switch (key) {
      case 'title':
        return isPt ? 'O Meu Perfil de Memória' : 'My Memory Profile';
      case 'aboutMe':
        return isPt ? 'Sobre Mim' : 'About Me';
      case 'keyFacts':
        return isPt ? 'Factos Principais' : 'Key Facts';
      default:
        return key;
    }
  }

  Future<void> _simulateDelay({int milliseconds = 300}) async {
    await Future.delayed(Duration(milliseconds: milliseconds));
  }
}
