import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/services/experiment_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/chat_search_label.dart';
import '../../../providers/voice_recorder_provider.dart';
import '../../../shared/widgets/chat_bar.dart';
import 'voice_recorder_widget.dart';

/// Chat conversation composer. Renders the shared chat-bar primitives from
/// `shared/widgets/chat_bar.dart`:
/// - Top row: text input + mic + send.
/// - Bottom row (PROD-1894): pink strip with the "Create list" pill —
///   only rendered when [showCreateList] is true (i.e. the conversation
///   has saveable cards). When there are no cards, the strip is omitted
///   entirely.
class MessageInput extends ConsumerStatefulWidget {
  final Function(String) onSend;
  final Function(String)? onVoiceSend;
  final VoidCallback? onShareLocation;
  final bool isLoading;
  final bool isLocationSharing;
  final double? uploadProgress;
  final bool autofocus;
  final String? placeholder;

  /// When true, the input is disabled (e.g., for WhatsApp read-only sessions).
  final bool disabled;

  /// PROD-1894: when true, render the bottom "Create list" pill strip
  /// below the input. False (default) keeps the composer single-row.
  final bool showCreateList;

  /// Invoked when the "Create list" pill is tapped. Required when
  /// [showCreateList] is true; ignored otherwise.
  final VoidCallback? onCreateList;

  /// When true, render a History button on the right of the same bottom
  /// strip that hosts Create-list. Shares the strip with Create-list when
  /// both are enabled.
  final bool showHistory;

  /// Invoked when the History button is tapped. Required when
  /// [showHistory] is true; ignored otherwise.
  final VoidCallback? onHistory;

  /// When true, render the pink map button to the right of the composer.
  /// Gated by the caller on the session having results.
  final bool showMapButton;

  /// Invoked when the map button is tapped. Required when [showMapButton]
  /// is true; ignored otherwise.
  final VoidCallback? onOpenMap;

  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChanged;
  final ValueChanged<bool>? onHasTextChanged;

  const MessageInput({
    super.key,
    required this.onSend,
    this.onVoiceSend,
    this.onShareLocation,
    this.isLoading = false,
    this.isLocationSharing = false,
    this.uploadProgress,
    this.autofocus = false,
    this.placeholder,
    this.disabled = false,
    this.showCreateList = false,
    this.onCreateList,
    this.showHistory = false,
    this.onHistory,
    this.showMapButton = false,
    this.onOpenMap,
    this.focusNode,
    this.onFocusChanged,
    this.onHasTextChanged,
  });

  @override
  ConsumerState<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends ConsumerState<MessageInput> {
  final _controller = TextEditingController();
  late final FocusNode _focusNode;
  bool _ownsFocusNode = false;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
      _focusNode.onKeyEvent = _handleKeyEvent;
    } else {
      _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
      _ownsFocusNode = true;
    }
    _focusNode.addListener(_onFocusChanged);
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
        widget.onHasTextChanged?.call(hasText);
      }
    });

    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  void _onFocusChanged() {
    setState(() {}); // Rebuild to hide/show placeholder based on focus
    widget.onFocusChanged?.call(_focusNode.hasFocus);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      if (_hasText && !widget.isLoading) {
        _handleSend();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _controller.dispose();
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  Future<void> _handleVoice() async {
    final recorderNotifier = ref.read(voiceRecorderProvider.notifier);
    final recorderState = ref.read(voiceRecorderProvider);

    if (recorderState.isRecording) {
      await _stopAndSendVoice();
    } else {
      await recorderNotifier.startRecording();
      if (!mounted) return;

      final newState = ref.read(voiceRecorderProvider);
      if (newState.status == RecorderStatus.permissionDenied) {
        _showPermissionDeniedDialog();
      } else if (newState.status == RecorderStatus.permissionDeniedForever) {
        _showPermissionDeniedForeverDialog();
      } else if (newState.status == RecorderStatus.error) {
        showSoko(
          ref,
          message: Lt.of(context).voiceRecordingError,
          variant: SokoVariant.error,
        );
      }
    }
  }

  Future<void> _stopAndSendVoice() async {
    final recorderNotifier = ref.read(voiceRecorderProvider.notifier);
    final filePath = await recorderNotifier.stopRecording();
    if (filePath != null && widget.onVoiceSend != null) {
      widget.onVoiceSend!(filePath);
    }
  }

  void _cancelVoiceRecording() {
    ref.read(voiceRecorderProvider.notifier).cancelRecording();
    showSoko(
      ref,
      message: Lt.of(context).voiceRecordingCancelled,
      variant: SokoVariant.info,
    );
  }

  void _showPermissionDeniedDialog() {
    if (!kIsWeb) {
      _showPermissionDeniedForeverDialog();
      return;
    }
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(Lt.of(context).voicePermissionRequired),
        content: Text(Lt.of(context).voicePermissionDeniedContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(Lt.of(context).cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _handleVoice();
            },
            child: Text(Lt.of(context).tryAgain),
          ),
        ],
      ),
    );
  }

  void _showPermissionDeniedForeverDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(Lt.of(context).voicePermissionRequired),
        content: Text(Lt.of(context).voicePermissionDeniedForever),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(Lt.of(context).cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: Text(Lt.of(context).openSettings),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.disabled) {
      return _buildDisabledInput(context);
    }

    final experiments = ref.watch(experimentServiceProvider);
    final voiceEnabled = experiments.enableVoiceMessages;
    final isRecording = voiceEnabled
        ? ref.watch(voiceRecorderProvider.select((s) => s.isRecording))
        : false;
    final searchLocationLabel = chatSearchLabelText(
      ref.watch(chatSearchLocationLabelProvider),
      Lt.of(context),
    );

    final bar = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isRecording)
          Container(
            decoration: const BoxDecoration(
              color: AppColors.sokoShade5,
              borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
            ),
            padding: const EdgeInsets.all(10),
            child: VoiceRecorderWidget(
              onCancel: _cancelVoiceRecording,
              onStopAndSend: _stopAndSendVoice,
            ),
          )
        else
          Builder(
            builder: (context) {
              final topRow = ChatBarTopRow(
                controller: _controller,
                focusNode: _focusNode,
                placeholder:
                    widget.placeholder ?? Lt.of(context).chatInputPlaceholder,
                hasText: _hasText,
                voiceEnabled: voiceEnabled,
                onSend: _handleSend,
                onMicTap: _handleVoice,
                onClear: _controller.clear,
                outlined: true,
                isLoading: widget.isLoading,
              );
              // No map button → the input capsule spans 100% width.
              if (!widget.showMapButton || widget.onOpenMap == null) {
                return topRow;
              }
              // Pink map button sits OUTSIDE the input capsule, to its right
              // with a 6 px gap (Figma `7507:28139`), centre-aligned.
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: topRow),
                  const SizedBox(width: 6),
                  ChatBarMapButton(onTap: widget.onOpenMap!),
                ],
              );
            },
          ),
        if ((widget.showCreateList && widget.onCreateList != null) ||
            (widget.showHistory && widget.onHistory != null))
          ChatBarBottomRow(
            searchLocationLabel: searchLocationLabel,
            onCreateListTap: widget.showCreateList ? widget.onCreateList : null,
            onHistoryTap: widget.showHistory ? widget.onHistory : null,
          ),
      ],
    );

    // PROD-1804: Hero-receive the bar's geometry from Discovery (top) when
    // a new session is opened by send. Tag matches `discovery_chat_bar.dart`.
    return Hero(
      tag: kChatBarHeroTag,
      child: Material(color: Colors.transparent, child: bar),
    );
  }

  /// Read-only state for WhatsApp sessions — preserves the chat-bar
  /// silhouette but disables interaction.
  Widget _buildDisabledInput(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock_outline, size: 16, color: AppColors.sokoShade3),
          const SizedBox(width: 8),
          Text(
            Lt.of(context).sessionReadOnlyLabel,
            style: const TextStyle(color: AppColors.sokoShade3, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
