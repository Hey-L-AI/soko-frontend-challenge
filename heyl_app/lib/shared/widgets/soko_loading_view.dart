import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';

/// Full-bleed, opaque Soko-branded loading surface: the walking-and-reading
/// mascot, a reassuring [message], and a spinner. Mirrors the metrics of the
/// user-profiling / OAuth-callback loaders so every async-wait surface shares
/// one visual language.
///
/// Used as an overlay while an in-process social login (native Google/Apple)
/// waits on the backend — see `login_screen.dart`.
class SokoLoadingView extends StatelessWidget {
  final String message;

  /// Opaque background so the view fully covers whatever it's layered over.
  final Color backgroundColor;

  const SokoLoadingView({
    super.key,
    required this.message,
    this.backgroundColor = AppColors.background,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: backgroundColor,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Web gets a larger illustration since the viewport has room;
              // mobile keeps the 200 px width used by the profiling loader.
              Image.asset(
                'assets/images/illustrations/soko-walking-and-reading.webp',
                width: kIsWeb ? 320 : 200,
                fit: BoxFit.contain,
                semanticLabel: 'Soko',
              ),
              const SizedBox(height: 24),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  message,
                  key: ValueKey(message),
                  textAlign: TextAlign.center,
                  style: AppTheme.body(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: AppColors.sokoInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
