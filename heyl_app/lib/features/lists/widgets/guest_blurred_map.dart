import 'dart:ui';

import 'package:flutter/material.dart';

import 'guest_blur_cta_card.dart';

/// PROD-1979 — guest treatment for a list's multi-pin cover map. Renders
/// [child] behind a blur + `IgnorePointer` so guests can see the general
/// shape but not read pin positions, with a centered [GuestBlurCtaCard]
/// routing to sign-in. Shared between the zine and list view modes so
/// the two surfaces stay visually in sync.
class GuestBlurredMap extends StatelessWidget {
  final Widget child;
  final VoidCallback onSignIn;

  const GuestBlurredMap({
    super.key,
    required this.child,
    required this.onSignIn,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: IgnorePointer(child: child),
        ),
        Positioned.fill(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: GuestBlurCtaCard(onSignIn: onSignIn),
            ),
          ),
        ),
      ],
    );
  }
}
