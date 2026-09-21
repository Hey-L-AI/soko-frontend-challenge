import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/audio_recorder_service.dart';

/// Recording state machine states
enum RecorderStatus {
  /// Not recording, ready to start
  idle,

  /// Requesting microphone permission
  requestingPermission,

  /// Currently recording
  recording,

  /// Processing/uploading recorded audio
  processing,

  /// Permission was denied
  permissionDenied,

  /// Permission was permanently denied
  permissionDeniedForever,

  /// Error occurred during recording
  error,
}

/// State for the voice recorder
class VoiceRecorderState {
  final RecorderStatus status;
  final Duration duration;
  final double amplitude;
  final String? filePath;
  final String? errorMessage;

  const VoiceRecorderState({
    this.status = RecorderStatus.idle,
    this.duration = Duration.zero,
    this.amplitude = 0.0,
    this.filePath,
    this.errorMessage,
  });

  VoiceRecorderState copyWith({
    RecorderStatus? status,
    Duration? duration,
    double? amplitude,
    String? filePath,
    String? errorMessage,
  }) {
    return VoiceRecorderState(
      status: status ?? this.status,
      duration: duration ?? this.duration,
      amplitude: amplitude ?? this.amplitude,
      filePath: filePath ?? this.filePath,
      errorMessage: errorMessage,
    );
  }

  bool get isRecording => status == RecorderStatus.recording;
  bool get isIdle => status == RecorderStatus.idle;
  bool get isProcessing => status == RecorderStatus.processing;
  bool get hasError =>
      status == RecorderStatus.error ||
      status == RecorderStatus.permissionDenied ||
      status == RecorderStatus.permissionDeniedForever;
}

/// Notifier for voice recorder state
class VoiceRecorderNotifier extends StateNotifier<VoiceRecorderState> {
  final AudioRecorderService _recorderService;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<double>? _amplitudeSubscription;

  VoiceRecorderNotifier(this._recorderService)
      : super(const VoiceRecorderState()) {
    _initializeStreams();
  }

  void _initializeStreams() {
    _durationSubscription = _recorderService.durationStream.listen((duration) {
      if (state.isRecording) {
        state = state.copyWith(duration: duration);
      }
    });

    _amplitudeSubscription =
        _recorderService.amplitudeStream.listen((amplitude) {
      if (state.isRecording) {
        state = state.copyWith(amplitude: amplitude);
      }
    });
  }

  /// Start recording
  Future<void> startRecording() async {
    debugPrint('[VoiceRecorder] startRecording called, current status: ${state.status}');
    if (state.isRecording) {
      debugPrint('[VoiceRecorder] Already recording, ignoring');
      return;
    }

    state = state.copyWith(status: RecorderStatus.requestingPermission);
    debugPrint('[VoiceRecorder] Requesting permission...');

    // Check permission
    final permissionStatus = await _recorderService.requestPermission();
    debugPrint('[VoiceRecorder] Permission status: $permissionStatus');
    if (permissionStatus == AudioPermissionStatus.denied) {
      debugPrint('[VoiceRecorder] Permission denied');
      state = state.copyWith(
        status: RecorderStatus.permissionDenied,
        errorMessage: 'Microphone permission denied',
      );
      return;
    } else if (permissionStatus == AudioPermissionStatus.deniedForever) {
      debugPrint('[VoiceRecorder] Permission denied forever');
      state = state.copyWith(
        status: RecorderStatus.permissionDeniedForever,
        errorMessage: 'Microphone permission permanently denied',
      );
      return;
    }

    // Start recording
    debugPrint('[VoiceRecorder] Starting recording...');
    final filePath = await _recorderService.startRecording();
    debugPrint('[VoiceRecorder] startRecording returned: $filePath');
    if (filePath == null) {
      debugPrint('[VoiceRecorder] Failed to start recording');
      state = state.copyWith(
        status: RecorderStatus.error,
        errorMessage: 'Failed to start recording',
      );
      return;
    }

    debugPrint('[VoiceRecorder] Recording started successfully');
    state = state.copyWith(
      status: RecorderStatus.recording,
      duration: Duration.zero,
      amplitude: 0.0,
      filePath: filePath,
    );
  }

  /// Stop recording and return the file path
  Future<String?> stopRecording() async {
    debugPrint('[VoiceRecorder] stopRecording called, current status: ${state.status}');
    if (!state.isRecording) {
      debugPrint('[VoiceRecorder] Not recording, ignoring stop');
      return null;
    }

    state = state.copyWith(status: RecorderStatus.processing);
    debugPrint('[VoiceRecorder] Processing...');

    final result = await _recorderService.stopRecording();
    debugPrint('[VoiceRecorder] stopRecording result: isSuccess=${result.isSuccess}, filePath=${result.filePath}, error=${result.errorMessage}');
    if (!result.isSuccess) {
      debugPrint('[VoiceRecorder] Recording failed: ${result.errorMessage}');
      state = state.copyWith(
        status: RecorderStatus.error,
        errorMessage: result.errorMessage ?? 'Failed to stop recording',
      );
      return null;
    }

    // Reset state to idle
    final filePath = result.filePath;
    debugPrint('[VoiceRecorder] Recording successful, returning filePath: $filePath');
    state = const VoiceRecorderState(status: RecorderStatus.idle);
    return filePath;
  }

  /// Cancel recording without saving
  Future<void> cancelRecording() async {
    if (!state.isRecording) return;

    await _recorderService.cancelRecording();
    state = const VoiceRecorderState(status: RecorderStatus.idle);
  }

  /// Reset error state
  void resetError() {
    if (state.hasError) {
      state = const VoiceRecorderState(status: RecorderStatus.idle);
    }
  }

  @override
  void dispose() {
    _durationSubscription?.cancel();
    _amplitudeSubscription?.cancel();
    super.dispose();
  }
}

/// Provider for voice recorder state
final voiceRecorderProvider =
    StateNotifierProvider<VoiceRecorderNotifier, VoiceRecorderState>((ref) {
  final recorderService = ref.watch(audioRecorderServiceProvider);
  return VoiceRecorderNotifier(recorderService);
});
