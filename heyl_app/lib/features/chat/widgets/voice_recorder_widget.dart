import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/voice_recorder_provider.dart';

/// Widget shown during voice recording
///
/// Displays:
/// - Recording timer
/// - Amplitude indicator (pulsing mic)
/// - Cancel button
/// - Stop/Send button
class VoiceRecorderWidget extends ConsumerWidget {
  final VoidCallback onCancel;
  final Future<void> Function() onStopAndSend;

  const VoiceRecorderWidget({
    super.key,
    required this.onCancel,
    required this.onStopAndSend,
  });

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recorderState = ref.watch(voiceRecorderProvider);

    return Row(
      children: [
        // Cancel button
        TextButton.icon(
          onPressed: onCancel,
          icon: const Icon(
            Icons.close,
            color: AppColors.sokoInk,
            size: 20,
          ),
          label: Text(
            Lt.of(context).cancel,
            style: const TextStyle(color: AppColors.sokoInk),
          ),
        ),

        const SizedBox(width: 12),

        // Recording indicator and timer
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Pulsing recording indicator
              _PulsingRecordingIndicator(amplitude: recorderState.amplitude),
              const SizedBox(width: 8),

              // Timer
              Text(
                _formatDuration(recorderState.duration),
                style: const TextStyle(
                  color: AppColors.sokoInk,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(width: 12),

        // Stop and send button
        ElevatedButton.icon(
          onPressed: recorderState.isRecording ? onStopAndSend : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.sokoPink,
            foregroundColor: AppColors.sokoInk,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          icon: const Icon(Icons.send, size: 18),
          label: Text(Lt.of(context).send),
        ),
      ],
    );
  }
}

/// Pulsing recording indicator that responds to amplitude
class _PulsingRecordingIndicator extends StatelessWidget {
  final double amplitude;

  const _PulsingRecordingIndicator({required this.amplitude});

  @override
  Widget build(BuildContext context) {
    // Scale the indicator based on amplitude (0.0 to 1.0)
    final scale = 1.0 + (amplitude * 0.3); // Max 30% larger

    return AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      width: 12 * scale,
      height: 12 * scale,
      decoration: BoxDecoration(
        color: AppColors.error,
        shape: BoxShape.circle,
        boxShadow: amplitude > 0
            ? [
                BoxShadow(
                  color: AppColors.error.withValues(alpha: 0.4),
                  blurRadius: 8 * amplitude,
                  spreadRadius: 2 * amplitude,
                ),
              ]
            : null,
      ),
    );
  }
}
