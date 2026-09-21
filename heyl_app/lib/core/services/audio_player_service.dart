import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

/// State of the audio player
enum AudioPlayerState {
  idle,
  loading,
  playing,
  paused,
  completed,
  error,
}

/// Service for audio playback using just_audio
class AudioPlayerService {
  final AudioPlayer _player = AudioPlayer();

  final _stateController = StreamController<AudioPlayerState>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();

  AudioPlayerState _currentState = AudioPlayerState.idle;
  String? _currentUrl;

  AudioPlayerService() {
    _initializeListeners();
  }

  /// Stream of player state
  Stream<AudioPlayerState> get stateStream => _stateController.stream;

  /// Stream of playback position
  Stream<Duration> get positionStream => _positionController.stream;

  /// Stream of audio duration
  Stream<Duration?> get durationStream => _durationController.stream;

  /// Current player state
  AudioPlayerState get currentState => _currentState;

  /// Currently loaded URL
  String? get currentUrl => _currentUrl;

  /// Current position
  Duration get currentPosition => _player.position;

  /// Total duration
  Duration? get totalDuration => _player.duration;

  void _initializeListeners() {
    // Listen to player state changes
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.loading ||
          state.processingState == ProcessingState.buffering) {
        _updateState(AudioPlayerState.loading);
      } else if (state.processingState == ProcessingState.completed) {
        _updateState(AudioPlayerState.completed);
      } else if (state.playing) {
        _updateState(AudioPlayerState.playing);
      } else {
        _updateState(AudioPlayerState.paused);
      }
    });

    // Listen to position changes
    _player.positionStream.listen((position) {
      _positionController.add(position);
    });

    // Listen to duration changes
    _player.durationStream.listen((duration) {
      _durationController.add(duration);
    });
  }

  void _updateState(AudioPlayerState newState) {
    _currentState = newState;
    _stateController.add(newState);
  }

  /// Load and play audio from URL or file path
  Future<bool> play(String url) async {
    try {
      // If it's a different URL, load it first
      if (_currentUrl != url) {
        _updateState(AudioPlayerState.loading);
        _currentUrl = url;

        // Set the audio source
        if (url.startsWith('http://') || url.startsWith('https://')) {
          await _player.setUrl(url);
        } else {
          // Local file path
          await _player.setFilePath(url);
        }
      }

      // Play
      await _player.play();
      return true;
    } catch (e) {
      debugPrint('Failed to play audio: $e');
      _updateState(AudioPlayerState.error);
      return false;
    }
  }

  /// Pause playback
  Future<void> pause() async {
    try {
      await _player.pause();
    } catch (e) {
      debugPrint('Failed to pause audio: $e');
    }
  }

  /// Stop playback and reset position
  Future<void> stop() async {
    try {
      await _player.stop();
      await _player.seek(Duration.zero);
      _updateState(AudioPlayerState.idle);
    } catch (e) {
      debugPrint('Failed to stop audio: $e');
    }
  }

  /// Seek to a specific position
  Future<void> seek(Duration position) async {
    try {
      await _player.seek(position);
    } catch (e) {
      debugPrint('Failed to seek: $e');
    }
  }

  /// Toggle play/pause
  Future<void> togglePlayPause() async {
    if (_currentState == AudioPlayerState.playing) {
      await pause();
    } else {
      if (_currentUrl != null) {
        await play(_currentUrl!);
      }
    }
  }

  /// Dispose resources
  void dispose() {
    _player.dispose();
    _stateController.close();
    _positionController.close();
    _durationController.close();
  }
}

/// Provider for AudioPlayerService
///
/// This creates a single shared instance across the app.
/// For scenarios where you need independent players (e.g., multiple voice messages),
/// consider using a factory pattern or StateNotifierProvider.
final audioPlayerServiceProvider = Provider<AudioPlayerService>((ref) {
  final service = AudioPlayerService();
  ref.onDispose(() => service.dispose());
  return service;
});
