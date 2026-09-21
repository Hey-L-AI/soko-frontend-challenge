import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../providers/auth_provider.dart';
import '../../../../shared/widgets/carousel_snap_physics.dart';
import '../../../daily_drop/providers/daily_drop_provider.dart';
import '../../../user_profiling/providers/user_profiling_gate_provider.dart';
import '../../../weekly_bundle/providers/weekly_bundle_provider.dart';
import '../../widgets/sections/daily_drop_section.dart';
import '../../widgets/sections/weekly_bundle_section.dart';
import '../providers/feed_top_slot_provider.dart';
import '../utils/feed_top_slot_status.dart';

/// The feed's top slot: **an ordered list of ritual cards**, rendered full
/// width when there is one and as a snapping carousel — one whole card plus a
/// third of the next — when there are more.
///
/// Adding a third card is one entry in [_slots] — the width modes, the peek
/// geometry and the settling rule are all derived from how many slots report
/// themselves visible, not hardcoded for two.
///
/// ## Why the membership decision lives here
///
/// A section that collapses to `SizedBox.shrink()` still occupies its slot in a
/// horizontal list, so "how wide is a card" cannot be answered by the children.
/// [FeedTopSlotStatus] answers it from the same provider state the sections
/// read — see the drift warning in `feed_top_slot_status.dart`.
///
/// ## The settling rule (no jump on the common path)
///
/// Width mode counts **visible + resolving**, not visible alone. A card that is
/// still in flight is assumed to be arriving, so the usual case — both cards
/// resolve to visible — opens as a carousel with two skeletons and never
/// changes width. The layout only moves when a card resolves to *hidden*, which is the
/// one case no amount of waiting avoids: the alternative (hold everything until
/// every slot is terminal) delays the most visible element on the page and
/// still jumps at the end.
class FeedTopCards extends ConsumerWidget {
  const FeedTopCards({super.key});

  /// Gap between cards, matching the 12 px the sections use when stacked.
  static const double gap = 12;

  /// How much of the NEXT card shows beside the settled one.
  ///
  /// **A third, not the half it was** (Zé, 2026-08-28). The peek's job is to
  /// say "there is more" — at a half it stopped being a hint and read as two
  /// cards competing, which cost the card you are actually looking at the
  /// emphasis this slot exists to give it. A third still reads unmistakably as
  /// a cut-off card.
  ///
  /// The old spelling was `cardsPerView = 1.5`; this is the same number said
  /// the other way round (`cardsPerView == 1 + peekFraction`), and it is the
  /// intent rather than a derived count — which matters because [opacityFor]
  /// needs the peek itself, not the total.
  static const double peekFraction = 1 / 3;

  /// Opacity of a card showing exactly [peekFraction] of itself. The settled
  /// card is always 1.0.
  ///
  /// 0.65 (Zé, 2026-08-28; it shipped at 0.8 for a few hours and was too
  /// close to the settled card to separate them).
  static const double peekOpacity = 0.65;

  /// Card width for a given column width. Public for the geometry test.
  ///
  /// One whole card, the gap, and [peekFraction] of the next fill the column:
  /// `w = c + gap + c * peekFraction`.
  static double cardWidthFor(double columnWidth) =>
      (columnWidth - gap) / (1 + peekFraction);

  /// Key on the fade wrapper for the card at [index].
  ///
  /// Public so a test can read the *applied* opacity instead of guessing which
  /// `Opacity` in the subtree is ours — Daily Drop's status cards ship one of
  /// their own, so `find.byType(Opacity)` is ambiguous here.
  @visibleForTesting
  static Key cardOpacityKey(int index) =>
      ValueKey<String>('feed-top-card-opacity-$index');

  /// Opacity for the card at [index] at scroll position [offset].
  ///
  /// **Driven by how much of the card is on screen, not by `offset / pitch`.**
  /// The last card can never reach its own pitch multiple — `CarouselSnapPhysics`
  /// clamps the snap target to `maxScrollExtent`, and with two cards that stop
  /// is well short of one full pitch — so a page-index parameterisation would
  /// leave the final card resting at something like 0.93 instead of 1.0 and the
  /// one behind it brighter than the peek it actually shows. Visibility has no
  /// such end effect: the card the user has settled on is, by construction, the
  /// fully visible one.
  ///
  /// The visible fraction is remapped so that [peekFraction] — the fraction a
  /// peeking card shows *at rest* — is where [peekOpacity] lands, rather than
  /// zero visibility. Between two stops both cards are partly visible and both
  /// sit between the two values, which is the crossfade: one brightens exactly
  /// as the other dims, continuously, with no animation controller.
  static double opacityFor({
    required int index,
    required double offset,
    required double cardWidth,
    required double viewportWidth,
  }) {
    if (cardWidth <= 0) return 1;
    final left = index * (cardWidth + gap) - offset;
    final visible =
        (math.min(left + cardWidth, viewportWidth) - math.max(left, 0)).clamp(
          0.0,
          cardWidth,
        );
    final t = ((visible / cardWidth - peekFraction) / (1 - peekFraction)).clamp(
      0.0,
      1.0,
    );
    return peekOpacity + (1 - peekOpacity) * t;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAuthenticated = ref.watch(isAuthenticatedProvider);

    // PROD-4081 — the statuses moved to `feedTopSlotStatusesProvider` because
    // the rule above the filter row needs the same answer, and two copies of
    // "is this slot empty?" is how the rule and the cards would come to
    // disagree. The membership rule below stays here, where the builders are.
    final statuses = ref.watch(feedTopSlotStatusesProvider);
    final dailyDrop = statuses.dailyDrop;
    final weekly = statuses.weekly;

    // Order is the page order. Daily Drop leads because it is the daily ritual;
    // the Weekly Bundle is the weekly one.
    final slots = <_TopSlot>[
      _TopSlot(
        status: dailyDrop,
        // `guestMode` is Daily Drop's own PROD-1979 treatment, not the feed's
        // guest policy (D10 forbids the client having one) — it predates the
        // feed and belongs to the widget.
        build: () => DailyDropSection(guestMode: !isAuthenticated),
      ),
      _TopSlot(
        status: weekly,
        build: () => const WeeklyBundleSection(
          showLeadingGap: false,
          showCaption: false,
        ),
      ),
    ];

    final present = slots
        .where((s) => s.status != FeedTopSlotStatus.hidden)
        .toList(growable: false);

    if (present.isEmpty) return const SizedBox.shrink();
    if (present.length == 1) return present.single.build();

    return _TopCardsCarousel(cards: [for (final slot in present) slot.build()]);
  }
}

/// The two-or-more case. Stateful only because the fade needs the live scroll
/// offset, which means owning a [ScrollController].
class _TopCardsCarousel extends StatefulWidget {
  const _TopCardsCarousel({required this.cards});

  final List<Widget> cards;

  @override
  State<_TopCardsCarousel> createState() => _TopCardsCarouselState();
}

class _TopCardsCarouselState extends State<_TopCardsCarousel> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 0 until the view is attached and laid out.
  ///
  /// `ScrollController.offset` asserts on both of those, and the first build
  /// runs before either is true — the carousel is built by a `LayoutBuilder`,
  /// so the fade is computed once with no position at all. Reading it through
  /// a guard rather than a try/catch keeps the debug assert available for a
  /// real misuse, e.g. this controller ever being attached to two views (the
  /// failure mode behind `shared-shell-scrollcontroller-footgun`).
  double get _offset {
    if (_controller.positions.length != 1) return 0;
    return _controller.position.hasPixels ? _controller.position.pixels : 0;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        final cardWidth = FeedTopCards.cardWidthFor(viewportWidth);
        return SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          // Pitch is card + gap: the distance between two leading edges. Using
          // the card width alone would drift the rounding by one gap per card.
          physics: CarouselSnapPhysics(
            itemExtent: cardWidth + FeedTopCards.gap,
          ),
          // `SingleChildScrollView` + `Row` rather than a horizontal
          // `ListView`: a ListView needs a bounded height, and these cards are
          // as tall as their own title and byline rows make them (locale and
          // font scale both move it). A Row sizes to its tallest child, so the
          // slot keeps fitting when the text does not.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: FeedTopCards.gap,
            children: <Widget>[
              for (var i = 0; i < widget.cards.length; i++)
                SizedBox(
                  width: cardWidth,
                  // Rebuilds on every scroll frame, but only this wrapper —
                  // the card itself is passed as `child` and is not rebuilt.
                  // `Opacity` skips its save-layer entirely at 1.0, so the
                  // settled card costs nothing.
                  child: AnimatedBuilder(
                    animation: _controller,
                    child: widget.cards[i],
                    builder: (context, child) => Opacity(
                      key: FeedTopCards.cardOpacityKey(i),
                      opacity: FeedTopCards.opacityFor(
                        index: i,
                        offset: _offset,
                        cardWidth: cardWidth,
                        viewportWidth: viewportWidth,
                      ),
                      child: child,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TopSlot {
  const _TopSlot({required this.status, required this.build});

  final FeedTopSlotStatus status;
  final Widget Function() build;
}
