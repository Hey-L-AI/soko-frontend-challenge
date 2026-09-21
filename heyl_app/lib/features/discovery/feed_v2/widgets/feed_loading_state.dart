// The feed's loading state — a rotating illustration that breathes, and one
// line naming what is being looked for (Zé, 2026-09-07).
//
// The backend composes a personalised feed, and in some cases that takes up to
// ~10 s. A bare `CircularProgressIndicator` held for ten seconds reads as a
// hang, so the wait borrows the shape of the feed's own end card
// ([FeedEndBlock]): illustration, `kFeedPageBlockGap`, one centred `Mobile/H3`.
//
// **The illustration cycles, one drawing per breath, in a per-mount random
// order.** Five of the app's ink figures take turns — see
// [kFeedLoadingIllustrations]. A single static image for ten seconds is still a
// page that looks stuck; a changing one is the clearest signal available that
// something is happening, and it costs no new binaries because all five already
// ship for other surfaces. The order is shuffled on every mount (Zé,
// 2026-09-07) so a reader who opens the app twice is not met by the same
// drawing both times.
//
// **Why the breath goes all the way to transparent.** The swap happens at the
// trough, so at zero opacity the cut between two drawings is invisible and each
// figure gets one clean fade-in / fade-out. A shallower pulse would leave the
// swap visible as a hard jump at 45 % opacity.
//
// **The pulse is the only motion**, which is why there is no spinner
// underneath: two things animating at different rates for the same wait is one
// too many.
//
// **The copy is per filter.** "We are finding things for you" only reassures
// when it names the thing, so each feed gets its own line. `people` has no feed
// to load (D131, `FeedFilter.isEnabledInV0`) and so cannot reach this widget
// today — its line exists to keep the switch exhaustive rather than let a
// future people feed borrow another entity's words.

import 'dart:math' show Random;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../../data/models/feed_home.dart';
import '../../../../l10n/generated/l10n.dart';
import 'blocks/feed_block_atoms.dart';
import 'blocks/feed_end_block.dart';
import 'feed_page_content.dart';

/// The drawings the wait cycles through (Zé, 2026-09-07).
///
/// **This list is the SET, not the order** — [FeedLoadingState] shuffles a copy
/// on every mount. Declaration order here therefore means nothing at runtime,
/// and a test that wants a known sequence must pass its own seeded [Random]
/// rather than assume this one.
///
/// The persona figures come from `assets/images/personas/`, **not** the
/// `personas/cards/` siblings — those are the tilted paper-card stacks
/// (880 × 994, portrait) and would letterbox badly in a 115 px-tall slot.
const List<String> kFeedLoadingIllustrations = <String>[
  // The figure with binoculars — also `banner_chat`'s art and the profile
  // "discover people" empty state.
  'assets/images/illustrations/soko-binoculars.png',
  'assets/images/personas/local_at_heart.png',
  'assets/images/illustrations/soko-with-camera.webp',
  'assets/images/personas/conscious_outdoors.png',
  // `banner_map`'s art.
  'assets/images/illustrations/soko-with-wine.png',
];

/// Shared across mounts so two loading states in the same session do not get
/// identical orders from two generators seeded off the same clock tick.
final Random _shuffleRandom = Random();

class FeedLoadingState extends StatefulWidget {
  /// The feed being composed — the one the copy names. On a filter change this
  /// is already the INCOMING filter (`feedHomeProvider.build` watches the same
  /// provider), so the line describes what is arriving, not what is leaving.
  final FeedFilter filter;

  /// Source of the per-mount shuffle. Injected only so a widget test can pin
  /// the sequence with a seed; production always takes the shared generator.
  @visibleForTesting
  final Random? random;

  const FeedLoadingState({super.key, required this.filter, this.random});

  /// Matched to the end card's illustration so the two waypoints of a feed —
  /// "still looking" and "that's all" — are the same size.
  static const double illustrationSize = FeedEndBlock.illustrationSize;

  /// One direction of the breath: fade in over this, fade out over this, then
  /// swap. So each drawing is on screen for twice this long.
  ///
  /// Deliberately long. A fast pulse reads as a throbber and makes the wait
  /// feel worse, which is the opposite of the point.
  static const Duration pulsePeriod = Duration(milliseconds: 1400);

  /// The scale at the trough. Small enough to be felt rather than seen — the
  /// opacity carries the breath, this only keeps it from reading as a flat
  /// dissolve.
  static const double _minScale = 0.94;

  /// Space above and below, so the element sits in the feed area rather than
  /// against the filter row above it.
  static const double _verticalPadding = 48;

  @override
  State<FeedLoadingState> createState() => _FeedLoadingStateState();
}

class _FeedLoadingStateState extends State<FeedLoadingState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: FeedLoadingState.pulsePeriod,
  );

  late final Animation<double> _breath = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  /// The order this mount will show them in.
  ///
  /// Shuffled once, here, rather than picked fresh at each swap: drawing at
  /// random each time would let the same figure come up twice in a row, which
  /// reads as the animation having stalled — the exact impression the whole
  /// element exists to prevent. A permutation cannot repeat until it wraps, and
  /// wrapping needs `5 × 2 × pulsePeriod` = 14 s, past the worst wait.
  late final List<String> _order = List<String>.of(kFeedLoadingIllustrations)
    ..shuffle(widget.random ?? _shuffleRandom);

  int _index = 0;
  bool _precached = false;

  @override
  void initState() {
    super.initState();
    // **Driven by hand rather than `repeat(reverse: true)`**, because the swap
    // has to happen at the trough and `repeat` never reports one: it runs off a
    // simulation whose status stays `forward` for the whole cycle, turning
    // points included. Explicit forward/reverse gives `dismissed` at the bottom
    // of every breath, which is exactly the moment the drawing may change.
    _controller.addStatusListener(_onPulseStatus);
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Decode all five up front. The swap is on a timer, so a drawing that has
    // to be decoded when its turn comes would fade in as an empty box.
    if (_precached) return;
    _precached = true;
    for (final asset in kFeedLoadingIllustrations) {
      precacheImage(AssetImage(asset), context);
    }
  }

  void _onPulseStatus(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.completed:
        _controller.reverse();
      case AnimationStatus.dismissed:
        // Fully transparent right now, so the cut is invisible.
        setState(() => _index = (_index + 1) % _order.length);
        _controller.forward();
      case AnimationStatus.forward:
      case AnimationStatus.reverse:
        break;
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onPulseStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    // Reduce Motion holds the first drawing still — no breath, no rotation.
    // The line below it already says the feed is loading, so nothing is lost.
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    return FeedPageContent(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: FeedLoadingState._verticalPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Illustration(
              breath: _breath,
              asset: _order[_index],
              animate: !reduceMotion,
            ),
            const SizedBox(height: kFeedPageBlockGap),
            // Same token as the end card's title: `Mobile/H3`, 26, centred.
            FeedBlockTitle(
              text: _messageFor(l10n, widget.filter),
              fontSize: 26,
              align: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// The line for this feed. Exhaustive over [FeedFilter] on purpose — a fifth
  /// filter must not silently inherit an existing entity's words.
  static String _messageFor(Lt l10n, FeedFilter filter) => switch (filter) {
    FeedFilter.events => l10n.feedLoadingEvents,
    FeedFilter.venues => l10n.feedLoadingVenues,
    FeedFilter.zines => l10n.feedLoadingZines,
    FeedFilter.people => l10n.feedLoadingPeople,
  };
}

/// One breathing drawing.
///
/// Split out so the `AnimatedBuilder` rebuilds the image and nothing else — the
/// title is static for the whole wait and has no business rebuilding on every
/// tick.
class _Illustration extends StatelessWidget {
  final Animation<double> breath;
  final String asset;
  final bool animate;

  const _Illustration({
    required this.breath,
    required this.asset,
    required this.animate,
  });

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      asset,
      height: FeedLoadingState.illustrationSize,
      fit: BoxFit.contain,
      // The title carries the meaning; the drawing is decoration.
      excludeFromSemantics: true,
    );

    // A fixed-height box either way, so the column below never moves — the five
    // drawings have different aspect ratios and the widest is ~24 px wider than
    // the narrowest at this height.
    final sized = SizedBox(
      height: FeedLoadingState.illustrationSize,
      child: image,
    );

    if (!animate) return sized;

    return AnimatedBuilder(
      animation: breath,
      // Built once and handed to the builder — the raster is not re-resolved
      // on every tick.
      child: sized,
      builder: (context, child) {
        final t = breath.value;
        return Opacity(
          opacity: t,
          child: Transform.scale(
            scale: lerpDouble(FeedLoadingState._minScale, 1, t)!,
            child: child,
          ),
        );
      },
    );
  }
}
