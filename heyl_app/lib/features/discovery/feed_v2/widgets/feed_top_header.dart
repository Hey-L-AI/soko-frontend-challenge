// PROD-4005 — the Discovery feed's top header (D31, Figma `7304-23416`).
//
// Soko wordmark, then the location band — "Estás em" against "◎ Avenidas
// Novas" and the scallop rule that closes the header off.
//
// This scrolls away normally, and TWO headers take over from it in turn: the
// band pins to the top edge as soon as it gets there (the feed's sticky
// overlay), and the pinned bar (D32) replaces the band once the rest of the
// in-flow chrome has gone too. Only the wordmark is ever allowed to pass under
// the status bar, and only before the band pins.
//
// **The band is [FeedLocationBand], not inline here**, precisely because the
// sticky overlay renders the same widget: the hand-over happens at the offset
// where the two copies coincide, so they cannot be two compositions that agree
// today.
//
// **Vertical rhythm is the Figma frame, measured.** `7304-23416` is 400 × 190.06
// and stacks: wordmark `0 → 115.06` · **30** · the band `145.06 → 190.06`.
//
// Everything above is measured from the frame's own y0, so the frame says
// nothing about what sits above the wordmark. That is `SafeArea` + the page
// margin — see the build method.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../l10n/generated/l10n.dart';
import 'feed_location_band.dart';
import '../../../research/widgets/research_invitation_banner.dart';
import '../../../../core/theme/page_layout.dart';

class FeedTopHeader extends StatelessWidget {
  const FeedTopHeader({super.key, this.researchScrollController});
  final ScrollController? researchScrollController;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = Lt.of(context);
    final isDesktop = MediaQuery.of(context).size.width >= 1024;

    return SafeArea(
      // **Top only.** D39's mobile figure is measured from below the status
      // bar — it reads "just under the iOS status-bar inset that `SafeArea`
      // already provides", and the legacy page provides it (`SafeArea(bottom:
      // false)` in `discovery_screen.dart`). This page did not, so on a notched
      // device the wordmark rendered under the status bar (Zé, 2026-08-28).
      //
      // Left/right are deliberately NOT taken: nothing else on this page takes
      // them, so a landscape notch would inset the header and leave every block
      // below it on the original margin. Horizontal insets are a page-wide
      // decision, not this widget's.
      top: true,
      bottom: false,
      left: false,
      right: false,
      child: Padding(
        // D39 — desktop gets extra breathing room above the wordmark; mobile
        // keeps it close to the top because vertical space is tight. Mirrors
        // `DiscoveryHeader`, which pairs its own figure with the same
        // `SafeArea` above.
        //
        // Mobile is the page margin rather than a number of its own: the
        // wordmark's gap to the top edge is the same gap the content keeps to
        // the side edges, and the pinned header that replaces this one on
        // scroll already opens with exactly that inset.
        padding: EdgeInsets.only(top: isDesktop ? 48 : kSokoPageMargin),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ResearchInvitationBanner(
              scrollController: researchScrollController,
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                // **The wordmark is the one element that does NOT run to the
                // page margin.** Figma draws it at 398/400 — edge to edge inside
                // the content column — but that puts it visibly closer to the
                // viewport than the legacy `DiscoveryHeader`, which insets it a
                // further 7.5% inside an already-padded column (Zé,
                // 2026-08-26). Same 0.925 factor as `DiscoveryHeader`, now
                // applied to the padded width, so the two pages match: ~30 px
                // from the viewport edge on a 430 px phone.
                final width = (constraints.maxWidth * 0.925).clamp(0.0, 480.0);
                return Center(
                  child: Semantics(
                    header: true,
                    label: l10n.discoveryHeaderLabel,
                    child: SvgPicture.asset(
                      'assets/images/logos/soko-logo-paper.svg',
                      width: width,
                      // The asset is already paper-coloured, so dark mode needs
                      // no tint — same treatment `DiscoveryHeader` applies.
                      colorFilter: isDark
                          ? null
                          : const ColorFilter.mode(
                              AppColors.sokoInk,
                              BlendMode.srcIn,
                            ),
                    ),
                  ),
                );
              },
            ),
            // Figma: wordmark ends 115.06, location box starts 145.06.
            const SizedBox(height: 30),
            // **Last in the header, and the sticky overlay depends on that.**
            // The page finds the band's scroll offset by subtracting
            // `kFeedLocationBandHeight` from the header's measured trailing
            // edge, so anything appended below this line would push the sticky
            // hand-over early by its own height. The "ENDS at the scallop"
            // case in `feed_headers_test.dart` is what pins it.
            const FeedLocationBand(),
          ],
        ),
      ),
    );
  }
}
