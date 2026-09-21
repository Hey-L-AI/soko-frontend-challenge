import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/soko_chat_bubble_shell.dart';
import '../../../shared/widgets/soko_turn_entrance.dart';
import '../../../shared/widgets/soko_typewriter_text.dart';
import '../../chat/widgets/search_status_indicator.dart';
import '../../chat/widgets/typing_indicator.dart';
import '../models/onboarding_chat_models.dart';
import '../providers/onboarding_chat_controller.dart';

typedef OnboardingContentBuilder =
    Widget Function(BuildContext context, OnboardingDeliveredTurn turn);

/// Scripted onboarding transcript with bottom-follow behavior independent of
/// the production chat screen's streaming model.
class OnboardingTranscript extends StatefulWidget {
  const OnboardingTranscript({
    super.key,
    required this.turns,
    required this.isTyping,
    this.searchingLabel,
    this.contentBuilder,
    this.onEditAnswer,
    this.scrollController,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 24),
  });

  static const followBottomThreshold = 64.0;

  /// Re-pin distance above which the bottom-follow eases in instead of snapping.
  /// A big jump (a card / image / carousel just landed) animates so it doesn't
  /// read as a drastic snap; small incremental settles below this jump instantly
  /// so the list never visibly lags live content growth.
  static const gentleRepinThreshold = 160.0;

  final List<OnboardingDeliveredTurn> turns;
  final bool isTyping;

  /// When non-null, a pulsing "searching…" progress label shows in the typing
  /// slot (before a content carousel). Mutually exclusive with [isTyping].
  final String? searchingLabel;
  final OnboardingContentBuilder? contentBuilder;

  /// When non-null, the user's name/city answer bubbles become tappable (with a
  /// trailing edit affordance) and invoke this with the tapped turn — the entry
  /// point for correcting an already-answered identity subturn. The screen
  /// passes it only while the edit window is open (still in the identity step).
  final void Function(OnboardingDeliveredTurn turn)? onEditAnswer;
  final ScrollController? scrollController;
  final EdgeInsets padding;

  /// Answer subturns that may be corrected via [onEditAnswer].
  static const _editableSubturns = <OnboardingSubturnId>{
    OnboardingSubturnId.identityName,
    OnboardingSubturnId.identityCity,
  };

  @override
  State<OnboardingTranscript> createState() => _OnboardingTranscriptState();
}

class _OnboardingTranscriptState extends State<OnboardingTranscript> {
  late ScrollController _scrollController;
  late bool _ownsScrollController;
  bool _followBottom = true;
  bool _autoScrolling = false;

  /// True while the user is actively dragging the list. Auto-follow (the
  /// content-growth re-pin in [_handleMetrics]) is suppressed for the whole
  /// gesture so an image finishing loading mid-scroll can't yank them back to
  /// the bottom (PROD-3888).
  bool _userDragging = false;

  @override
  void initState() {
    super.initState();
    _attachController(widget.scrollController);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void didUpdateWidget(covariant OnboardingTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      _detachController();
      _attachController(widget.scrollController);
    }

    // A user's own send must always snap to the bottom, even if they'd scrolled
    // up — re-engage follow when the newest turn is the user's message. Soko
    // replies and the typing toggle keep the passive behavior (follow only if
    // already at the bottom), so scrolling up mid-delivery to read isn't undone.
    final grew = widget.turns.length > oldWidget.turns.length;
    if (grew && widget.turns.last.actor == OnboardingTurnActor.user) {
      _followBottom = true;
    }

    if (_followBottom &&
        (oldWidget.turns.length != widget.turns.length ||
            oldWidget.isTyping != widget.isTyping ||
            oldWidget.searchingLabel != widget.searchingLabel)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  /// Re-pin to the bottom as content grows (reply carousels/cards, images, the
  /// typing indicator being replaced by real bubbles, entrance animations) over
  /// the frames after a send. [ScrollMetricsNotification] fires when the scroll
  /// metrics change from content growth rather than user scrolling, so it catches
  /// the growth the single-frame [_scrollToBottom] measured too early to include.
  /// Gated on [_followBottom], so a manual scroll-up (see [_handleScroll]) stops
  /// the re-pinning.
  bool _handleMetrics(ScrollMetricsNotification notification) {
    if (_followBottom &&
        !_autoScrolling &&
        !_userDragging &&
        _scrollController.hasClients &&
        _scrollController.position.extentAfter > 0) {
      _repinToBottom();
    }
    return false;
  }

  /// Re-pin the list to the bottom as content grows. A large gap (past
  /// [gentleRepinThreshold]) eases in over [OnboardingChatController.bubbleEntranceDuration]
  /// so a landing card/image doesn't snap drastically; small settles (and
  /// reduce-motion) jump instantly. Guarded by [_autoScrolling] so the metrics
  /// notifications that fire during the animation don't stack more animations.
  void _repinToBottom() {
    final position = _scrollController.position;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion ||
        position.extentAfter < OnboardingTranscript.gentleRepinThreshold) {
      position.jumpTo(position.maxScrollExtent);
      return;
    }
    _autoScrolling = true;
    position
        .animateTo(
          position.maxScrollExtent,
          duration: OnboardingChatController.bubbleEntranceDuration,
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() => _autoScrolling = false);
  }

  void _attachController(ScrollController? controller) {
    _ownsScrollController = controller == null;
    _scrollController = controller ?? ScrollController();
  }

  void _detachController() {
    if (_ownsScrollController) _scrollController.dispose();
  }

  @override
  void dispose() {
    _detachController();
    super.dispose();
  }

  bool _handleScroll(ScrollNotification notification) {
    // Grabbing the list hands control to the user: stop auto-following for the
    // whole gesture so a late layout change can't fight the scroll.
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null) {
        _userDragging = true;
        _followBottom = false;
      }
      return false;
    }
    // On release (drag end or the ballistic settle after a fling), resume
    // following only if they came to rest at (or near) the bottom. Never
    // recompute during a programmatic auto-scroll.
    if (notification is ScrollEndNotification) {
      _userDragging = false;
      if (!_autoScrolling) {
        _followBottom =
            notification.metrics.extentAfter <=
            OnboardingTranscript.followBottomThreshold;
      }
      return false;
    }

    final isUserUpdate =
        notification is ScrollUpdateNotification &&
        notification.dragDetails != null;
    final isUserOverscroll =
        notification is OverscrollNotification &&
        notification.dragDetails != null;
    if (!_autoScrolling && (isUserUpdate || isUserOverscroll)) {
      _followBottom =
          notification.metrics.extentAfter <=
          OnboardingTranscript.followBottomThreshold;
    }
    return false;
  }

  Future<void> _scrollToBottom() async {
    if (!mounted || !_followBottom || !_scrollController.hasClients) return;

    _autoScrolling = true;
    final position = _scrollController.position;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    try {
      if (reduceMotion) {
        position.jumpTo(position.maxScrollExtent);
      } else {
        await position.animateTo(
          position.maxScrollExtent,
          duration: OnboardingChatController.bubbleEntranceDuration,
          curve: Curves.easeOutCubic,
        );
      }
    } finally {
      _autoScrolling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final showTyping = widget.isTyping && !reduceMotion;
    // A content carousel's "searching…" beat. Mutually exclusive with the
    // typing dots (message vs. content turn); suppressed under reduce-motion.
    final searchingLabel = reduceMotion ? null : widget.searchingLabel;

    final turns = widget.turns;
    final children = <Widget>[
      for (var i = 0; i < turns.length; i++)
        _turnItem(
          context,
          turns[i],
          i > 0 ? turns[i - 1] : null,
          i + 1 < turns.length ? turns[i + 1] : null,
        ),
      if (showTyping) const TypingIndicator(key: Key('onboarding-typing')),
      if (searchingLabel != null)
        SearchStatusIndicator(
          key: const Key('onboarding-searching'),
          text: searchingLabel,
        ),
    ];

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: _handleMetrics,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScroll,
        // Bottom-anchored, not top-anchored: a chat reads bottom-up, so messages
        // hug the composer and grow upward, and only scroll once they exceed the
        // viewport. A plain top-aligned ListView instead pinned a short
        // transcript (e.g. the two name-step bubbles) to the top and left a big
        // empty gap down to the composer (PROD-3888). The ConstrainedBox floors
        // the content column at the viewport height so `mainAxisAlignment.end`
        // has room to push short content to the bottom; tall content overflows
        // it and scrolls as before.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final minHeight = (constraints.maxHeight - widget.padding.vertical)
                .clamp(0.0, double.infinity);
            return SingleChildScrollView(
              key: const Key('onboarding-transcript-list'),
              controller: _scrollController,
              padding: widget.padding,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: minHeight),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: children,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _turnItem(
    BuildContext context,
    OnboardingDeliveredTurn turn,
    OnboardingDeliveredTurn? prev,
    OnboardingDeliveredTurn? next,
  ) {
    final content = _buildTurn(context, turn, prev, next);
    // Turns that render nothing (dropped action buttons once their step is
    // answered, empty user-answer turns) must not contribute the between-turns
    // gap — otherwise an invisible turn wedged between two bubbles doubles the
    // spacing (its bottom padding + the prior bubble's). Skip the padding +
    // entrance for those.
    if (_rendersNothing(content)) {
      return SizedBox.shrink(key: ValueKey(turn.id));
    }
    return Padding(
      key: ValueKey(turn.id),
      padding: EdgeInsets.only(bottom: _gapAfter(turn, next)),
      child: SokoTurnEntrance(
        animate: turn.animate,
        beginOffset: _entranceOffset(turn),
        child: content,
      ),
    );
  }

  /// The newest turn slides in from its aligned side — user turns from the right,
  /// Soko turns (messages + content cards) from the left — a subtle 6% of the
  /// turn width. Reads as gentler than the previous straight-up slide when the
  /// list re-pins to the bottom.
  static Offset _entranceOffset(OnboardingDeliveredTurn turn) {
    return turn.actor == OnboardingTurnActor.user
        ? const Offset(0.06, 0)
        : const Offset(-0.06, 0);
  }

  /// Bubble-free spacing (no dividers): a tight paragraph gap between two of
  /// Soko's own consecutive plain-text messages in the same group, and a larger
  /// gap at a group boundary (a new subturn, a switch to/from the user, or a
  /// content card) so the transcript reads as airy Claude-style sections.
  static double _gapAfter(
    OnboardingDeliveredTurn turn,
    OnboardingDeliveredTurn? next,
  ) {
    if (next == null) return 24;
    // Two stacked user bubbles hug together (Instagram grouping): a tight 3-px
    // seam so the collapsed tail-side corners read as one connected column.
    if (_isUserBubble(turn) && _isUserBubble(next)) return 3;
    final bothSokoMessages =
        turn.kind == OnboardingTurnKind.message &&
        turn.actor == OnboardingTurnActor.soko &&
        next.kind == OnboardingTurnKind.message &&
        next.actor == OnboardingTurnActor.soko &&
        turn.subturnId == next.subturnId;
    if (bothSokoMessages) return 8;
    return turn.subturnId == next.subturnId ? 14 : 24;
  }

  /// A turn that renders as the user's pink bubble: a non-empty user message.
  /// (Empty user answers render nothing — see [_buildTurn].)
  static bool _isUserBubble(OnboardingDeliveredTurn? t) =>
      t != null &&
      t.kind == OnboardingTurnKind.message &&
      t.actor == OnboardingTurnActor.user &&
      (t.text?.trim().isNotEmpty ?? false);

  /// Whether a built turn widget is an empty placeholder (`SizedBox.shrink()`),
  /// returned by `_buildTurn` for empty user answers and by the screen's
  /// `contentBuilder` for action turns that have been dropped from history.
  static bool _rendersNothing(Widget child) =>
      child is SizedBox && child.width == 0 && child.height == 0;

  /// The user's pink reply bubble. When [editable], a trailing pencil is shown
  /// and the whole bubble becomes a tap target for [OnboardingTranscript.onEditAnswer].
  Widget _userBubble(
    BuildContext context,
    OnboardingDeliveredTurn turn,
    OnboardingDeliveredTurn? prev,
    OnboardingDeliveredTurn? next,
    bool editable,
  ) {
    final text = Text(
      turn.text ?? '',
      // Figma 7285:23397 — Mobile/B2 Reg: Zalando Sans Light, 14, 1.2.
      style: AppTheme.body(
        fontSize: 14,
        fontWeight: FontWeight.w300,
        height: 1.2,
        color: AppColors.sokoInk,
      ),
    );

    final bubble = SokoChatBubbleShell(
      isUser: true,
      backgroundColor: AppColors.sokoPink,
      borderRadius: sokoUserBubbleRadius(
        prevIsUser: _isUserBubble(prev),
        nextIsUser: _isUserBubble(next),
      ),
      // Figma 7285:23397 is 14×12, but the tighter 8-px vertical reads
      // better for these short one-line replies (product decision).
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: editable
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: text),
                const SizedBox(width: 6),
                Icon(
                  Icons.edit_outlined,
                  size: 13,
                  color: AppColors.sokoInk.withValues(alpha: 0.55),
                ),
              ],
            )
          : text,
    );

    if (!editable) return bubble;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onEditAnswer!(turn),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: bubble),
    );
  }

  Widget _buildTurn(
    BuildContext context,
    OnboardingDeliveredTurn turn,
    OnboardingDeliveredTurn? prev,
    OnboardingDeliveredTurn? next,
  ) {
    if (turn.kind == OnboardingTurnKind.content) {
      return widget.contentBuilder?.call(context, turn) ??
          const SizedBox.shrink();
    }

    final isUser = turn.actor == OnboardingTurnActor.user;
    // Some answers (e.g. the vibe {liked, disliked} map) carry no human-readable
    // text — the answer is captured by the cards themselves. Render nothing
    // rather than an empty pink bubble (or, historically, raw JSON on resume).
    if (isUser && (turn.text?.trim().isEmpty ?? true)) {
      return const SizedBox.shrink();
    }

    // Correctable name/city bubbles (only while the screen supplies
    // `onEditAnswer`) get a trailing pencil and a tap target that re-opens the
    // matching composer.
    final editable =
        isUser &&
        widget.onEditAnswer != null &&
        OnboardingTranscript._editableSubturns.contains(turn.subturnId) &&
        (turn.text?.trim().isNotEmpty ?? false);

    // Soko speaks in plain text (Claude-style) — no bubble; the USER's replies
    // keep the pink bubble so the two voices stay distinct.
    final Widget content = isUser
        ? _userBubble(context, turn, prev, next, editable)
        : Builder(
            builder: (context) {
              final sokoStyle = AppTheme.body(
                fontSize: 16,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: AppColors.sokoInk,
              );
              // Freshly-delivered Soko lines type out character-by-character;
              // history/resume turns (animate == false) render whole. The
              // widget also falls back to full text under reduce-motion.
              return turn.animate
                  ? SokoTypewriterText(text: turn.text ?? '', style: sokoStyle)
                  : Text(turn.text ?? '', style: sokoStyle);
            },
          );

    return Semantics(
      liveRegion: turn.animate,
      child: AnimatedOpacity(
        opacity: turn.isPending ? 0.65 : 1,
        duration: OnboardingChatController.bubbleEntranceDuration,
        child: content,
      ),
    );
  }
}
