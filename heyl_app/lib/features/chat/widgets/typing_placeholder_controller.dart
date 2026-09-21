import 'dart:async';

import 'package:flutter/foundation.dart';

/// Controller that drives a typewriter animation through a list of phrases.
///
/// Exposes [displayText] for the main placeholder and [displayPhrases] for
/// desktop fading prompts. Uses a generation counter pattern (from PROD-782)
/// to prevent stale timer callbacks after restart or dispose.
class TypingPlaceholderController extends ChangeNotifier {
  TypingPlaceholderController(List<String> phrases) : _phrases = phrases {
    _startNextPhrase();
  }

  List<String> _phrases;

  // Generation counter — incremented on restart/dispose to invalidate timers
  int _generation = 0;

  // Current state
  String _currentText = '';
  int _phraseIndex = 0;
  int _charIndex = 0;
  bool _isDeleting = false;
  Timer? _timer;

  // Pause/resume (P4/P5)
  bool _isPaused = false;

  // Hover override (P4)
  String? _overrideText;

  /// Whether the controller is currently paused.
  bool get isPaused => _isPaused;

  /// The text to display in the placeholder.
  /// Returns the hover override if set, otherwise the current typed text.
  String get displayText => _overrideText ?? _currentText;

  /// The current partially-typed text (without override).
  String get currentText => _currentText;

  /// The index of the phrase currently being typed (for animation keying).
  int get phraseIndex => _phraseIndex;

  /// The full phrase currently being typed.
  String get currentPhrase =>
      _phrases.isEmpty ? '' : _phrases[_phraseIndex % _phrases.length];

  /// Next 3 phrases after the one being typed, for desktop fading prompts.
  /// Index 0 = the phrase that will become the placeholder next, 1-2 = upcoming.
  /// This avoids duplicating the currently-typed phrase in the fading prompts.
  List<String> get displayPhrases {
    if (_phrases.isEmpty) return [];
    final result = <String>[];
    for (var i = 1; i <= 3; i++) {
      result.add(_phrases[(_phraseIndex + i) % _phrases.length]);
    }
    return result;
  }

  /// Pause the typing animation (P4 hover, P5 user typing).
  void pause() {
    _isPaused = true;
    _timer?.cancel();
  }

  /// Resume the typing animation (P4 hover exit, P5 user clears text).
  void resume() {
    if (!_isPaused) return;
    _isPaused = false;
    _typeNext();
  }

  /// Set an override text for hover preview (P4).
  void setOverrideText(String text) {
    _overrideText = text;
    notifyListeners();
  }

  /// Clear the hover override (P4).
  void clearOverride() {
    if (_overrideText == null) return;
    _overrideText = null;
    notifyListeners();
  }

  /// Restart the animation with new phrases (e.g., on locale change).
  void restart(List<String> newPhrases) {
    _generation++;
    _timer?.cancel();
    _phrases = newPhrases;
    _phraseIndex = 0;
    _charIndex = 0;
    _isDeleting = false;
    _isPaused = false;
    _overrideText = null;
    _currentText = '';
    notifyListeners();
    _startNextPhrase();
  }

  void _startNextPhrase() {
    final gen = _generation;
    _schedule(const Duration(milliseconds: 400), () {
      if (_generation != gen) return;
      _typeNext();
    });
  }

  void _typeNext() {
    if (_isPaused) return;
    if (_phrases.isEmpty) return;
    final gen = _generation;
    final phrase = _phrases[_phraseIndex % _phrases.length];

    if (!_isDeleting) {
      // Typing forward
      _charIndex++;
      _currentText = phrase.substring(0, _charIndex.clamp(0, phrase.length));
      notifyListeners();

      if (_charIndex >= phrase.length) {
        // Finished typing — pause then start deleting
        _schedule(const Duration(milliseconds: 2000), () {
          if (_generation != gen) return;
          _isDeleting = true;
          _typeNext();
        });
        return;
      }

      // Next char at constant 50ms (P2)
      _schedule(const Duration(milliseconds: 50), () {
        if (_generation != gen) return;
        _typeNext();
      });
    } else {
      // Deleting
      _charIndex--;
      _currentText = phrase.substring(0, _charIndex.clamp(0, phrase.length));
      notifyListeners();

      if (_charIndex <= 0) {
        // Finished deleting — advance to next phrase
        _isDeleting = false;
        _phraseIndex = (_phraseIndex + 1) % _phrases.length;
        _startNextPhrase();
        return;
      }

      // Delete faster: 30ms per char
      _schedule(const Duration(milliseconds: 30), () {
        if (_generation != gen) return;
        _typeNext();
      });
    }
  }

  void _schedule(Duration delay, VoidCallback callback) {
    _timer?.cancel();
    _timer = Timer(delay, callback);
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    super.dispose();
  }
}
