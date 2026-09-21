import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/services/audio_recorder_service.dart';
import '../../../core/services/unified_analytics_service.dart'
    show unifiedAnalyticsProvider;
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_text_field.dart';
import '../app_feedback_area.dart';

/// Which feedback box is currently being recorded / played.
enum _Box { issue, idea }

/// Max voice-note length (mirrors the server-side cap, PROD-2900).
const Duration _kMaxRecordDuration = Duration(seconds: 90);

/// Open the app-wide feedback sheet. [currentArea] is the "this page" scope
/// (the shell's active page); [sessionId] is attached only for chat-area
/// submissions. [trigger] says which affordance opened it ('shake' | 'tab')
/// for the feedback_open analytics event (PROD-3211).
Future<void> showAppFeedbackSheet(
  BuildContext context,
  WidgetRef ref, {
  required AppFeedbackArea currentArea,
  String? sessionId,
  String trigger = 'tab',
}) {
  ref
      .read(unifiedAnalyticsProvider)
      .trackFeedbackOpen(trigger: trigger, screen: currentArea.name);
  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (_) =>
        _AppFeedbackSheet(currentArea: currentArea, sessionId: sessionId),
  );
}

class _AppFeedbackSheet extends ConsumerStatefulWidget {
  final AppFeedbackArea currentArea;
  final String? sessionId;

  const _AppFeedbackSheet({required this.currentArea, this.sessionId});

  @override
  ConsumerState<_AppFeedbackSheet> createState() => _AppFeedbackSheetState();
}

class _AppFeedbackSheetState extends ConsumerState<_AppFeedbackSheet> {
  final _issueController = TextEditingController();
  final _ideaController = TextEditingController();

  late AppFeedbackArea _scope;

  // Recording (one recorder, one active box at a time).
  final AudioRecorderService _recorder = AudioRecorderService();
  StreamSubscription<Duration>? _durationSub;
  _Box? _recordingBox;
  Duration _recordDuration = Duration.zero;

  // Recorded audio, per box.
  String? _issueAudioPath;
  Duration? _issueAudioDuration;
  String? _ideaAudioPath;
  Duration? _ideaAudioDuration;

  // Playback.
  final AudioPlayer _player = AudioPlayer();
  _Box? _playingBox;

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _scope = widget.currentArea;
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && mounted) {
        setState(() => _playingBox = null);
      }
    });
  }

  @override
  void dispose() {
    _issueController.dispose();
    _ideaController.dispose();
    _durationSub?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  bool get _hasContent =>
      _issueController.text.trim().isNotEmpty ||
      _ideaController.text.trim().isNotEmpty ||
      _issueAudioPath != null ||
      _ideaAudioPath != null;

  // ---- recording ----------------------------------------------------------

  Future<void> _startRecording(_Box box) async {
    if (_recordingBox != null) return;
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (!mounted) return;
      showSoko(
        ref,
        message: Lt.of(context).appFeedbackMicDenied,
        variant: SokoVariant.error,
      );
      return;
    }
    final path = await _recorder.startRecording();
    if (path == null) {
      if (!mounted) return;
      showSoko(
        ref,
        message: Lt.of(context).appFeedbackMicDenied,
        variant: SokoVariant.error,
      );
      return;
    }
    _durationSub = _recorder.durationStream.listen((d) {
      if (!mounted) return;
      setState(() => _recordDuration = d);
      if (d >= _kMaxRecordDuration) {
        _stopRecording();
      }
    });
    if (!mounted) return;
    setState(() {
      _recordingBox = box;
      _recordDuration = Duration.zero;
    });
  }

  Future<void> _stopRecording() async {
    final box = _recordingBox;
    if (box == null) return;
    await _durationSub?.cancel();
    _durationSub = null;
    final result = await _recorder.stopRecording();
    if (!mounted) return;
    setState(() {
      _recordingBox = null;
      if (result.isSuccess) {
        if (box == _Box.issue) {
          _issueAudioPath = result.filePath;
          _issueAudioDuration = result.duration;
        } else {
          _ideaAudioPath = result.filePath;
          _ideaAudioDuration = result.duration;
        }
      }
    });
  }

  void _deleteAudio(_Box box) {
    if (_playingBox == box) {
      _player.stop();
      _playingBox = null;
    }
    setState(() {
      if (box == _Box.issue) {
        _issueAudioPath = null;
        _issueAudioDuration = null;
      } else {
        _ideaAudioPath = null;
        _ideaAudioDuration = null;
      }
    });
  }

  // ---- playback -----------------------------------------------------------

  Future<void> _togglePlay(_Box box, String path) async {
    if (_playingBox == box) {
      await _player.pause();
      if (mounted) setState(() => _playingBox = null);
      return;
    }
    try {
      await _player.stop();
      if (kIsWeb || path.startsWith('blob:')) {
        await _player.setUrl(path);
      } else {
        await _player.setFilePath(path);
      }
      if (!mounted) return;
      setState(() => _playingBox = box);
      await _player.play();
    } catch (_) {
      if (mounted) setState(() => _playingBox = null);
    }
  }

  // ---- submit -------------------------------------------------------------

  Future<void> _submit() async {
    if (!_hasContent || _submitting) return;
    setState(() => _submitting = true);
    final l10n = Lt.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final platform = kIsWeb ? 'web' : defaultTargetPlatform.name;

    try {
      await ref
          .read(appFeedbackApiProvider)
          .submitAppFeedback(
            area: _scope,
            sessionId: _scope == AppFeedbackArea.chat ? widget.sessionId : null,
            issueText: _issueController.text,
            ideaText: _ideaController.text,
            issueAudioPath: _issueAudioPath,
            ideaAudioPath: _ideaAudioPath,
            platform: platform,
            locale: locale,
          );
      // PROD-3211: measure volume/type/scope — the text itself already lands
      // in the backoffice "User Feedback" tab for humans.
      final hasIssue =
          _issueController.text.trim().isNotEmpty || _issueAudioPath != null;
      final hasIdea =
          _ideaController.text.trim().isNotEmpty || _ideaAudioPath != null;
      ref
          .read(unifiedAnalyticsProvider)
          .trackFeedbackSubmit(
            type: hasIssue && hasIdea
                ? 'both'
                : hasIssue
                ? 'problem'
                : 'idea',
            scope: _scope == AppFeedbackArea.general ? 'app' : 'page',
            length:
                _issueController.text.trim().length +
                _ideaController.text.trim().length,
            hasAudio: _issueAudioPath != null || _ideaAudioPath != null,
            screen: _scope.name,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      showSoko(
        ref,
        message: l10n.appFeedbackSuccessToast,
        variant: SokoVariant.success,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showSoko(
        ref,
        message: l10n.appFeedbackErrorToast,
        variant: SokoVariant.error,
      );
    }
  }

  String _issueHint(Lt l10n) {
    switch (_scope) {
      case AppFeedbackArea.homepage:
        return l10n.appFeedbackIssueHintHomepage;
      case AppFeedbackArea.library:
        return l10n.appFeedbackIssueHintLibrary;
      case AppFeedbackArea.create:
        return l10n.appFeedbackIssueHintCreate;
      case AppFeedbackArea.menu:
        return l10n.appFeedbackIssueHintMenu;
      case AppFeedbackArea.chat:
        return l10n.appFeedbackIssueHintChat;
      case AppFeedbackArea.profile:
        return l10n.appFeedbackIssueHintProfile;
      case AppFeedbackArea.general:
        return l10n.appFeedbackIssueHintGeneral;
    }
  }

  /// Icon for a scope button. Homepage uses the Soko brand mark (matching the
  /// bottom nav's Home tab); the rest use their nav-equivalent glyphs tinted to
  /// [color].
  Widget _areaIconWidget(AppFeedbackArea a, Color color) {
    if (a == AppFeedbackArea.homepage) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return SvgPicture.asset(
        isDark
            ? 'assets/images/logos/soko-icon-paper.svg'
            : 'assets/images/logos/soko-icon-blood-1.svg',
        width: 20,
        height: 20,
      );
    }
    final IconData icon;
    switch (a) {
      case AppFeedbackArea.chat:
        icon = LucideIcons.message_circle;
      case AppFeedbackArea.library:
        icon = LucideIcons.book_open;
      case AppFeedbackArea.create:
        icon = LucideIcons.plus;
      case AppFeedbackArea.menu:
        icon = LucideIcons.menu;
      case AppFeedbackArea.profile:
        icon = LucideIcons.user;
      case AppFeedbackArea.homepage:
      case AppFeedbackArea.general:
        icon = LucideIcons.layout_grid;
    }
    return Icon(icon, size: 20, color: color);
  }

  String _areaName(AppFeedbackArea a, Lt l10n) {
    switch (a) {
      case AppFeedbackArea.homepage:
        return l10n.appFeedbackAreaHomepage;
      case AppFeedbackArea.chat:
        return l10n.appFeedbackAreaChat;
      case AppFeedbackArea.library:
        return l10n.appFeedbackAreaLibrary;
      case AppFeedbackArea.create:
        return l10n.appFeedbackAreaCreate;
      case AppFeedbackArea.menu:
        return l10n.appFeedbackAreaMenu;
      case AppFeedbackArea.profile:
        return l10n.appFeedbackAreaProfile;
      case AppFeedbackArea.general:
        return l10n.appFeedbackScopeGeneral;
    }
  }

  /// A note text box with the voice-note mic control overlaid inside its
  /// bottom-right corner (per the mockup).
  Widget _textBoxWithMic(
    _Box box,
    TextEditingController controller,
    String hint,
  ) {
    final path = box == _Box.issue ? _issueAudioPath : _ideaAudioPath;
    final dur = box == _Box.issue ? _issueAudioDuration : _ideaAudioDuration;
    return Stack(
      children: [
        SokoTextField(
          controller: controller,
          hintText: hint,
          minLines: 2,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          // Keep the hint + text pinned to the top of the box (not centered).
          textAlignVertical: TextAlignVertical.top,
          // Reserve bottom-right space so text never runs under the mic.
          contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 40),
          onChanged: (_) => setState(() {}),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: _MicInBox(
            audioPath: path,
            audioDuration: dur,
            isRecording: _recordingBox == box,
            recordDuration: _recordDuration,
            maxDuration: _kMaxRecordDuration,
            isPlaying: _playingBox == box,
            recordingElsewhere: _recordingBox != null && _recordingBox != box,
            onStart: () => _startRecording(box),
            onStop: _stopRecording,
            onDelete: () => _deleteAudio(box),
            onTogglePlay: () => _togglePlay(box, path ?? ''),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final busy = _submitting || _recordingBox != null;

    return DSSheetShell(
      header: _Header(title: l10n.appFeedbackSheetTitle),
      bodyPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        LucideIcons.vibrate,
                        size: 15,
                        color: AppColors.sokoInk.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                  TextSpan(text: l10n.appFeedbackSheetSubtitle),
                ],
              ),
              style: AppTheme.body(
                fontSize: 14,
                color: AppColors.sokoInk.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 14),
            _SectionLabel(l10n.appFeedbackAboutLabel),
            const SizedBox(height: 8),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _ScopeButton(
                      icon: _areaIconWidget(
                        widget.currentArea,
                        _scope == widget.currentArea
                            ? AppColors.sokoInk
                            : AppColors.sokoInkSecondary,
                      ),
                      title: _areaName(widget.currentArea, l10n),
                      subtitle: l10n.appFeedbackScopeThisPageTag,
                      selected: _scope == widget.currentArea,
                      onTap: busy
                          ? null
                          : () => setState(() => _scope = widget.currentArea),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ScopeButton(
                      icon: Icon(
                        LucideIcons.layout_grid,
                        size: 20,
                        color:
                            (_scope == AppFeedbackArea.general &&
                                widget.currentArea != AppFeedbackArea.general)
                            ? AppColors.sokoInk
                            : AppColors.sokoInkSecondary,
                      ),
                      title: l10n.appFeedbackScopeGeneral,
                      subtitle: null,
                      selected:
                          _scope == AppFeedbackArea.general &&
                          widget.currentArea != AppFeedbackArea.general,
                      onTap: busy
                          ? null
                          : () => setState(
                              () => _scope = AppFeedbackArea.general,
                            ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _SectionLabel(l10n.appFeedbackIssueLabel),
            const SizedBox(height: 8),
            _textBoxWithMic(_Box.issue, _issueController, _issueHint(l10n)),
            const SizedBox(height: 14),
            _SectionLabel(l10n.appFeedbackIdeaLabel),
            const SizedBox(height: 8),
            _textBoxWithMic(
              _Box.idea,
              _ideaController,
              l10n.appFeedbackIdeaHint,
            ),
          ],
        ),
      ),
      footer: _SubmitFooter(
        label: l10n.appFeedbackSubmitButton,
        onSubmit: _submit,
        enabled: _hasContent && !busy,
        loading: _submitting,
      ),
    );
  }
}

String _fmtDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Mic control + recorded-audio chip for one box.
/// Voice-note control that lives inside a text box's bottom-right corner:
/// idle mic → recording (time + stop) → recorded (play · duration · delete).
class _MicInBox extends StatelessWidget {
  final String? audioPath;
  final Duration? audioDuration;
  final bool isRecording;
  final Duration recordDuration;
  final Duration maxDuration;
  final bool isPlaying;
  final bool recordingElsewhere;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onDelete;
  final VoidCallback onTogglePlay;

  const _MicInBox({
    required this.audioPath,
    required this.audioDuration,
    required this.isRecording,
    required this.recordDuration,
    required this.maxDuration,
    required this.isPlaying,
    required this.recordingElsewhere,
    required this.onStart,
    required this.onStop,
    required this.onDelete,
    required this.onTogglePlay,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    // Recorded → compact play · duration · delete pill.
    if (audioPath != null) {
      return Container(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.sokoShade4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CircleBtn(
              icon: isPlaying ? LucideIcons.pause : LucideIcons.play,
              tooltip: isPlaying
                  ? l10n.appFeedbackPauseAudio
                  : l10n.appFeedbackPlayAudio,
              onTap: onTogglePlay,
              size: 30,
            ),
            const SizedBox(width: 8),
            Text(
              _fmtDuration(audioDuration ?? Duration.zero),
              style: AppTheme.body(fontSize: 12, color: AppColors.sokoInk),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: l10n.appFeedbackDeleteAudio,
              child: InkResponse(
                onTap: onDelete,
                radius: 18,
                child: Icon(
                  LucideIcons.trash_2,
                  size: 17,
                  color: AppColors.sokoInkSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Recording → time remaining + stop. Counting down (rather than up) is the
    // only signal the user gets that recording auto-stops at the cap.
    if (isRecording) {
      final remaining = maxDuration - recordDuration;
      final left = remaining.isNegative ? Duration.zero : remaining;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _fmtDuration(left),
            semanticsLabel: l10n.appFeedbackRecordTimeLeft(_fmtDuration(left)),
            style: AppTheme.body(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.sokoRed,
            ),
          ),
          const SizedBox(width: 6),
          _CircleBtn(
            icon: LucideIcons.square,
            tooltip: l10n.appFeedbackRecordStop,
            onTap: onStop,
          ),
        ],
      );
    }

    // Idle → circular mic button.
    return _CircleBtn(
      icon: LucideIcons.mic,
      tooltip: l10n.appFeedbackRecordStart,
      onTap: recordingElsewhere ? null : onStart,
      bg: recordingElsewhere ? AppColors.sokoShade4 : AppColors.sokoRed,
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final Color? bg;

  const _CircleBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 34,
    this.bg,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: size / 2 + 4,
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg ?? AppColors.sokoRed,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: size * 0.5, color: Colors.white),
        ),
      ),
    );
  }
}

class _ScopeButton extends StatelessWidget {
  final Widget icon;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onTap;

  const _ScopeButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.sokoInk : AppColors.sokoInkSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? Colors.white : AppColors.sokoShade5,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.sokoPink : AppColors.sokoShade4,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            icon,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.body(
                        fontSize: 11,
                        color: AppColors.sokoInkSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      style: AppTheme.body(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppColors.sokoInk,
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  final String title;
  const _Header({required this.title});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        title,
        style: const TextStyle(
          fontFamily: 'Zalando Sans',
          fontSize: 18,
          fontWeight: FontWeight.w500,
          height: 1.2,
          letterSpacing: -0.36,
          color: AppColors.sokoInk,
        ),
      ),
    ),
  );
}

class _SubmitFooter extends StatelessWidget {
  final String label;
  final VoidCallback onSubmit;
  final bool enabled;
  final bool loading;

  const _SubmitFooter({
    required this.label,
    required this.onSubmit,
    required this.enabled,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Container(
        color: AppColors.sokoPaper,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: SokoCtaButton(
          label: label,
          variant: SokoCtaVariant.pink,
          loading: loading,
          onPressed: enabled ? onSubmit : null,
        ),
      ),
    );
  }
}
