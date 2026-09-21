import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/audio_player_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/clickable.dart';

/// Widget for playing voice messages in chat bubbles
///
/// Features:
/// - Play/Pause button
/// - Progress bar
/// - Duration display (current / total)
class VoiceMessagePlayer extends StatefulWidget {
  final String audioUrl;
  final bool isUserMessage;

  const VoiceMessagePlayer({
    super.key,
    required this.audioUrl,
    required this.isUserMessage,
  });

  @override
  State<VoiceMessagePlayer> createState() => _VoiceMessagePlayerState();
}

class _VoiceMessagePlayerState extends State<VoiceMessagePlayer> {
  final AudioPlayerService _playerService = AudioPlayerService();

  AudioPlayerState _playerState = AudioPlayerState.idle;
  Duration _position = Duration.zero;
  Duration? _duration;

  StreamSubscription<AudioPlayerState>? _stateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  void _initializePlayer() {
    _stateSubscription = _playerService.stateStream.listen((state) {
      if (mounted) {
        setState(() => _playerState = state);
      }
    });

    _positionSubscription = _playerService.positionStream.listen((position) {
      if (mounted) {
        setState(() => _position = position);
      }
    });

    _durationSubscription = _playerService.durationStream.listen((duration) {
      if (mounted) {
        setState(() => _duration = duration);
      }
    });
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playerService.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _togglePlayPause() async {
    if (_playerState == AudioPlayerState.playing) {
      await _playerService.pause();
    } else {
      await _playerService.play(widget.audioUrl);
    }
  }

  Future<void> _seek(double value) async {
    if (_duration != null) {
      final position = Duration(
        milliseconds: (value * _duration!.inMilliseconds).round(),
      );
      await _playerService.seek(position);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Soko bubbles are sokoPink (user) / sokoShade5 (assistant) — both put
    // sokoInk-derived text/icons on top for contrast.
    const iconColor = AppColors.sokoInk;
    const progressActiveColor = AppColors.sokoInk;
    final progressInactiveColor = AppColors.sokoInk.withValues(alpha: 0.3);
    final textColor = AppColors.sokoInk.withValues(alpha: 0.7);

    // Calculate progress
    final progress = _duration != null && _duration!.inMilliseconds > 0
        ? _position.inMilliseconds / _duration!.inMilliseconds
        : 0.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Play/Pause button
        _buildPlayButton(iconColor),
        const SizedBox(width: 8),

        // Progress and duration
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Progress bar
              SizedBox(
                height: 20,
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: progressActiveColor,
                    inactiveTrackColor: progressInactiveColor,
                    thumbColor: progressActiveColor,
                    overlayColor: progressActiveColor.withValues(alpha: 0.2),
                  ),
                  child: Slider(
                    value: progress.clamp(0.0, 1.0),
                    onChanged: _seek,
                  ),
                ),
              ),

              // Duration text
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  _duration != null
                      ? '${_formatDuration(_position)} / ${_formatDuration(_duration!)}'
                      : '0:00',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlayButton(Color iconColor) {
    final isLoading = _playerState == AudioPlayerState.loading;
    final isPlaying = _playerState == AudioPlayerState.playing;

    if (isLoading) {
      return SizedBox(
        width: 32,
        height: 32,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: iconColor,
          ),
        ),
      );
    }

    return Clickable(
      onTap: _togglePlayPause,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: iconColor.withValues(alpha: 0.15),
        ),
        child: Icon(
          isPlaying ? Icons.pause : Icons.play_arrow,
          color: iconColor,
          size: 20,
        ),
      ),
    );
  }
}
