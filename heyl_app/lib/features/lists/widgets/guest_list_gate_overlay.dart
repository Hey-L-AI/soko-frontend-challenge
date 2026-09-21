import 'dart:ui';

import 'package:flutter/material.dart';

import 'guest_blur_cta_card.dart';

/// Overlay widget shown to guest users at the bottom of a list view.
///
/// Renders the [child] content (actual list item rows) blurred underneath
/// a sign-in CTA card. All hidden items are shown blurred — the child
/// determines the natural height and the CTA card is centered on top.
class GuestListGateOverlay extends StatelessWidget {
  /// The actual content to display blurred (e.g., ListItemRow widgets)
  final Widget child;

  /// Callback when user taps the sign-in button
  final VoidCallback? onSignIn;

  const GuestListGateOverlay({super.key, required this.child, this.onSignIn});

  @override
  Widget build(BuildContext context) {
    // Min height ensures the CTA card fits even with few hidden items
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 280),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Blurred items — non-positioned, determines Stack height
          ClipRect(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: IgnorePointer(child: Opacity(opacity: 0.5, child: child)),
            ),
          ),

          // CTA card — positioned overlay, aligned to top
          Positioned.fill(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.only(left: 20, right: 20, top: 16),
                child: GuestBlurCtaCard(onSignIn: onSignIn),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
