import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// The app's loading canvas: pink ground, Soko illustration, nothing else.
///
/// Matches `SokoWelcomeScreen` so the splash → welcome handoff feels like the
/// same canvas: same pink background and the same illustration at roughly the
/// same position. The headline / CTA fade in once the welcome screen takes over.
///
/// **Extracted from `_SplashGate` so a second waiter can reuse it** (PROD-4419).
/// `feedVariantGateProvider` holds the Discovery route for a moment after the
/// splash lifts, and drawing a *different* loading state there would read as a
/// flash — splash, then some other thing, then the page. Rendering the identical
/// canvas makes it one continuous load instead.
///
/// Anything new that needs to show "the app is still deciding" belongs here too,
/// rather than inventing a third loading look.
class SokoSplashView extends StatelessWidget {
  const SokoSplashView({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: AppColors.sokoPink,
    body: SafeArea(
      child: Center(
        child: Image(
          image: AssetImage(
            'assets/images/illustrations/soko-seating-and-reading.webp',
          ),
          width: 140,
          fit: BoxFit.contain,
          semanticLabel: 'Soko',
        ),
      ),
    ),
  );
}
