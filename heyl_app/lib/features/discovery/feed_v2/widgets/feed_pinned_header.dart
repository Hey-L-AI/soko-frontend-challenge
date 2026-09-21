// PROD-4005 / PROD-4080 / PROD-4299 — the feed's pinned header, as the two
// halves the bar is actually made of.
//
//     [ 📅 Eventos ] · "in" · ◎ Avenidas Novas ······ ( 🧠 )
//
// **There is no `FeedPinnedHeader` widget any more, and that is the point.**
// The feed shipped two of them — the D32/D33 three-slot bar and the D40/D42
// alternative — behind an admin toggle, so the two could be compared on real
// data. PROD-4299 kept the alternative and deleted the toggle.
//
// What went with it was a second layout. `SokoPinnedHeader._SlotLayout` and
// `_BandToBarLayout` were both answering "where does the location sit in the
// bar", and `feed_sticky_location_test.dart` existed to catch them drifting.
// The bar's slots now live in the band's delegate, so there is one layout, one
// location, one set of measurements, and nothing left to drift. This file
// supplies what goes in the two side slots; `FeedLocationBand` places them and
// owns the location that slides between them.
//
// ⚠️ **The location is deliberately NOT here.** It is the one element both
// header states show, so it is a single widget owned by the band — see
// `docs/learnings/an-element-in-two-header-states-must-be-one-widget.md`.
// Adding a `SokoLocationLine` to either half below puts two on screen
// mid-transition, which is the exact bug the band→bar hand-over was built to
// remove.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../data/models/user_profile.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/providers.dart';
import '../../../../shared/widgets/soko_pinned_header.dart';
import '../../../../shared/widgets/soko_tag_chip.dart';
import '../providers/feed_filter_provider.dart';
import 'feed_filter_bar.dart';

/// Figma frame height.
///
/// An alias of [kSokoPinnedHeaderHeight] — the bar's height is the design
/// system's, not the feed's. Kept so feed code and its tests can keep naming
/// the thing they are measuring.
const double kFeedPinnedHeaderHeight = kSokoPinnedHeaderHeight;

/// Gap either side of the "in", so the three parts read as one phrase.
const double kFeedPinnedHeaderPhraseGap = 8;

/// Whether the memories button should render for the current user.
///
/// **Admin-only in v0** (Zé, 2026-08-26). Its spec'd destination is the user's
/// memories inside the profile, but on `develop` that surface is unreachable
/// for everyone else: `/memories` is in `AppRoutes.droppedRoutes` and redirects
/// home, and `/menu/memory` bounces non-admins *and guests* in the top-level
/// router redirect. Rendering it for everyone would ship a button that does
/// nothing for ~all users.
///
/// Gating is the page's job, not the slot's — `SokoHeaderSlot.memories` draws
/// the button and asks no questions, so a page with a reachable memories
/// surface is not stuck behind this feed-specific rule.
bool feedShowsMemoriesButton(WidgetRef ref) =>
    ref.watch(currentUserProvider)?.role == UserRole.admin;

/// The bar's leading half: the selected filter as a chip, then "in".
///
/// **The chip is [SokoTagChip], the same component the filter row renders**
/// (PROD-4201). It used to be a hand-rolled pink `Container` imitating one, and
/// the imitation had drifted on every metric that matters — height 26 vs 30,
/// radius 9 vs 6, padding 12 vs 10, `w600` vs Zalando Light, and no icon at all
/// where the row's chips carry the filter's glyph. Label *and* icon now come
/// from [kFeedFilterEntries], which is also what the row reads, so the button
/// and the chip it opens cannot disagree about what a filter looks like or is
/// called.
class FeedPinnedHeaderLeading extends ConsumerWidget {
  /// Toggles the "Procura" + filter bar (D40 — the chip's job).
  ///
  /// PROD-4179 — a *toggle*, not an opener: a second tap closes the row again
  /// (Zé, 2026-09-03). It used to only ever open it, so the only way back was
  /// tapping outside or scrolling to the top.
  ///
  /// **It stays live in Procura mode**, where it means "put the chrome away":
  /// leave the search and collapse the row in one tap. An earlier version hid
  /// it there, reasoning that the row it toggles is shown unconditionally — but
  /// that removed the reader's way back out of the pinned bar.
  final VoidCallback onOpenFilters;

  const FeedPinnedHeaderLeading({super.key, required this.onOpenFilters});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final active = ref.watch(feedFilterProvider);

    // D40: picking another filter REPLACES the chip. Reading it from the same
    // entry table the filter bar renders means the two can't disagree.
    final entry = kFeedFilterEntries.firstWhere(
      (e) => e.filter == active,
      orElse: () => kFeedFilterEntries[1], // Eventos
    );

    // The bar honours this in three places and the chip in a fourth; this has
    // to agree, or a reduce-motion user gets a phrase that slides for 600 ms
    // after everything else has snapped.
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final chip = SokoTagChip(
      label: entry.label(l10n),
      icon: entry.icon,
      // Always the selected treatment: this chip *is* the current filter, not
      // a choice among several.
      selected: true,
      // The composite parent below owns the node — the documented reason this
      // flag exists. `SokoTagChip` returns an `ExcludeSemantics` here, so the
      // two cannot both announce.
      provideSemantics: false,
      onTap: onOpenFilters,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // **This is what makes the location slide when the filter changes**
        // (Zé, 2026-09-09), and it is doing more work than it looks.
        //
        // `SokoTagChip` does NOT animate its own width: `_TagSurface` is a
        // `SizedBox(30) > Material > Center(widthFactor: 1)`, and `Material`
        // animates `color` and `shape`, never size. The filter bar's sliding
        // lives in `_SokoTagAnimatedRow` (`MeasureSize` → `AnimatedPositioned`)
        // and never fires on a label change, because those five chips never
        // change label. So "reuse the chip and the slide comes with it" is
        // false, and believing it ships a header that snaps.
        //
        // `AnimatedSize` supplies the width motion, and everything downstream
        // — the "in", and the location the band positions after this Row —
        // follows through ordinary layout, because the delegate re-measures
        // this group every pass. No `MeasureSize`, no `setState` cycle to own.
        //
        // ⚠️ `RenderAnimatedSize` lays its child out at the child's NATURAL
        // size and aligns it; it cannot stretch it. So growing reads perfectly
        // (the pill grows from the left, revealing the longer label) while
        // shrinking snaps the pill narrow and closes the gap over the duration.
        // If that ever reads badly, the upgrade is the bar's own recipe:
        // `MeasureSize` the natural width, ease it with `TweenAnimationBuilder`,
        // and hand the number to a `SizedBox` the chip is clipped into.
        Semantics(
          button: true,
          // What the tap DOES, which is not what the chip says. The chip's own
          // node would announce "Eventos, selected, button", and a
          // screen-reader user acting on that would expect to select Eventos
          // rather than to open the filter row. Same label the header's left
          // circular button carried before the chip replaced it.
          label: l10n.feedPinnedHeaderFiltersLabel,
          onTap: onOpenFilters,
          // ⚠️ **Omitted entirely under reduce motion, NOT given
          // `Duration.zero`.** Every other honouring site in the Tag system
          // passes a zero duration and is fine, because `AnimatedPositioned`,
          // `TweenAnimationBuilder` and `Material` are all implicit animations
          // that simply land immediately. `AnimatedSize` is not one of those —
          // it animates at the render-object level, and at zero
          // `RenderAnimatedSize` re-dirties itself inside its own
          // `performLayout`: *"A RenderObject must not re-dirty itself while
          // still being laid out."* Dropping the wrapper is the correct answer
          // anyway; there is nothing to animate.
          child: reduceMotion
              ? chip
              : AnimatedSize(
                  // It is the leading element, so it grows and shrinks from its
                  // left edge. The default `Alignment.center` would move the
                  // pill sideways while the phrase after it slides — two
                  // motions, one of them wrong.
                  alignment: Alignment.centerLeft,
                  // The Tag system's own numbers rather than literals, so the
                  // header's motion IS the row's motion.
                  duration: SokoTagBarMotion.reveal.duration,
                  curve: SokoTagBarMotion.reveal.curve,
                  child: chip,
                ),
        ),
        const SizedBox(width: kFeedPinnedHeaderPhraseGap),
        Text(
          // The key still says "alt" because the ARB key outlived the
          // alternative header it was named for. Renaming it would mean
          // editing `intl_es.arb`, which is generated from the production
          // localization portal and must not be hand-edited.
          l10n.feedAltHeaderIn,
          maxLines: 1,
          // **18, matching the location and the band's "Estás em"** (Zé,
          // 2026-09-09). It was 14, tied to the chip's scale. The chip is a
          // design-system chip at its own size; "in Avenidas Novas" is one
          // running phrase and reads as one voice.
          style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
        ),
        const SizedBox(width: kFeedPinnedHeaderPhraseGap),
      ],
    );
  }
}

/// The bar's trailing half: the user's memories, for the admins who can reach
/// them.
///
/// Shrinks to zero width for everyone else rather than being omitted by the
/// caller, so the band's delegate has one shape to lay out and the location
/// simply gets the width back.
class FeedPinnedHeaderTrailing extends ConsumerWidget {
  const FeedPinnedHeaderTrailing({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!feedShowsMemoriesButton(ref)) return const SizedBox.shrink();
    // `SokoHeaderSlot.memories`, not a hand-built `CircleIconButton`: the slot
    // draws the Figma `Icon/Brain` SVG, where this header had been shipping
    // `LucideIcons.brain` — two different glyphs for one button.
    return SokoHeaderSlot.memories(onTap: () => context.push(AppRoutes.memory));
  }
}
