import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/experiment_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/chat_search_label.dart';
import '../../../providers/sidebar_provider.dart';
import '../../../providers/voice_recorder_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/chat_bar.dart';
import '../../chat/widgets/typing_placeholder_controller.dart';
import '../../chat/widgets/voice_recorder_widget.dart';
import 'create_menu_sheet.dart';
import 'discovery_typeahead_overlay.dart';

/// Discovery / chat-empty-state composer (PROD-1517, simplified in
/// PROD-1894).
///
/// Single-row composer: text input with rotating typewriter placeholder,
/// mic, send. There is no bottom row on this surface — the bottom row
/// (Create-list pill) only appears in [MessageInput] when the active
/// conversation has saveable cards.
///
/// Wiring:
/// - typewriter via [TypingPlaceholderController] + `heroPlaceholder1..16`,
/// - send via the existing `autoSendMessage` route extra on `/chat`,
/// - mic gated by [ExperimentService.enableVoiceMessages] and recording
///   via [VoiceRecorderWidget].
///
/// Visual + behavior shared with the chat composer at the bottom of
/// [ChatScreen] via the `shared/widgets/chat_bar.dart` primitives (PROD-1804).
class DiscoveryChatBar extends ConsumerStatefulWidget {
  /// Forwarded to the inner text field. The Discovery home composer
  /// stays unfocused on mount (default `false`); the chat empty state
  /// passes `true` so the soft keyboard opens immediately.
  final bool autofocus;

  /// When true (Discovery surface only), focusing the input opens the
  /// typeahead overlay (PROD-1909). The chat empty state passes `false`
  /// so its behavior is unchanged from PROD-1894.
  final bool enableTypeaheadOnFocus;

  /// When true (Discovery surface only), render the bottom row with the
  /// "Adiciona à Soko" pill, history button, and WhatsApp deep-link.
  /// The chat surfaces (conversation + empty state) keep the simpler
  /// PROD-1894 layout — top row only.
  final bool showDiscoveryActions;

  /// When true (chat empty state), render a slim bottom strip hosting a
  /// History button on the right — same styled box that hosts Create-list
  /// on the conversation composer. Mutually exclusive with
  /// [showDiscoveryActions] (Discovery owns its own bottom row).
  final bool showHistory;

  /// When true (chat empty state), render the chat composer style: the
  /// outlined paper capsule (Figma `7507:27889`) with bare send/mic icons and
  /// the leading clear/search affordance (X when there's text, else a search
  /// glyph). The Discovery home composer keeps its blurred `Soko/Shade5` bar
  /// and chromed buttons (default false).
  final bool outlined;

  const DiscoveryChatBar({
    super.key,
    this.autofocus = false,
    this.enableTypeaheadOnFocus = false,
    this.showDiscoveryActions = false,
    this.showHistory = false,
    this.outlined = false,
  });

  @override
  ConsumerState<DiscoveryChatBar> createState() => _DiscoveryChatBarState();
}

class _DiscoveryChatBarState extends ConsumerState<DiscoveryChatBar> {
  final _controller = TextEditingController();
  late final FocusNode _focusNode;
  late final TypingPlaceholderController _typingController;
  List<String> _lastPhrases = const [];
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
    _focusNode.addListener(_onFocusChanged);
    _typingController = TypingPlaceholderController(const []);
    _controller.addListener(_onTextChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final phrases = _localizedPhrases();
    if (!listEquals(phrases, _lastPhrases)) {
      _lastPhrases = phrases;
      _typingController.restart(phrases);
      // Pause immediately if the user is already typing when locale changes.
      if (_hasText) _typingController.pause();
    }

    // Pause the typing animation when this route is no longer the
    // current one — i.e. the user pushed a detail page (`/venues/...`,
    // `/events/...`, etc.) on top. The discovery screen stays mounted
    // in the Navigator stack but its layout boundary is no longer the
    // active one; letting the [AnimatedBuilder] consuming
    // [_typingController] keep ticking causes
    // `_debugRelayoutBoundaryAlreadyMarkedNeedsLayout` assertions to
    // fire every frame on the covered tree (paragraph 539→419 → set
    // text → markNeedsLayout). Pausing here is reactive: changes to
    // `isCurrent` propagate through `_ModalScopeStatus` and rebuild
    // this dependent. `didChangeDependencies` runs each rebuild.
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (!isCurrent && !_typingController.isPaused) {
      _typingController.pause();
    } else if (isCurrent && _typingController.isPaused && !_hasText) {
      _typingController.resume();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _typingController.dispose();
    super.dispose();
  }

  List<String> _localizedPhrases() {
    final l10n = Lt.of(context);
    return [
      l10n.heroPlaceholder1,
      l10n.heroPlaceholder2,
      l10n.heroPlaceholder3,
      l10n.heroPlaceholder4,
      l10n.heroPlaceholder5,
      l10n.heroPlaceholder6,
      l10n.heroPlaceholder7,
      l10n.heroPlaceholder8,
      l10n.heroPlaceholder9,
      l10n.heroPlaceholder10,
      l10n.heroPlaceholder11,
      l10n.heroPlaceholder12,
      l10n.heroPlaceholder13,
      l10n.heroPlaceholder14,
      l10n.heroPlaceholder15,
      l10n.heroPlaceholder16,
    ];
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText == _hasText) return;
    setState(() => _hasText = hasText);
    if (hasText) {
      _typingController.pause();
    } else {
      _typingController.resume();
    }
  }

  /// On focus, hand off to the typeahead overlay (PROD-1909). Only fires
  /// when the parent has explicitly opted in via [enableTypeaheadOnFocus]
  /// — i.e. the Discovery surface. The chat empty state opts out so its
  /// composer keeps PROD-1894 behavior exactly.
  ///
  /// Defers the unfocus + dialog push to the next frame to avoid mutating
  /// focus state inside a focus-change callback (mirrors the post-frame
  /// pattern in `discovery_action_bar.dart:96-99`).
  void _onFocusChanged() {
    if (!widget.enableTypeaheadOnFocus) return;
    if (!_focusNode.hasFocus) return;
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_focusNode.hasFocus) return; // user dismissed between frames
      _focusNode.unfocus();
      final query = _controller.text;
      // Clear so when the overlay closes the bar returns to the
      // typewriter placeholder instead of stale text; the overlay
      // seeds its own controller from `initialQuery`.
      _controller.clear();
      showDiscoveryTypeahead(context, initialQuery: query);
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      if (_hasText) {
        _handleSend();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    // PROD-3168: sending from the home composer opens a conversation.
    ref
        .read(unifiedAnalyticsProvider)
        .trackChatOpen(entryPoint: EntryPoint.homeInput);
    _controller.clear();
    context.go(AppRoutes.chat, extra: {'autoSendMessage': text});
  }

  void _handleHistoryTap() {
    if (!mounted) return;
    ref.read(sidebarOpenProvider.notifier).state = true;
  }

  void _handleAddTap() {
    // Opens (or closes) the same Create sheet as the "Criar" bottom-nav
    // tab — single entry point for the create flows (suggest
    // place/event, share from Instagram, new zine, new memory). The
    // toggle behavior mirrors the bottom nav: a second tap dismisses
    // the sheet, matching the "any click outside the modal closes it"
    // rule in PROD-1952.
    CreateMenuSheet.toggle(context, ref, entryPoint: EntryPoint.homeTopPink);
  }

  Future<void> _handleMicTap() async {
    final notifier = ref.read(voiceRecorderProvider.notifier);
    await notifier.startRecording();
    if (!mounted) return;
    final l10n = Lt.of(context);
    final state = ref.read(voiceRecorderProvider);
    if (state.status == RecorderStatus.permissionDenied ||
        state.status == RecorderStatus.permissionDeniedForever) {
      showSoko(
        ref,
        message: l10n.voicePermissionDeniedContent,
        variant: SokoVariant.error,
      );
    } else if (state.status == RecorderStatus.error) {
      showSoko(
        ref,
        message: l10n.voiceRecordingError,
        variant: SokoVariant.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // When this composer is configured to autofocus (chat empty state),
    // re-grab focus the moment the sidebar closes — `ChatSidebarDrawer`
    // drops focus on open so the keyboard collapses, and the user
    // expects to land back in the composer with the keyboard re-open on
    // dismiss. No-op on the Discovery surface (autofocus stays false).
    ref.listen<bool>(sidebarOpenProvider, (prev, next) {
      if (widget.autofocus && prev == true && !next && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusNode.requestFocus();
        });
      }
    });

    final experiments = ref.watch(experimentServiceProvider);
    final voiceEnabled = experiments.enableVoiceMessages;
    final isRecording = voiceEnabled
        ? ref.watch(voiceRecorderProvider.select((s) => s.isRecording))
        : false;

    final isDesktop = MediaQuery.of(context).size.width >= 1024;

    Widget bar = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isRecording)
          // TODO(prod-1517-followup): VoiceRecorderWidget chrome was
          // designed for the chat MessageInput pill — revisit when
          // designer specs the recording state for the new chat bar.
          Container(
            decoration: const BoxDecoration(
              color: Color(0xFFF1E5E6), // sokoShade5
              borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
            ),
            padding: const EdgeInsets.all(10),
            child: VoiceRecorderWidget(
              onCancel: () =>
                  ref.read(voiceRecorderProvider.notifier).cancelRecording(),
              onStopAndSend: () async {
                await ref.read(voiceRecorderProvider.notifier).stopRecording();
              },
            ),
          )
        else
          ChatBarTopRow(
            controller: _controller,
            focusNode: _focusNode,
            typingController: _typingController,
            placeholder: '',
            hasText: _hasText,
            voiceEnabled: voiceEnabled,
            onSend: _handleSend,
            onMicTap: _handleMicTap,
            onClear: widget.outlined ? _controller.clear : null,
            outlined: widget.outlined,
            autofocus: widget.autofocus,
          ),
        // Discovery-only bottom row (Add-to-Soko / history / WhatsApp).
        // Removed from the chat MessageInput in PROD-1894; restored
        // on the Discovery surface (opt-in via `showDiscoveryActions`)
        // so the home composer keeps the original three shortcuts.
        // Hidden while voice recording so the recorder owns the full
        // bar silhouette.
        if (widget.showDiscoveryActions && !isRecording)
          ChatBarDiscoveryBottomRow(
            onAddTap: _handleAddTap,
            onHistoryTap: _handleHistoryTap,
          )
        // Chat empty state opts in to the slim history-only strip — same
        // styled box that the conversation composer uses for Create-list.
        // It also leads with the read-only search-location label so the
        // per-conversation center C is visible on join, not only once the
        // first message flips the screen into the conversation composer.
        else if (widget.showHistory && !isRecording)
          ChatBarBottomRow(
            searchLocationLabel: chatSearchLabelText(
              ref.watch(chatSearchLocationLabelProvider),
              Lt.of(context),
            ),
            onHistoryTap: _handleHistoryTap,
          ),
      ],
    );

    // TODO(desktop-redesign): no desktop designs yet. Cap the bar width on
    // wide viewports so it doesn't stretch the full DiscoveryShell column.
    if (isDesktop) {
      bar = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: bar,
        ),
      );
    }

    // PROD-1804: Hero-animate the bar's geometry from Discovery (top) to
    // ChatScreen (bottom) when sending starts a new session. Tag must match
    // the chat composer's Hero tag in `message_input.dart`.
    return Hero(
      tag: kChatBarHeroTag,
      // Material wrapper makes ink-well children render correctly during the
      // flight overlay. Color: transparent so the Hero overlay doesn't paint
      // a stray background while the bar is in mid-air.
      child: Material(color: Colors.transparent, child: bar),
    );
  }
}
