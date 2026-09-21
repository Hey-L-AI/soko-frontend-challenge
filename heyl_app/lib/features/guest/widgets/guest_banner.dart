import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../utils/open_app_url.dart';

/// Persistent guest banner shown above [DiscoveryShell] for any
/// unauthenticated visitor (PROD-2072). Three zones on web:
///   • `[Log in]` (idle pill) — preserves return URL
///   • Soko wordmark (centered, tinted with sokoInk)
///   • `[Open app]` (selected/pink pill) — opens `soko.fyi/get/<currentPath>`
///
/// On native (iOS / Android) the `[Open app]` pill is hidden but its
/// layout slot is preserved (invisible placeholder) so the wordmark
/// stays visually centered. The `[Open app]` CTA itself only makes
/// sense in a browser — on native the user is already in the app.
///
/// Matches Figma node `6628:15331` (the chrome stripe at the top of frame
/// `6628:15179`). Caller (`DiscoveryShell`) is responsible for the
/// `isGuest` gating — this widget always renders when mounted.
class GuestBanner extends ConsumerWidget {
  const GuestBanner({super.key, required this.currentPath});

  /// GoRouter `matchedLocation` of the page underneath. Used as the path
  /// suffix for the `[Open app]` deep link.
  final String currentPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final topInset = MediaQuery.of(context).padding.top;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.sokoPaper,
        border: Border(
          // Figma: bottom 1 px Soko/Ink @ 30 % alpha. No 30-alpha token in
          // `AppColors` yet — derive inline rather than introduce a single-
          // use token (consolidate when a third caller appears).
          bottom: BorderSide(
            color: AppColors.sokoInk.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      padding: EdgeInsets.only(top: topInset),
      // Background + bottom border span the full viewport so the chrome
      // reads as a single stripe across the page; the interactive row
      // itself is centred inside the same 480 px column the rest of
      // `DiscoveryShell` uses on desktop (`PageContent`). Mirrors
      // `PinnedPageChrome`'s pattern — keeps the wordmark and CTAs aligned
      // with body content like detail cards and the Discovery feed.
      //
      // The inner `SizedBox(width: double.infinity)` is load-bearing. On
      // mobile, `PageContent` returns `Center > ConstrainedBox(maxWidth:
      // infinity)`, which hands down an UNBOUNDED width constraint — the
      // `Row` then sizes to its children's intrinsic width and
      // `MainAxisAlignment.spaceBetween` collapses (buttons squish next
      // to the wordmark). Forcing the SizedBox to take the full available
      // width gives the Row a tight constraint so `spaceBetween` pins the
      // CTAs to the edges.
      child: PageContent(
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            // Figma `6628:15331` reserves 15 px horizontal gutters and pins
            // the button row 14 px below the top of the chrome (74 px -
            // 60 px safe-area equivalent). On non-iOS web the safe-area is
            // 0, so bottom-pad to keep the chrome at ~64 px tall — close
            // to the 128 px Figma frame minus the 64 px notch the design
            // assumes.
            padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                BtSqIco(
                  icon: null,
                  label: l10n.guestBannerLogIn,
                  variant: BtSqIcoVariant.idle,
                  onTap: () => navigateToLoginPreservingReturn(
                    context,
                    ref,
                    referrer: AuthReferrer.guestBannerLogin,
                  ),
                ),
                // Wordmark — fixed 138×40 to match Figma `6628:15332`. The
                // SVG asset is paper-coloured; tint to ink via ColorFilter so
                // it reads against the paper banner background.
                Semantics(
                  header: true,
                  label: 'Soko',
                  child: SvgPicture.asset(
                    'assets/images/logos/soko-logo-paper.svg',
                    width: 138,
                    height: 40,
                    colorFilter: const ColorFilter.mode(
                      AppColors.sokoInk,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
                // Right slot: web shows the [Open app] universal-link
                // CTA. On native the same widget is rendered invisibly
                // (Visibility with maintainSize) so the wordmark in the
                // middle stays visually centered between the [Log in]
                // pill on the left and the right edge of the banner.
                Visibility(
                  visible: kIsWeb,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: BtSqIco(
                    icon: null,
                    label: l10n.guestBannerOpenApp,
                    variant: BtSqIcoVariant.selected,
                    onTap: kIsWeb
                        ? () => launchUrl(
                            Uri.parse(openAppUrl(currentPath)),
                            mode: LaunchMode.externalApplication,
                          )
                        : () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
