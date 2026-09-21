// PROD-4319 — the `create_cta` block: "help me get to know this place", with the
// two contribution CTAs under it.
//
// **This widget composes `DiscoveryHelpUsActions` rather than redrawing its
// pills.** That widget already owns the pill chrome, both sheets, the analytics
// call and the below-the-viewport fix its own doc comment describes. Copying it
// here would fork all four, and the two surfaces would drift the first time
// either changed.
//
// Everything it renders already existed before this block did: the copy is the
// legacy Discovery page's, in all four locales, and so are the buttons. The only
// new decisions here are the card treatment and the guest gate.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_theme.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../l10n/generated/l10n.dart';
import '../../../../../providers/auth_provider.dart';
import '../../../widgets/discovery_help_us_actions.dart';
import 'feed_block_atoms.dart';

/// Card ground. `sokoShade5` is the app's existing light fill (assistant chat
/// bubbles) and sits a shade off `sokoPaper`, which is what separates this ask
/// from the block above it without a rule or a heading.
const Color kFeedCreateCtaGround = AppColors.sokoShade5;

/// Analytics `source` for both sheets opened from this block.
///
/// Deliberately NOT `discovery_help_us`: the legacy surface still sends that,
/// and one shared value would make the two indistinguishable in the funnel
/// exactly when you would want to compare them.
const String kFeedCreateCtaSource = 'feed_create_cta';

class FeedCreateCtaBlock extends ConsumerWidget {
  final FeedBlockCreateCta block;

  const FeedCreateCtaBlock({super.key, required this.block});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Defence in depth only. The load-bearing gate is `renderableFeedBlocks`,
    // which DROPS this block for a guest — because a block that draws nothing
    // must not still count as renderable, or a page whose only block is this one
    // renders blank instead of reaching the empty state.
    //
    // Kept here as well because this widget is public and a future call site
    // could reach it without going through that filter.
    if (!ref.watch(isAuthenticatedProvider)) return const SizedBox.shrink();

    final l10n = Lt.of(context);

    return FeedBlockSurface(
      block: block,
      child: Container(
        // Matches `FeedBannerBlock`'s card metrics so this sits in the feed's
        // existing rhythm rather than introducing a second card shape.
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: kFeedCreateCtaGround,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              // The legacy page's line, shared deliberately (Zé, 2026-09-09):
              // one sentence, one wording, both surfaces. A future change
              // scoped to only one of them needs a new key, not an edit.
              l10n.discoveryNewCitySubtitle,
              textAlign: TextAlign.center,
              style: AppTheme.body(
                fontSize: 15,
                // The ground is a fixed light fill in both themes, so the ink
                // must be too — `sokoPaper` here would vanish in dark mode.
                color: AppColors.sokoInk,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 16),
            const DiscoveryHelpUsActions(source: kFeedCreateCtaSource),
          ],
        ),
      ),
    );
  }
}
