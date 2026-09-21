import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';

/// Shared Soko-branded header used at the top of every screen in the
/// redesigned auth flow (PROD-2073): the Soko wordmark followed by a
/// two-column tagline row.
///
/// The wordmark renders at identical pixel size + top offset as
/// `DiscoveryHeader`. Discovery wraps its header in
/// `Padding(EdgeInsets.fromLTRB(16, 16, 16, …))` at the screen level, so
/// the equivalent gutter is applied here: 16 px top above the chrome
/// baseline (48 px extra on desktop per D39) and 16 px horizontal around
/// the wordmark SVG. The wordmark itself then scales by the same
/// `(constraints.maxWidth * 0.925).clamp(0, 480)` formula.
///
/// The tagline row keeps its own 24 px gutter to align with the auth body
/// content (login/register forms use `EdgeInsets.symmetric(horizontal:
/// 24)`). Background is transparent — set the cream `sokoPaper`
/// background on the enclosing Scaffold.
class SokoBrandHeader extends StatelessWidget {
  const SokoBrandHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    // Match DiscoveryHeader's top breathing room exactly — D39 in
    // docs/ui/design-decisions.md: mobile keeps the wordmark close to the
    // top (tight vertical real estate), desktop gets 48 px so the wordmark
    // doesn't look stuck to the top edge of the viewport. The +16 below
    // mirrors `discovery_screen.dart`'s outer `Padding(fromLTRB(16, 16,
    // 16, …))`, which is applied at the screen level on Discovery but
    // belongs here in the shared auth header so the same shell can host
    // every funnel screen without each one re-adding it.
    final isDesktop = MediaQuery.of(context).size.width >= 1024;
    final topPad = (isDesktop ? 48.0 : 0.0) + 16.0;

    return Padding(
      padding: EdgeInsets.only(top: topPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Wordmark — 16 px horizontal gutter to match
          // `discovery_screen.dart`'s outer 16 px padding around
          // `DiscoveryHeader`. With the same `(constraints.maxWidth *
          // 0.925).clamp(0, 480)` formula, the auth and discovery
          // wordmarks now render at identical pixel widths.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = (constraints.maxWidth * 0.925).clamp(0.0, 480.0);
                return Center(
                  child: Semantics(
                    header: true,
                    label: 'Soko',
                    child: SvgPicture.asset(
                      'assets/images/logos/soko-logo-paper.svg',
                      width: width,
                      colorFilter: const ColorFilter.mode(
                        AppColors.sokoInk,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          // Tagline keeps its own 24 px gutter — auth-only surface, no
          // Discovery counterpart to match. PROD-4071 flattened this to a
          // single two-column line: "Menos scroll" (left) · "Mais vida
          // local" (right), both in the same light weight per Figma
          // (node 7501-26908), replacing the old bold-main + long-secondary
          // block.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    l10n.authBrandTaglineMain,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _taglineStyle,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    l10n.authBrandTaglineSecondary,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _taglineStyle,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Figma "Mobile/B2 Reg": Zalando Sans Light, 14, -0.14 tracking, Soko/Ink.
  static const TextStyle _taglineStyle = TextStyle(
    fontFamily: 'Zalando Sans',
    fontSize: 14,
    height: 1.0,
    fontWeight: FontWeight.w300,
    letterSpacing: -0.14,
    color: AppColors.sokoInk,
  );
}
