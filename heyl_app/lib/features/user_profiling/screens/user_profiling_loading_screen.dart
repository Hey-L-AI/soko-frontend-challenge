import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../daily_drop/providers/daily_drop_provider.dart';
import '../providers/user_profiling_gate_provider.dart';
import '../providers/user_profiling_provider.dart';
import '../providers/user_profiling_questions_provider.dart';

/// Brief loading state shown while the submit POST is in flight. Cycles
/// through reassuring taglines and routes to the reveal screen on success
/// or surfaces an error UI on failure.
class UserProfilingLoadingScreen extends ConsumerStatefulWidget {
  const UserProfilingLoadingScreen({super.key});

  @override
  ConsumerState<UserProfilingLoadingScreen> createState() =>
      _UserProfilingLoadingScreenState();
}

class _UserProfilingLoadingScreenState
    extends ConsumerState<UserProfilingLoadingScreen> {
  static const _lineCount = 4;

  Timer? _ticker;
  int _lineIndex = 0;
  bool _navigatingToResult = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!mounted) return;
      setState(() => _lineIndex = (_lineIndex + 1) % _lineCount);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // React to result/error landing in the provider.
    ref.listen(userProfilingProvider, (previous, next) {
      if (next.result != null && previous?.result == null) {
        ref
            .read(unifiedAnalyticsProvider)
            .trackProfilingComplete(
              archetype: next.result!.persona.id,
              stepCount: next.currentStep + 1,
            );
        unawaited(_goToResultAfterProfileRefresh());
      }
    });

    final state = ref.watch(userProfilingProvider);
    final l = Lt.of(context);
    final lines = [
      l.personaOnboardingDiscoveringVibe,
      l.personaOnboardingHoldOn,
      l.personaOnboardingAlmostThere,
      l.personaOnboardingBuildingList,
    ];

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: state.error != null
            ? _ErrorBody(
                onRetry: () async {
                  // The catalog is loaded before the user can reach the
                  // submit path, so it must be present here on the retry.
                  // If somehow it isn't (provider invalidated mid-flow),
                  // bail rather than re-trigger the StateError in
                  // `submit()`.
                  final catalog = ref
                      .read(userProfilingQuestionsProvider)
                      .valueOrNull;
                  if (catalog == null) return;
                  try {
                    await ref
                        .read(userProfilingProvider.notifier)
                        .submit(catalog);
                  } catch (_) {
                    /* error captured in state */
                  }
                },
                // PROD-2438: pushReplacement preserves `shellHome` under
                // the profiling stack — see flow_screen for the full
                // rationale. PROD-2566: `source=resumed` — in-flow back nav,
                // not a fresh entry.
                onBack: () => context.pushReplacement(
                  '${AppRoutes.userProfilingFlow}?source=resumed',
                ),
              )
            : _LoadingBody(line: lines[_lineIndex]),
      ),
    );
  }

  Future<void> _goToResultAfterProfileRefresh() async {
    if (_navigatingToResult) return;
    _navigatingToResult = true;

    // The router gates non-onboarding routes on /auth/me.onboarding_complete.
    // Wait for the post-submit profile refresh before showing the result so
    // the final "continue" action cannot bounce the user back into onboarding.
    await ref.read(authStateProvider.notifier).refreshUserProfile();
    if (!mounted) return;
    await markUserProfilingFinishedLocally(ref);
    if (!mounted) return;
    // Kick the daily drop out of its `cta_profiling` state. The backend
    // now has a profile to generate from, so `initialize()` will GET a
    // fresh drop (or POST /daily/request to enqueue generation). Fires
    // while the user is still on the reveal / smart-lists screens so
    // the drop is more likely to be ready by the time they hit home.
    unawaited(ref.read(dailyDropProvider.notifier).initialize());
    // PROD-2438: see flow_screen — pushReplacement preserves shellHome
    // under the profiling stack, so the post-profiling Explorar o app
    // CTA pops back to it cleanly instead of remounting the shell.
    context.pushReplacement(AppRoutes.userProfilingResult);
  }
}

class _LoadingBody extends StatelessWidget {
  final String line;
  const _LoadingBody({required this.line});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Soko-walking-and-reading — same loading character used
            // by `activation_callback_screen._buildProcessingView`, so
            // both async-wait surfaces share one visual language.
            // Web gets a larger illustration since the viewport has
            // room; mobile keeps the activation-pattern 200 px width.
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
                line,
                key: ValueKey(line),
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
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final Future<void> Function() onRetry;
  final VoidCallback onBack;

  const _ErrorBody({required this.onRetry, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              color: AppColors.textSecondary,
              size: 36,
            ),
            const SizedBox(height: 16),
            Text(
              Lt.of(context).onboardingErrorTitle,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              Lt.of(context).onboardingErrorBody,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.sokoDark,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              child: Text(Lt.of(context).onboardingRetryCta),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: onBack,
              child: Text(
                Lt.of(context).onboardingSkipCta,
                style: const TextStyle(color: AppColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
