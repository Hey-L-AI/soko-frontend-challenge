import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/models.dart';
import '../../../features/lists/utils/zine_cover_recipe.dart';
import '../../../features/lists/widgets/zine/list_zine_cover.dart';
import '../../../features/lists/widgets/zine/zine_cover_peel_overlay.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../providers/user_profiling_provider.dart';
import '../utils/profiling_strings.dart';

/// Smart-lists screen ("Só para ti") — shows the persona-tailored lists the
/// backend generated during onboarding. Tapping a card opens that list;
/// the primary CTA dismisses onboarding into the main app.
class SmartListsScreen extends ConsumerWidget {
  const SmartListsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(userProfilingProvider).result;
    if (result == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // PROD-2438: pushReplacement preserves shellHome under the
        // profiling stack — see flow_screen for the full rationale.
        // PROD-2566: `source=resumed` — an in-flow recovery, not a fresh
        // deep-link/CTA entry, so it doesn't pollute campaign attribution.
        if (context.mounted) {
          context.pushReplacement(
            '${AppRoutes.userProfilingFlow}?source=resumed',
          );
        }
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final personaName = profilingPersonaName(context, result.persona.id);
    final description = Lt.of(
      context,
    ).personaOnboardingForYouDescription(result.smartLists.length);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                _ListsHeader(
                  title: personaName,
                  // PROD-2438: pushReplacement keeps shellHome at the
                  // bottom of the profiling stack — see flow_screen.
                  onBack: () =>
                      context.pushReplacement(AppRoutes.userProfilingResult),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    // PROD-2963: the CTA now flows inline right below the
                    // cards (no longer a fixed footer), so only a modest
                    // bottom pad is needed for scroll breathing room.
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                    child: Column(
                      children: [
                        // Extra top margin so the H1 has breathing room
                        // below the chrome header.
                        const SizedBox(height: 40),
                        Text(
                          Lt.of(context).personaOnboardingYourSmartLists,
                          textAlign: TextAlign.center,
                          style: AppTheme.displayPrimary(
                            fontSize: 42,
                            fontWeight: FontWeight.w300,
                            color: AppColors.sokoInk,
                            height: 0.94,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          description,
                          textAlign: TextAlign.center,
                          style: AppTheme.body(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Grid is shrink-wrapped (GridView.shrinkWrap),
                        // so no Expanded/IntrinsicHeight gymnastics
                        // needed — it sizes to its content height.
                        _ListsGrid(lists: result.smartLists),
                        // PROD-2963: pull the CTA up to sit just below the
                        // cards (centered, hug-content) instead of pinning a
                        // full-width button to the bottom edge, where it
                        // collided with the Android system nav bar.
                        const SizedBox(height: 40),
                        _ListsFooter(
                          onExplore: () => context.go(AppRoutes.home),
                        ),
                      ],
                    ),
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

class _ListsHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  const _ListsHeader({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    // Terminus screen of the onboarding flow — intentionally omits the
    // progress bar that the flow + reveal screens share.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: Row(
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
    );
  }
}

class _ListsGrid extends StatelessWidget {
  final List<SmartList> lists;
  const _ListsGrid({required this.lists});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: lists.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        // Sized so the cover (locked to 4:5 portrait below) plus a worst-
        // case 3-line description fits without the cover having to shrink.
        // Cards with shorter descriptions end up with a small gap below
        // the text — preferable to cropping the curated zine artwork.
        childAspectRatio: 0.50,
      ),
      itemBuilder: (context, i) {
        final list = lists[i];
        return _SmartListCard(
          list: list,
          indexInShelf: i,
          // `push` works because `/user-profiling/lists` is mounted inside
          // DiscoveryShell (same nested navigator as `/lists/:listId`).
          // Back from the list returns to the smart-lists grid.
          onTap: () => context.push('/lists/${Uri.encodeComponent(list.id)}'),
        );
      },
    );
  }
}

class _SmartListCard extends StatelessWidget {
  final SmartList list;
  final VoidCallback onTap;

  /// Position in the smart-list grid. Drives the [ZineCoverPeelOverlay]
  /// gate so the first/second card always renders the corner-peel hint.
  final int indexInShelf;
  const _SmartListCard({
    required this.list,
    required this.onTap,
    required this.indexInShelf,
  });

  @override
  Widget build(BuildContext context) {
    // Every list returned by the profiling submit is `from_profiling`
    // by construction; the BE sets `cover_show_*=false` on the same
    // rows so chrome (title, logo, texture) stays out of the curated
    // `Zine-Profiling-*.jpg` artwork. We just forward those flags.
    final recipe = ZineCoverRecipe.fromFields(
      listId: list.id,
      coverType: list.coverType,
      coverColor: list.coverColor,
      coverTexture: list.coverTexture,
      coverTextColor: list.coverTextColor,
      coverItemId: list.coverItemId,
      coverItemImageUrl: list.coverItemImageUrl,
      legacyCoverImageUrl: list.coverImageUrl,
      showTitle: list.coverShowTitle,
      showTexture: list.coverShowTexture,
      showLogo: list.coverShowLogo,
    );

    return Semantics(
      button: true,
      label: list.name,
      // Inner Texts each contribute to accessibility — outer Semantics
      // already provides the button name, so suppress the duplication.
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Cover is locked to 4:5 portrait so longer descriptions
              // below don't compress the curated `Zine-Profiling-*.jpg`
              // artwork (BoxFit.cover would otherwise chop the top/bottom).
              AspectRatio(
                aspectRatio: 4 / 5,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ListZineCover(recipe: recipe, title: list.name),
                    ),
                    // Corner-peel hint on the persona-tailored cards.
                    // No clip radius here — the cover in this surface
                    // isn't rounded, so the peel sits flush with the
                    // cover edges.
                    Positioned.fill(
                      child: ZineCoverPeelOverlay(
                        coverRecipe: recipe,
                        name: list.name,
                        indexInShelf: indexInShelf,
                        alwaysPeel: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Bold list name beneath the cover — matches the Figma
              // reference's "Art Attack" / "Sporty Spice" labels.
              Text(
                list.name,
                style: AppTheme.body(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.sokoInk,
                ),
              ),
              if (list.description != null) ...[
                const SizedBox(height: 4),
                // Mobile/B2 Reg description, up to 3 lines for breathing
                // room (Figma shows multiline descriptions).
                Text(
                  list.description!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.body(
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                    color: AppColors.sokoInk,
                    height: 1.2,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ListsFooter extends StatelessWidget {
  final VoidCallback onExplore;
  const _ListsFooter({required this.onExplore});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SokoCtaButton(
        label: Lt.of(context).personaOnboardingExploreApp,
        icon: Icons.north_east,
        variant: SokoCtaVariant.pink,
        // PROD-2963: hug the label instead of spanning full width.
        expand: false,
        onPressed: onExplore,
      ),
    );
  }
}
