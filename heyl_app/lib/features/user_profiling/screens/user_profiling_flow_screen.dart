import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../providers/user_profiling_provider.dart';
import '../providers/user_profiling_questions_provider.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../utils/profiling_strings.dart';
import '../widgets/interest_chip_grid.dart';
import '../widgets/location_step.dart';
import '../widgets/vibe_card.dart';
import '../widgets/vibe_palette.dart';

/// User-profiling (V6 vibe) flow:
///   Step 0 — location
///   Steps 1-4 — vibe multi-select (1-2 each)
///   Step 5 — interests multi-select (1-4)
///
/// Submit is triggered from step 5's CTA, after which we navigate to the
/// loading screen which then routes to the persona reveal.
class UserProfilingFlowScreen extends ConsumerStatefulWidget {
  /// When true, calls `notifier.reset()` on first build to wipe prior
  /// in-memory state. URL: `/user-profiling/flow?reset=1`.
  final bool reset;

  /// Where this flow entry came from, for the `profiling_started` analytics
  /// `entry_source` (PROD-2566). Threaded from the route's `?source=` query.
  /// Defaults to `'deep_link'` — an external `/user-profiling/flow` tap carries
  /// no `?source`, so the campaign deep-link entry is attributed correctly
  /// instead of being mislabeled as the daily-drop CTA. In-app entries pass
  /// their own (`daily_drop_cta`, `product_tour`, `resumed`). `?reset=1` always
  /// reports `'start_over'` regardless.
  final String entrySource;

  const UserProfilingFlowScreen({
    super.key,
    this.reset = false,
    this.entrySource = 'deep_link',
  });

  @override
  ConsumerState<UserProfilingFlowScreen> createState() =>
      _UserProfilingFlowScreenState();
}

class _UserProfilingFlowScreenState
    extends ConsumerState<UserProfilingFlowScreen> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    if (widget.reset) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(userProfilingProvider.notifier).reset();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(unifiedAnalyticsProvider)
          .trackProfilingStarted(
            entrySource: widget.reset ? 'start_over' : widget.entrySource,
          );
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final questionsAsync = ref.watch(userProfilingQuestionsProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: questionsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _ErrorState(
                message: e.toString(),
                onRetry: () => ref.invalidate(userProfilingQuestionsProvider),
              ),
              data: (catalog) =>
                  _Loaded(catalog: catalog, pageController: _pageController),
            ),
          ),
        ),
      ),
    );
  }
}

class _Loaded extends ConsumerWidget {
  final UserProfilingQuestions catalog;
  final PageController pageController;

  const _Loaded({required this.catalog, required this.pageController});

  /// 0 = location, 1..4 = vibes, 5 = interests.
  static const int kLocationStepIndex = 0;
  static const int kFirstVibeIndex = 1;

  int get totalSteps => 1 + catalog.steps.length; // location + 5 catalog steps

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(userProfilingProvider);
    final notifier = ref.read(userProfilingProvider.notifier);

    // Sync the PageView when the provider's currentStep changes.
    ref.listen<int>(userProfilingProvider.select((s) => s.currentStep), (
      previous,
      next,
    ) {
      if (pageController.hasClients && pageController.page?.round() != next) {
        pageController.animateToPage(
          next,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    });

    return Column(
      children: [
        _Header(
          stepIndex: state.currentStep,
          totalSteps: totalSteps,
          canGoBack: state.currentStep > 0,
          onBack: notifier.previousStep,
        ),
        Expanded(
          child: PageView.builder(
            controller: pageController,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: totalSteps,
            itemBuilder: (context, index) {
              if (index == kLocationStepIndex) {
                // LocationStep manages its own LayoutBuilder + scroll so it
                // can vertically center inside the available height.
                return const LocationStep();
              }
              final stepIdx = index - kFirstVibeIndex;
              return _CatalogStepBody(step: catalog.steps[stepIdx]);
            },
          ),
        ),
        _Footer(
          stepIndex: state.currentStep,
          totalSteps: totalSteps,
          catalog: catalog,
          onContinue: () => _handleContinue(context, ref, state, notifier),
          onSkip: () => _confirmSkip(context, ref, notifier),
        ),
      ],
    );
  }

  Future<void> _handleContinue(
    BuildContext context,
    WidgetRef ref,
    UserProfilingState state,
    UserProfilingNotifier notifier,
  ) async {
    // Drop focus so the soft keyboard (open on the location step's city
    // TextField) doesn't linger over the next step.
    FocusManager.instance.primaryFocus?.unfocus();
    if (state.currentStep < totalSteps - 1) {
      notifier.nextStep();
      return;
    }
    // Last step: submit. The _Footer also gates Continue on
    // `isComplete(catalog)` so this branch should only fire when state is
    // complete — the guard is defence-in-depth (catalog could theoretically
    // change between widget rebuild and the tap arriving).
    if (!ref.read(userProfilingProvider).isComplete(catalog)) return;
    // PROD-2438: pushReplacement (not go) so `shellHome` stays at the
    // bottom of the navigator stack across the profiling chain. `go`
    // replaces the entire matchList with just `[loading]`, evicting the
    // shell — and when the user later tapped "Explorar o app" the
    // remount of the shell hit a `GlobalObjectKey` reparenting collision
    // on go_router's inner `_CustomNavigator` (`framework.dart:4738`
    // assertion + "Duplicate GlobalKey detected"). See
    // `docs/learnings/go-router-shell-navigator-globalobjectkey-collision.md`.
    context.pushReplacement(AppRoutes.userProfilingLoading);
    try {
      await notifier.submit(catalog);
    } catch (_) {
      /* error captured in state; loading screen handles */
    }
  }

  Future<void> _confirmSkip(
    BuildContext context,
    WidgetRef ref,
    UserProfilingNotifier notifier,
  ) async {
    final confirmed = await showBottomSheetWithHiddenNav<bool>(
      context: context,
      ref: ref,
      builder: (ctx) => DSSheetShell(
        bodyPadding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              Lt.of(ctx).personaOnboardingSkipConfirmTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontSize: 18,
                fontWeight: FontWeight.w700,
                height: 1.0,
                letterSpacing: -0.36,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              Lt.of(ctx).personaOnboardingSkipConfirmDesc,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontSize: 14,
                fontWeight: FontWeight.w300,
                height: 1.2,
                letterSpacing: -0.14,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: BtSqIco(
                    icon: LucideIcons.x,
                    label: Lt.of(ctx).personaOnboardingSkipConfirmCancel,
                    variant: BtSqIcoVariant.normal,
                    expand: true,
                    onTap: () => Navigator.of(ctx).pop(false),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: BtSqIco(
                    icon: LucideIcons.chevrons_right,
                    label: Lt.of(ctx).personaOnboardingSkipConfirmAction,
                    variant: BtSqIcoVariant.selected,
                    expand: true,
                    onTap: () => Navigator.of(ctx).pop(true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && context.mounted) {
      final stepIndex = ref.read(userProfilingProvider).currentStep;
      ref
          .read(unifiedAnalyticsProvider)
          .trackProfilingSkipped(stepIndex: stepIndex);
      // PROD-2582 — a skip is NOT a completion. We deliberately do NOT mark
      // profiling finished locally and do NOT kick the daily drop into
      // polling. Leaving the local gate false keeps `DailyDropSection`
      // rendering the profiling CTA card ("I don't know you well yet") in
      // the daily-drop slot — the BE still returns `cta_profiling` — so the
      // user can opt back into profiling later instead of the slot going
      // blank. (Reverses the skip-as-finished behaviour from PROD-2436.)
      notifier.reset();
      if (context.mounted) context.go(AppRoutes.home);
    }
  }
}

class _Header extends StatelessWidget {
  final int stepIndex;
  final int totalSteps;
  final bool canGoBack;
  final VoidCallback onBack;

  const _Header({
    required this.stepIndex,
    required this.totalSteps,
    required this.canGoBack,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                onPressed: canGoBack ? onBack : null,
                icon: const Icon(Icons.arrow_back, size: 22),
                color: AppColors.textPrimary,
              ),
              Expanded(
                child: Text(
                  Lt.of(context).personaOnboardingHeader,
                  textAlign: TextAlign.center,
                  // Mobile/B1 Reg — Zalando Sans 18 / w300 / lh 1.0,
                  // tracking -0.36 (`fontSize × -0.02` via display()).
                  style: AppTheme.display(
                    fontSize: 18,
                    fontWeight: FontWeight.w300,
                    color: AppColors.sokoInk,
                    height: 1.0,
                  ),
                ),
              ),
              const SizedBox(width: 48), // visual balance for the back button
            ],
          ),
          const SizedBox(height: 6),
          _ProgressBar(stepIndex: stepIndex, totalSteps: totalSteps),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final int stepIndex;
  final int totalSteps;

  const _ProgressBar({required this.stepIndex, required this.totalSteps});

  @override
  Widget build(BuildContext context) {
    final progress = totalSteps == 0 ? 0.0 : (stepIndex + 1) / totalSteps;
    return SizedBox(
      height: 2,
      child: Stack(
        children: [
          Container(color: AppColors.borderLight),
          FractionallySizedBox(
            widthFactor: progress.clamp(0.0, 1.0),
            child: Container(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _CatalogStepBody extends ConsumerWidget {
  final UserProfilingStep step;

  const _CatalogStepBody({required this.step});

  /// Single-select tap on a vibe step: replace the selection with this
  /// option and advance to the next page after a brief delay so the
  /// user sees the selection register visually before the page turns.
  /// Re-tapping the already-selected option still advances (lets a user
  /// "confirm" a re-visited page without changing the answer).
  void _onVibeTapped(BuildContext context, WidgetRef ref, String optionId) {
    final notifier = ref.read(userProfilingProvider.notifier);
    notifier.selectVibeOption(step.id, optionId);
    // Capture the step index at tap time so the deferred advance is
    // a noop if the user tapped Back (or rapid-tapped onto a later
    // step) during the delay window.
    final stepIndexAtTap = ref.read(userProfilingProvider).currentStep;
    // ~250ms — long enough for the selected state to render and read
    // as "got it", short enough that the flow still feels brisk.
    Future.delayed(const Duration(milliseconds: 250), () {
      if (!context.mounted) return;
      if (ref.read(userProfilingProvider).currentStep != stepIndexAtTap) {
        return;
      }
      notifier.nextStep();
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(userProfilingProvider);
    final notifier = ref.read(userProfilingProvider.notifier);

    final isInterests = step.kind == UserProfilingStepKind.interests;
    final selections = isInterests
        ? state.interests
        : (state.selections[step.id] ?? const []);

    final body = isInterests
        ? InterestChipGrid(
            options: step.options,
            selectedIds: state.interests,
            max: step.max,
            onToggle: (id) => notifier.toggleInterest(id, max: step.max),
          )
        : Column(
            // mainAxisSize.min so the surrounding `Center` actually
            // centers the stack vertically instead of letting the
            // Column stretch to fill the available height.
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final opt in step.options)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: VibeCard(
                    label: profilingString(context, opt.labelKey),
                    backgroundColor: VibePalette.forOption(opt.id),
                    selected: selections.contains(opt.id),
                    // Single-select: no cap concept — picking always
                    // replaces the prior selection on this step.
                    atCap: false,
                    onTap: () => _onVibeTapped(context, ref, opt.id),
                  ),
                ),
            ],
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Padding(
                // Extra top padding so the H1 sits with breathing room
                // below the chrome header.
                padding: const EdgeInsets.fromLTRB(20, 40, 20, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      profilingString(context, step.titleKey),
                      textAlign: TextAlign.center,
                      style: AppTheme.displayPrimary(
                        fontSize: 42,
                        fontWeight: FontWeight.w300,
                        color: AppColors.sokoInk,
                        height: 0.94,
                      ),
                    ),
                    // Inputs / chip grid centered in the remaining height.
                    Expanded(child: Center(child: body)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Footer extends ConsumerWidget {
  final int stepIndex;
  final int totalSteps;
  final UserProfilingQuestions catalog;
  final VoidCallback onContinue;
  final VoidCallback onSkip;

  const _Footer({
    required this.stepIndex,
    required this.totalSteps,
    required this.catalog,
    required this.onContinue,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(userProfilingProvider);
    final isLocation = stepIndex == 0;
    final canContinue = _canContinue(state, isLocation, stepIndex);
    // Continue is only meaningful on Location (needs explicit advance after
    // city pick) and on the last step (submits). Vibe steps in between
    // auto-advance on tap via `_onVibeTapped`, so showing Continue there
    // was redundant — and on the last step previously hid a silent no-op
    // when `state.isComplete` was false (PROD-2436).
    final showContinue = isLocation || stepIndex == totalSteps - 1;

    // Sticky-footer button pair → canonical `BtSqIco` per the
    // SokoCtaButton docstring: "For sheet button-row pairs (Cancel +
    // Confirm) keep using BtSqIco — same shape sized down to 40 px."
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Row(
        children: [
          Expanded(
            child: BtSqIco(
              icon: null,
              label: Lt.of(context).personaOnboardingSkip,
              variant: BtSqIcoVariant.idle,
              expand: true,
              onTap: onSkip,
            ),
          ),
          if (showContinue) ...[
            const SizedBox(width: 12),
            Expanded(
              // `BtSqIco` requires a non-null `onTap`; gate visually via
              // Opacity + IgnorePointer while !canContinue.
              child: Opacity(
                opacity: canContinue ? 1 : 0.4,
                child: IgnorePointer(
                  ignoring: !canContinue,
                  child: BtSqIco(
                    icon: Icons.north_east,
                    label: Lt.of(context).personaOnboardingContinue,
                    variant: BtSqIcoVariant.selected,
                    expand: true,
                    onTap: onContinue,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool _canContinue(UserProfilingState state, bool isLocation, int idx) {
    if (isLocation) return state.hasLocation;
    final stepIdx = idx - 1;
    if (stepIdx < 0 || stepIdx >= catalog.steps.length) return false;
    final step = catalog.steps[stepIdx];
    // Interests step submits — gate on full completion (PROD-2436). A purely
    // local `interests.length >= step.min` check would let Continue look
    // enabled while `_handleContinue` silently no-ops because some earlier
    // step's selection didn't make it into state (e.g. catalog drift, a
    // racy back-tap).
    if (step.kind == UserProfilingStepKind.interests) {
      return state.isComplete(catalog);
    }
    return (state.selections[step.id]?.length ?? 0) >= step.min;
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

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
              size: 32,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: onRetry,
              child: Text(Lt.of(context).commonRetry),
            ),
          ],
        ),
      ),
    );
  }
}
