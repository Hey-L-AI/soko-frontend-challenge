// PROD-4238 — the `feed_complete` block: the end of the feed, as the backend
// declares it.
//
// **The app never renders an end-of-feed card on its own initiative** (Zé,
// PROD-4236). "É tudo, malta" appears because the backend put a block on the
// page saying so — with neither `feed_complete` nor `feed_end` present, the
// feed simply ends. That is why this reads `block.title` and has no fallback:
// a `??  l10n.discoveryFooterEnd` here would quietly restore exactly the
// client-side inference the block type exists to remove.
//
// The chrome is `DiscoveryFooter`'s, unchanged — the 115 px tile, the 42 px
// Season Mix line, the 120 px gap above and deliberately no dotted rule. Only
// the caption differs, and it arrives on the wire (backend-localized, D7), so
// this ships no ARB key. `discoveryFooterEnd` stays for the two search/shelf
// screens that still use it.
//
// ⚠️ The 120 px above is the FOOTER's, not the feed's. `FeedBlockSeparator`
// contributes zero before this block for that reason; see its own note.

import 'package:flutter/material.dart';

import '../../../../../data/models/feed_home.dart';
import '../../../widgets/sections/discovery_footer.dart';

class FeedCompleteBlock extends StatelessWidget {
  final FeedBlockFeedComplete block;

  const FeedCompleteBlock({super.key, required this.block});

  @override
  Widget build(BuildContext context) {
    final title = block.title;
    // No copy, nothing to say. Rendering the footer's chrome with an empty
    // line would put a 115 px illustration and 200 px of air on the page
    // announcing nothing — worse than the feed just ending, which is what the
    // contract says happens when a terminal block is absent.
    if (title == null || title.isEmpty) return const SizedBox.shrink();

    // `hasTrailingGap: true` — the screen already appends its own 96 px
    // `bottomNavReserve` and the footer's 104 brings the total to the 200 px
    // its own doc specifies. The two numbers were written to add up; nothing
    // needs reconciling beyond not double-counting them.
    return DiscoveryFooter.captioned(caption: title);
  }
}
