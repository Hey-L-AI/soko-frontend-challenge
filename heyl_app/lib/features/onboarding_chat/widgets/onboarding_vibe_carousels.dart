import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/entity_signal.dart';
import '../../../data/models/vibe_candidate.dart';
import '../../../shared/widgets/soko_tag.dart';
import '../../chat/widgets/search_status_indicator.dart';
import '../../entity_signals/providers/signal_controller.dart';
import '../providers/onboarding_vibe_controller.dart';
import 'onboarding_card_entrance.dart';
import 'onboarding_detail_page.dart';
import 'onboarding_vibe_card.dart';

typedef VibeShelfProvider =
    StateNotifierProvider<OnboardingVibeController, OnboardingVibeState>;

/// One thumbs-able vibe carousel (Sítios *or* Eventos), delivered inline in the
/// transcript as a content turn. Owns its own [OnboardingVibeController] and
/// fires its own discovery request on first build.
class OnboardingVibeShelf extends ConsumerStatefulWidget {
  const OnboardingVibeShelf({
    super.key,
    required this.provider,
    required this.label,
    required this.pillColor,
    required this.errorLabel,
    required this.retryLabel,
    required this.searchingLabel,
    this.persistedCandidateIds = const [],
  });

  final VibeShelfProvider provider;
  final String label;
  final Color pillColor;
  final String errorLabel;
  final String retryLabel;

  /// Shown in place of the shelf's card row while its own discovery fetch is
  /// still in flight (e.g. the transcript's searching-gate hit its cap, or the
  /// reduce-motion path skipped the gate). Keeps the single "Finding places/
  /// events for you…" text loader going instead of flashing a bare spinner —
  /// the cards then reveal via [OnboardingCardEntrance].
  final String searchingLabel;

  /// On resume, the ordered candidate ids this shelf showed last time. When
  /// non-empty the shelf re-hydrates exactly those cards (with their 👍/👎)
  /// instead of fetching a fresh discovery batch.
  final List<String> persistedCandidateIds;

  @override
  ConsumerState<OnboardingVibeShelf> createState() =>
      _OnboardingVibeShelfState();
}

class _OnboardingVibeShelfState extends ConsumerState<OnboardingVibeShelf> {
  // Fits a 2-line name + 2-line subtitle under the 140-px image (PROD-3888
  // follow-up): image 140 + 8 gap + name(2×) + 2 gap + subtitle(2×). Zalando
  // Sans's intrinsic line boxes made the old 226 overflow by ~6 px on the
  // worst case (2-line title AND 2-line subtitle); 234 clears it with a hair
  // of margin.
  static const _rowHeight = 234.0;

  /// Fire the `load_error`/`empty` funnel event at most once per shelf, so a
  /// rebuild (or retry) doesn't spam the funnel.
  bool _reportedLoadOutcome = false;

  // --- "Like me" glow nudge (PROD onboarding gate) ---------------------------
  // 1s after this shelf's cards appear, one randomly-chosen card that is
  // actually on screen breathes its 👍 (see [AttentionPulse]) to hint the user
  // must like ≥1 item to continue. The glow follows visibility — if its card
  // scrolls away it re-picks another visible card — and stops for good once the
  // shelf has a like.
  final Set<int> _visibleCards = {};
  int? _glowIndex;
  bool _glowArmed = false;
  Timer? _glowStartTimer;
  final Random _rng = Random();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref
            .read(widget.provider.notifier)
            .load(candidateIds: widget.persistedCandidateIds);
      }
    });
  }

  @override
  void dispose() {
    _glowStartTimer?.cancel();
    super.dispose();
  }

  /// Arm the 1-second delay once the shelf first has cards to show. Guarded so
  /// it runs at most once, and skipped under reduce-motion or if the user has
  /// already liked (no nudge needed).
  void _armGlow(OnboardingVibeState state) {
    if (_glowArmed || _glowStartTimer != null) return;
    if (!state.hasLoaded || state.isEmpty || state.likedIds.isNotEmpty) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    _glowStartTimer = Timer(const Duration(seconds: 1), () {
      _glowStartTimer = null;
      if (!mounted) return;
      _glowArmed = true;
      _pickGlowCard();
    });
  }

  /// Choose the card to glow: keep the current one while it stays visible,
  /// otherwise pick a random currently-visible card. Clears the glow when the
  /// nudge is no longer eligible (liked, or nothing visible).
  void _pickGlowCard() {
    if (!mounted || !_glowArmed) return;
    final liked = ref.read(widget.provider).likedIds.isNotEmpty;
    if (liked || _visibleCards.isEmpty) {
      if (_glowIndex != null) setState(() => _glowIndex = null);
      return;
    }
    if (_glowIndex != null && _visibleCards.contains(_glowIndex)) return;
    final choices = _visibleCards.toList();
    setState(() => _glowIndex = choices[_rng.nextInt(choices.length)]);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(widget.provider);
    final controller = ref.read(widget.provider.notifier);

    // Start the 1s countdown to the like nudge once cards are on screen.
    _armGlow(state);

    // Report a resolved-but-unusable shelf once — the state already handles
    // these gracefully (retry / hidden), but the funnel was blind to them.
    ref.listen<OnboardingVibeState>(widget.provider, (_, next) {
      if (_reportedLoadOutcome || !next.hasLoaded) return;
      if (next.error != null && next.isEmpty) {
        _reportedLoadOutcome = true;
        _trackVibe('load_error');
      } else if (next.isEmpty) {
        _reportedLoadOutcome = true;
        _trackVibe('empty');
      }
    });

    // A shelf that finished loading with nothing to show hides entirely —
    // otherwise its divider + "Eventos"/"Sítios" label leave an orphaned empty
    // block on screen (PROD-3888). The error state still renders below (retry),
    // and the loading spinner still shows while the fetch is in flight.
    if (state.hasLoaded && state.error == null && state.isEmpty) {
      return const SizedBox.shrink();
    }

    // Figma 7285:23751: a hairline divider brackets each shelf, a small Tag
    // pill labels it, then the 105-wide card row.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, thickness: 1, color: AppColors.sokoInk8),
        const SizedBox(height: 10),
        SokoTag(
          background: widget.pillColor,
          child: Text(widget.label, style: SokoTag.textStyle),
        ),
        const SizedBox(height: 10),
        SizedBox(height: _rowHeight, child: _body(state, controller)),
      ],
    );
  }

  /// Fires the `onboarding_step` funnel event for a vibe-taste interaction.
  void _trackVibe(String action) {
    ref
        .read(unifiedAnalyticsProvider)
        .trackOnboardingStep(step: 'vibe.taste', action: action);
  }

  /// Toggle a thumb, then fire the funnel event for the CONFIRMED server result
  /// (not the tap intent). The signal endpoint is a toggle, so a tap on a held
  /// sentiment clears it — the funnel records that as an undo, and a failed
  /// write as an error, so like counts reflect what actually persisted.
  Future<void> _thumbAndTrack(
    OnboardingVibeController controller,
    VibeCandidate candidate,
    SignalAction action,
  ) async {
    final result = await controller.toggle(candidate, action);
    final String trackAction;
    if (result == null) {
      trackAction = 'thumb_error';
    } else if (action == SignalAction.like) {
      trackAction = result == SignalTaste.liked ? 'thumb_up' : 'thumb_up_undo';
    } else {
      trackAction = result == SignalTaste.disliked
          ? 'thumb_down'
          : 'thumb_down_undo';
    }
    _trackVibe(trackAction);
  }

  /// Opens the tapped card's detail as a full-screen, read-only page pushed on
  /// the root navigator (over the onboarding gate) — a real back button (or a
  /// 👍/👎, which auto-closes the detail) pops straight back to onboarding, and
  /// the sandboxed body hides every external link / cross-screen nav.
  ///
  /// The detail's 👍/👎 write to the shared [signalControllerProvider], not this
  /// shelf's local [OnboardingVibeState.sentiments], so on return we re-sync the
  /// card's taste from that shared store — otherwise a like made inside the
  /// detail wouldn't show on the shelf card outside it. We hold the (autoDispose)
  /// controller alive across the push with [WidgetRef.listenManual] (the detail
  /// is its only other listener), then mirror the reconciled taste back into the
  /// shelf. Mirrors `_openSearchItemDetail` in `onboarding_identity_name_screen.dart`.
  Future<void> _openDetail(
    OnboardingVibeController controller,
    VibeCandidate candidate,
  ) async {
    final id = candidate.entityId;
    if (id.isEmpty) return;
    _trackVibe('card_tap');
    final key = (type: candidate.type.signalType, id: id);
    final sub = ref.listenManual(signalControllerProvider(key), (_, __) {});
    try {
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) =>
              OnboardingDetailPage(type: candidate.type, entityId: id),
        ),
      );
      if (!mounted) return;
      controller.syncTaste(
        id,
        ref.read(signalControllerProvider(key)).signal.taste,
      );
    } finally {
      sub.close();
    }
  }

  Widget _body(OnboardingVibeState state, OnboardingVibeController controller) {
    if (state.isLoading && state.isEmpty) {
      // Continue the single text loader instead of a bare spinner. Under reduce
      // motion the pulsing indicator is suppressed for a static label.
      final reduceMotion =
          MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      return reduceMotion
          ? Align(
              alignment: Alignment.topLeft,
              child: Text(
                widget.searchingLabel,
                style: AppTheme.body(fontSize: 14, color: AppColors.sokoInk),
              ),
            )
          : SearchStatusIndicator(text: widget.searchingLabel);
    }
    if (state.error != null && state.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.errorLabel,
              textAlign: TextAlign.center,
              style: AppTheme.body(fontSize: 14, color: AppColors.sokoInk),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: controller.load,
              child: Text(
                widget.retryLabel,
                style: AppTheme.body(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (state.isEmpty) return const SizedBox.shrink();

    // Render the whole fetched batch. The horizontal list builds cards lazily as
    // they scroll into view, so scrolling reveals more — no "see more" gate (the
    // discovery endpoint isn't paginated, so this single batch is all there is).
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      itemCount: state.candidates.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10),
      itemBuilder: (context, index) {
        final candidate = state.candidates[index];
        // Gate the glow on the live state too, so a like stops it this frame —
        // no wait for a visibility tick to re-evaluate.
        final glowing =
            _glowArmed && state.likedIds.isEmpty && index == _glowIndex;
        return VisibilityDetector(
          key: Key('vibe-glow-${candidate.entityId}'),
          onVisibilityChanged: (info) {
            final seen = info.visibleFraction >= 0.6;
            final changed = seen
                ? _visibleCards.add(index)
                : _visibleCards.remove(index);
            if (changed && _glowArmed) _pickGlowCard();
          },
          child: OnboardingCardEntrance(
            index: index,
            child: OnboardingVibeCard(
              candidate: candidate,
              taste: state.tasteFor(candidate.entityId),
              highlightLike: glowing,
              onLike: () =>
                  _thumbAndTrack(controller, candidate, SignalAction.like),
              onDislike: () =>
                  _thumbAndTrack(controller, candidate, SignalAction.dislike),
              onTap: () => _openDetail(controller, candidate),
            ),
          ),
        );
      },
    );
  }
}
