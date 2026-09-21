import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/user_profiling_models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../providers/user_profiling_provider.dart';
import '../utils/profiling_strings.dart';

/// PROD-2566 — host for the `/user-profiling/landing` route. A thin stateful
/// wrapper so the "already-profiled landing shown" analytics fires exactly once
/// per entry, then renders the persona view in already-completed mode.
class ProfilingAlreadyDoneLanding extends ConsumerStatefulWidget {
  const ProfilingAlreadyDoneLanding({super.key});

  @override
  ConsumerState<ProfilingAlreadyDoneLanding> createState() =>
      _ProfilingAlreadyDoneLandingState();
}

class _ProfilingAlreadyDoneLandingState
    extends ConsumerState<ProfilingAlreadyDoneLanding> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(unifiedAnalyticsProvider)
          .trackProfilingDeepLink(reason: 'already_profiled');
    });
  }

  @override
  Widget build(BuildContext context) =>
      const PersonaRevealScreen(mode: PersonaRevealMode.alreadyCompleted);
}

/// How [PersonaRevealScreen] is being shown.
enum PersonaRevealMode {
  /// Default — the reveal at the end of a fresh profiling run. Reads the
  /// just-submitted persona from in-memory state; CTA continues to smart lists.
  postFlow,

  /// PROD-2566 — the "you've already done this" landing an already-profiled
  /// user reaches via the `/user-profiling/flow` deep link. Reads the persona
  /// from [alreadyProfiledPersonaProvider] (null until PROD-2698 ships — renders
  /// gracefully without a card); CTA is "erase & re-run" + "back home".
  alreadyCompleted,
}

/// Persona reveal — full-bleed coloured screen showing the assigned persona
/// (name + description). See [PersonaRevealMode] for the two surfaces it serves.
class PersonaRevealScreen extends ConsumerWidget {
  final PersonaRevealMode mode;

  const PersonaRevealScreen({
    super.key,
    this.mode = PersonaRevealMode.postFlow,
  });

  /// Single background colour for the reveal screen. Per the design spec,
  /// per-persona theming is deferred — swap this for a `persona.id`-keyed
  /// map when art lands.
  static const Color _background = Color(0xFFE5DD60);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (mode) {
      case PersonaRevealMode.postFlow:
        return _buildPostFlow(context, ref);
      case PersonaRevealMode.alreadyCompleted:
        return _buildAlreadyCompleted(context, ref);
    }
  }

  /// End-of-flow reveal (existing behaviour). Reads the just-submitted persona
  /// from in-memory state; bounces back to the flow if there's nothing to show.
  Widget _buildPostFlow(BuildContext context, WidgetRef ref) {
    final result = ref.watch(userProfilingProvider).result;
    if (result == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // PROD-2438: pushReplacement preserves shellHome at the bottom
        // of the profiling stack — see flow_screen for the full rationale.
        if (context.mounted) {
          context.pushReplacement(AppRoutes.userProfilingFlow);
        }
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return _scaffold(
      context,
      title: Lt.of(context).personaOnboardingYourVibeFeels,
      body: _personaBody(context, result.persona),
      footer: _RevealFooter(
        onDismiss: () => context.go(AppRoutes.home),
        // PROD-2438: pushReplacement (not go) keeps shellHome mounted under
        // the profiling stack. See flow_screen for the full rationale.
        onContinue: () => context.pushReplacement(AppRoutes.userProfilingLists),
      ),
    );
  }

  /// PROD-2566 already-profiled landing. The persona card is shown when
  /// [alreadyProfiledPersonaProvider] resolves to a persona; until the backend
  /// read endpoint (PROD-2698) ships it stays null and we render the message-
  /// only landing. Either way the "erase & re-run" / "back home" CTAs work.
  Widget _buildAlreadyCompleted(BuildContext context, WidgetRef ref) {
    final persona = ref.watch(alreadyProfiledPersonaProvider).valueOrNull;
    return _scaffold(
      context,
      title: Lt.of(context).profilingAlreadyDoneTitle,
      body: persona != null
          ? _personaBody(context, persona)
          : _noPersonaBody(context),
      footer: _AlreadyDoneFooter(
        onBackHome: () => context.go(AppRoutes.home),
        // "Erase & re-run" = a fresh run; ?reset=1 bypasses the already-profiled
        // gate on the flow route and wipes in-memory state on entry.
        onRerun: () {
          ref
              .read(unifiedAnalyticsProvider)
              .trackProfilingDeepLink(reason: 'rerun');
          context.go('${AppRoutes.userProfilingFlow}?reset=1');
        },
      ),
    );
  }

  /// Shared full-bleed scaffold: header (title + filled progress bar), a
  /// vertically-centred scrollable [body], and a [footer] button row.
  Widget _scaffold(
    BuildContext context, {
    required String title,
    required Widget body,
    required Widget footer,
  }) {
    return Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                _RevealHeader(
                  title: title,
                  onBack: () => context.go(AppRoutes.home),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [body],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                footer,
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Persona card: Soko character + persona name (one word per line) + the
  /// persona description. Shared by both modes.
  Widget _personaBody(BuildContext context, Persona persona) {
    // Use id-keyed resolvers (not the wire `nameKey`/`descriptionKey`) — wire
    // keys have drifted across spec versions; see profiling_strings.dart.
    final name = profilingPersonaName(context, persona.id).toUpperCase();
    // Split on whitespace → one word per line. AutoSizeText (below) then
    // shrinks the font so the widest word fits its line on any viewport,
    // never breaking mid-word. Transversal across every persona and scalable
    // to any future name length / word-count — no per-persona tuning.
    final nameWords = name
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    final description = profilingPersonaDescription(context, persona.id);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Soko-with-camera character — same treatment as the profiling loading
        // screen, so the two flow surfaces share one visual language.
        Image.asset(
          'assets/images/illustrations/soko-with-camera.webp',
          width: 140,
          height: 140,
          fit: BoxFit.contain,
        ),
        const SizedBox(height: 24),
        AutoSizeText(
          // One word per line; AutoSizeText shrinks the font (down to
          // minFontSize) so the widest word fits its line without ever breaking
          // mid-word.
          nameWords.join('\n'),
          textAlign: TextAlign.center,
          // One line per word — 2 lines for a two-word persona.
          maxLines: nameWords.length,
          minFontSize: 24,
          stepGranularity: 1,
          wrapWords: false,
          // Mobile/H0 — SeasonMix 52 / w300 / lh 0.86, tracking -1.04.
          style: AppTheme.displayPrimary(
            fontSize: 52,
            fontWeight: FontWeight.w300,
            color: AppColors.sokoInk,
            height: 0.86,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          description,
          textAlign: TextAlign.center,
          // Mobile/B2 Reg — Zalando Sans 14 / w300 / lh 1.2, tracking -0.14.
          style: AppTheme.body(
            fontSize: 14,
            fontWeight: FontWeight.w300,
            color: AppColors.sokoInk,
            height: 1.2,
          ),
        ),
      ],
    );
  }

  /// PROD-2566 graceful fallback: the already-profiled landing when no persona
  /// card is available yet (PROD-2698 read endpoint not live). Soko character +
  /// a short "you've already shared your vibe" message.
  Widget _noPersonaBody(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset(
          'assets/images/illustrations/soko-with-camera.webp',
          width: 140,
          height: 140,
          fit: BoxFit.contain,
        ),
        const SizedBox(height: 24),
        Text(
          Lt.of(context).profilingAlreadyDoneBody,
          textAlign: TextAlign.center,
          style: AppTheme.body(
            fontSize: 14,
            fontWeight: FontWeight.w300,
            color: AppColors.sokoInk,
            height: 1.2,
          ),
        ),
      ],
    );
  }
}

class _RevealHeader extends StatelessWidget {
  final VoidCallback onBack;
  final String title;
  const _RevealHeader({required this.onBack, required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back, size: 22),
                color: AppColors.textPrimary,
              ),
              Expanded(
                child: Text(
                  title,
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
              const SizedBox(width: 48),
            ],
          ),
          const SizedBox(height: 6),
          // Reveal is past the survey — render the progress bar as fully filled.
          // Equivalent to `_ProgressBar(stepIndex: totalSteps - 1, totalSteps)` but
          // inlined since `_ProgressBar` is private to the flow screen.
          Container(height: 2, color: AppColors.textPrimary),
        ],
      ),
    );
  }
}

class _RevealFooter extends StatelessWidget {
  final VoidCallback onDismiss;
  final VoidCallback onContinue;
  const _RevealFooter({required this.onDismiss, required this.onContinue});

  @override
  Widget build(BuildContext context) {
    // Paired `BtSqIco` footer — same rhythm as the survey's
    // Skip / Continue pair in `user_profiling_flow_screen.dart`.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Row(
        children: [
          Expanded(
            child: BtSqIco(
              icon: null,
              label: Lt.of(context).personaOnboardingMaybeLater,
              variant: BtSqIcoVariant.idle,
              expand: true,
              onTap: onDismiss,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: BtSqIco(
              icon: Icons.north_east,
              label: Lt.of(context).personaOnboardingContinue,
              variant: BtSqIcoVariant.selected,
              expand: true,
              onTap: onContinue,
            ),
          ),
        ],
      ),
    );
  }
}

/// PROD-2566 already-profiled landing footer: "back home" (idle) + "erase &
/// re-run" (selected). Same `BtSqIco` rhythm as [_RevealFooter].
class _AlreadyDoneFooter extends StatelessWidget {
  final VoidCallback onBackHome;
  final VoidCallback onRerun;
  const _AlreadyDoneFooter({required this.onBackHome, required this.onRerun});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Row(
        children: [
          Expanded(
            child: BtSqIco(
              icon: null,
              label: Lt.of(context).profilingAlreadyDoneBackHome,
              variant: BtSqIcoVariant.idle,
              expand: true,
              onTap: onBackHome,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: BtSqIco(
              icon: Icons.refresh,
              label: Lt.of(context).profilingAlreadyDoneRerun,
              variant: BtSqIcoVariant.selected,
              expand: true,
              onTap: onRerun,
            ),
          ),
        ],
      ),
    );
  }
}
