import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Result of an audio permission check
enum AudioPermissionStatus {
  granted,
  denied,
  deniedForever,
}

/// Result of a recording operation
class RecordingResult {
  final String? filePath;
  final Duration? duration;
  final String? errorMessage;

  const RecordingResult({
    this.filePath,
    this.duration,
    this.errorMessage,
  });

  bool get isSuccess => filePath != null;
}

/// Service for audio recording using the record package
class AudioRecorderService {
  final AudioRecorder _recorder = AudioRecorder();

  Timer? _durationTimer;
  Timer? _amplitudeTimer;
  Duration _currentDuration = Duration.zero;
  final _durationController = StreamController<Duration>.broadcast();
  final _amplitudeController = StreamController<double>.broadcast();

  static const Duration maxDuration = Duration(minutes: 5);

  /// Stream of recording duration
  Stream<Duration> get durationStream => _durationController.stream;

  /// Stream of audio amplitude (0.0 to 1.0)
  Stream<double> get amplitudeStream => _amplitudeController.stream;

  /// Current recording duration
  Duration get currentDuration => _currentDuration;

  /// Check if currently recording
  Future<bool> isRecording() async {
    return await _recorder.isRecording();
  }

  /// Check if microphone permission is granted
  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  /// Request microphone permission
  Future<AudioPermissionStatus> requestPermission() async {
    final granted = await _recorder.hasPermission();
    if (granted) {
      return AudioPermissionStatus.granted;
    }
    // Note: The record package doesn't distinguish between denied and deniedForever
    // On iOS/Android, if the user denies twice, it's typically "deniedForever"
    return AudioPermissionStatus.denied;
  }

  /// Start recording audio
  ///
  /// Records to a temporary file in the appropriate format for the platform.
  /// Returns the file path that will be used (or a placeholder on web),
  /// or null if recording couldn't start.
  Future<String?> startRecording() async {
    try {
      // Check permission
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        debugPrint('[AudioRecorder] Permission not granted');
        return null;
      }

      // Determine format based on platform
      final AudioEncoder encoder;
      String? filePath;

      if (kIsWeb) {
        // Web uses WebM with Opus codec
        // On web, we don't pass a path - the package handles it internally
        // and returns a blob URL when we stop
        encoder = AudioEncoder.opus;
        debugPrint('[AudioRecorder] Starting web recording with Opus encoder');
      } else if (Platform.isIOS) {
        // iOS uses M4A with AAC codec
        encoder = AudioEncoder.aacLc;
        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        filePath = '${tempDir.path}/voice_$timestamp.m4a';
        debugPrint('[AudioRecorder] Starting iOS recording to: $filePath');
      } else {
        // Android uses OGG with Opus codec (best compression)
        encoder = AudioEncoder.opus;
        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        filePath = '${tempDir.path}/voice_$timestamp.ogg';
        debugPrint('[AudioRecorder] Starting Android recording to: $filePath');
      }

      // Configure recording
      final config = RecordConfig(
        encoder: encoder,
        sampleRate: 44100,
        bitRate: 128000,
        numChannels: 1, // Mono for voice
      );

      // Start recording
      // On web, don't pass a path - let the package handle blob storage
      if (kIsWeb) {
        await _recorder.start(config, path: '');
      } else {
        await _recorder.start(config, path: filePath!);
      }

      debugPrint('[AudioRecorder] Recording started successfully');

      // Start duration timer
      _currentDuration = Duration.zero;
      _durationController.add(_currentDuration);
      _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        _currentDuration += const Duration(milliseconds: 100);
        _durationController.add(_currentDuration);

        // Auto-stop at max duration
        if (_currentDuration >= maxDuration) {
          stopRecording();
        }
      });

      // Start amplitude monitoring
      _startAmplitudeMonitoring();

      // On web, return a placeholder - the real URL comes from stop()
      return kIsWeb ? 'recording_in_progress' : filePath;
    } catch (e) {
      debugPrint('[AudioRecorder] Failed to start recording: $e');
      return null;
    }
  }

  /// Stop recording and return the result
  Future<RecordingResult> stopRecording() async {
    try {
      _stopTimers();

      debugPrint('[AudioRecorder] Stopping recording...');
      final filePath = await _recorder.stop();
      debugPrint('[AudioRecorder] Recording stopped, path: $filePath');

      if (filePath == null || filePath.isEmpty) {
        debugPrint('[AudioRecorder] No file path returned');
        return const RecordingResult(
          errorMessage: 'Recording stopped but no file was created',
        );
      }

      return RecordingResult(
        filePath: filePath,
        duration: _currentDuration,
      );
    } catch (e) {
      debugPrint('[AudioRecorder] Failed to stop recording: $e');
      return RecordingResult(
        errorMessage: 'Failed to stop recording: $e',
      );
    }
  }

  /// Cancel the current recording without saving
  Future<void> cancelRecording() async {
    try {
      _stopTimers();

      final filePath = await _recorder.stop();

      // Delete the file if it exists (only on non-web platforms)
      if (filePath != null && !kIsWeb) {
        try {
          final file = File(filePath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {
          // Ignore file deletion errors
        }
      }
    } catch (e) {
      debugPrint('[AudioRecorder] Failed to cancel recording: $e');
    }
  }

  /// Start monitoring audio amplitude
  void _startAmplitudeMonitoring() {
    // Poll amplitude every 100ms
    _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) async {
      if (!await _recorder.isRecording()) {
        timer.cancel();
        return;
      }

      try {
        final amplitude = await _recorder.getAmplitude();
        // Convert dB to 0-1 range (typical voice is -60 to 0 dB)
        // amplitude.current is in dB, where 0 is max and negative values are quieter
        final normalizedAmplitude = ((amplitude.current + 60) / 60).clamp(0.0, 1.0);
        _amplitudeController.add(normalizedAmplitude);
      } catch (_) {
        // Ignore amplitude errors
      }
    });
  }

  /// Stop duration and amplitude timers
  void _stopTimers() {
    _durationTimer?.cancel();
    _durationTimer = null;
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;
  }

  /// Dispose resources
  void dispose() {
    _stopTimers();
    _recorder.dispose();
    _durationController.close();
    _amplitudeController.close();
  }
}

/// Provider for AudioRecorderService
final audioRecorderServiceProvider = Provider<AudioRecorderService>((ref) {
  final service = AudioRecorderService();
  ref.onDispose(() => service.dispose());
  return service;
});
