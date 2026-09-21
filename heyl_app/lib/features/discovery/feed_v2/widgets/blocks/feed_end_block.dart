// PROD-4006 / PROD-4238 — the `feed_end` block. Figma `7304-24484` + button
// `7304-24487`.
//
// Illustration, a centred question, and a button whose live-or-disabled state
// is **the backend's** (D24): it sends `enabled` and an `action`, and the
// widget renders what it is told. There is never an `if (v0)` here — which is
// what let PROD-4237 bring the button alive with no app release, exactly as the
// umbrella promised.
//
// Since PROD-4237 the block means "end of **this slate**, there is more". It is
// emitted only when a next slate exists, and its action is
// `{type: next_slate, cursor}`; the last slate ends on `feed_complete` instead
// (`feed_complete_block.dart`), never both. An app version that predates the
// action kind parses it, finds no route, and renders the disabled button it
// always did — the degrade is structural, not a version check.
//
// ⚠️ **Tapping REPLACES this block**, it does not scroll past it. The
// replacement happens in `FeedHomeNotifier.loadSlate`; see the warning there
// for why appending would strand this card mid-feed.

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../shared/widgets/bt_sq_ico.dart';
import '../../providers/feed_home_provider.dart';
import '../../utils/feed_action_routes.dart';
import '../feed_page_content.dart';
import 'feed_block_atoms.dart';

class FeedEndBlock extends ConsumerWidget {
  final FeedBlockFeedEnd block;

  const FeedEndBlock({super.key, required this.block});

  /// Already bundled and already exactly this drawing — the figure behind an
  /// open newspaper. Figma exports `7304:24485` as a flattened raster needing
  /// `mix-blend-multiply` to knock out its white; the app's copy is RGBA with a
  /// real alpha channel, so it composites correctly with no blend mode. Reusing
  /// it keeps a 250 KB binary out of this commit.
  static const String illustrationAsset =
      'assets/images/illustrations/soko-reading.png';

  /// `size-[115px]` on the frame.
  static const double illustrationSize = 115;

  /// `gap-[30px]` between the illustration and the title.
  static const double _illustrationToTitleGap = 30;

  /// The frame puts the button in a sibling group rather than inside the block,
  /// so this is measured across that boundary on the full-page comp
  /// `7304-23414`: the block ends at 7628.81 and `Bt_Sq_Ico` starts at 7658.81.
  /// Which makes it the page's own rhythm after all — every element in that
  /// frame is 30 from the next.
  static const double _titleToButtonGap = kFeedPageBlockGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FeedBlockSurface(
      block: block,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Image.asset(
            illustrationAsset,
            height: illustrationSize,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: _illustrationToTitleGap),
          if (block.title != null && block.title!.isNotEmpty) ...[
            // `Mobile/H3` — Season Mix 26, centred. Backend-localized (D7).
            FeedBlockTitle(
              text: block.title!,
              fontSize: 26,
              align: TextAlign.center,
            ),
            const SizedBox(height: _titleToButtonGap),
          ],
          _buildButton(context, ref),
        ],
      ),
    );
  }

  /// The button, live or dimmed.
  ///
  /// Unlike the banner's CTA this one **always renders**. The banner omits a
  /// CTA it cannot honour because the control is incidental to that block; here
  /// the button *is* the block's design, and D24 asks specifically for the
  /// finished design with the behaviour withheld.
  ///
  /// `onTap: null` is what makes it disabled — `BtSqIco` drops to 50 % opacity,
  /// stops hover and press feedback, and ignores taps. No bespoke disabled
  /// styling, and no second definition of what "disabled" looks like. The
  /// spinner is that same component's `loading` flag, for the same reason.
  ///
  /// Two live shapes, dispatched on the action's own kind rather than on which
  /// one happens to be non-null:
  ///
  ///   * **`next_slate`** (PROD-4237) — pages the feed in place. This is what
  ///     the backend sends today.
  ///   * **`route`** — pushes an allowlisted destination. Nothing emits this on
  ///     `feed_end`, and it is kept because `FeedButton` can express it and a
  ///     block that silently ignored a well-formed route would be a worse
  ///     surprise than one that honours it.
  ///
  /// A failed slate fetch needs no retry affordance of its own: this block is
  /// still on the page with its button live, so **the button is the retry**.
  Widget _buildButton(BuildContext context, WidgetRef ref) {
    final button = block.button;
    final cursor = button.nextSlateCursor;
    final route = button.routeTarget(isAllowedFeedActionRoute);

    // Read the flag off the notifier rather than tracking it locally: the fetch
    // outlives this widget's element (the block is REPLACED on success), so a
    // local `setState` would be writing to a widget that is about to be gone.
    //
    // Through the narrow derived provider, not `feedHomeProvider` directly —
    // see its own note for why a block widget must not reach for the feed.
    final loading = ref.watch(feedSlateLoadingProvider);

    final VoidCallback? onTap;
    if (cursor != null) {
      onTap = loading
          ? null
          : () => ref
                .read(feedHomeProvider.notifier)
                .loadSlate(cursor: cursor, fromBlockId: block.id);
    } else if (route != null) {
      onTap = () => context.push(route);
    } else {
      onTap = null;
    }

    return BtSqIco(
      icon: LucideIcons.arrow_down,
      label: button.label,
      variant: BtSqIcoVariant.selected,
      selectedBackgroundOverride: AppColors.sokoPink,
      expand: true,
      loading: loading && cursor != null,
      onTap: onTap,
    );
  }
}
