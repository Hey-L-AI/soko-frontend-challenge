import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/expert_badge.dart';
import '../../../shared/widgets/person_dot.dart';
import '../../../shared/widgets/press_pop.dart';
import '../../../shared/widgets/soko_toggle_glyph.dart';
import '../../../l10n/generated/l10n.dart';
import '../../lists/widgets/zine/list_zine_cover.dart';
import '../../lists/widgets/zine/zine_cover_peel_overlay.dart';
import '../data/onboarding_zine.dart';
import '../providers/onboarding_zines_controller.dart';
import 'onboarding_card_entrance.dart';
import 'onboarding_zine_page.dart';

typedef ZinesShelfProvider =
    StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>;

/// The zines step's preview row: one themed zine COVER card per picked interest
/// (PROD-3883 / BE-2), delivered inline in the transcript as a content turn.
/// Owns nothing — it reads the screen-scoped [OnboardingZinesController] and
/// fires its discovery request on first build. Each cover carries a quick-save
/// bookmark; tapping the cover body opens the full sandbox zine reader
/// ([OnboardingZinePage]).
class OnboardingZinesShelf extends ConsumerStatefulWidget {
  const OnboardingZinesShelf({
    super.key,
    required this.provider,
    required this.errorLabel,
    required this.retryLabel,
    required this.saveLabel,
    required this.savedLabel,
    this.initiallySavedIds = const {},
    this.analyticsStep = 'zines.generated',
  });

  final ZinesShelfProvider provider;
  final String errorLabel;
  final String retryLabel;
  final String saveLabel;
  final String savedLabel;

  /// Onboarding-funnel subturn this shelf attributes its item interactions to.
  /// Defaults to the generated batch; the "most-followed" second row passes
  /// `'zines.suggested'` so the two rows are tracked separately.
  final String analyticsStep;

  /// On resume, which zines the user had already saved — seeds the controller so
  /// their covers show "Saved" (content itself is stable server-side).
  final Set<String> initiallySavedIds;

  @override
  ConsumerState<OnboardingZinesShelf> createState() =>
      _OnboardingZinesShelfState();
}

class _OnboardingZinesShelfState extends ConsumerState<OnboardingZinesShelf> {
  // Cover 222 + 12 gap + title line + editor row + up-to-2-line description,
  // with headroom so no line clips. Generated cards (no description) are
  // shorter and top-align inside this fixed-height strip.
  static const _rowHeight = 322.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref
            .read(widget.provider.notifier)
            .load(seedSavedIds: widget.initiallySavedIds);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(widget.provider);
    final controller = ref.read(widget.provider.notifier);

    // Figma 7285:23952: a hairline divider brackets the carousel top + bottom.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, thickness: 1, color: AppColors.sokoInk8),
        const SizedBox(height: 12),
        SizedBox(height: _rowHeight, child: _body(state, controller)),
        const SizedBox(height: 12),
        const Divider(height: 1, thickness: 1, color: AppColors.sokoInk8),
      ],
    );
  }

  Widget _body(
    OnboardingZinesState state,
    OnboardingZinesController controller,
  ) {
    if (state.isLoading && state.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.sokoPink),
      );
    }
    if (state.error != null && state.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.errorLabel,
              textAlign: TextAlign.center,
              style: AppTheme.body(fontSize: 14, color: AppColors.sokoInk),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: controller.load,
              child: Text(
                widget.retryLabel,
                style: AppTheme.body(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (state.isEmpty) return const SizedBox.shrink();

    final zines = state.zines;
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      itemCount: zines.length,
      separatorBuilder: (_, __) => const SizedBox(width: 12),
      itemBuilder: (context, index) {
        final zine = zines[index];
        return OnboardingCardEntrance(
          index: index,
          child: _ZineCoverCard(
            zine: zine,
            index: index,
            saved: state.isSaved(zine.listId),
            saving: state.isSaving(zine.listId),
            onOpen: () {
              _trackZine('open');
              _openFullZine(zine);
            },
            onQuickSave: () {
              _trackZine('save');
              controller.save(zine.listId);
            },
            onUnsave: () {
              _trackZine('unsave');
              controller.unsave(zine.listId);
            },
          ),
        );
      },
    );
  }

  /// Fires the shared `onboarding_step` funnel event for a zines-step item
  /// interaction (cover opened / quick-saved), keyed to the `zines.generated`
  /// subturn like every other zines action.
  void _trackZine(String action) {
    ref
        .read(unifiedAnalyticsProvider)
        .trackOnboardingStep(step: widget.analyticsStep, action: action);
  }

  /// Opens the full sandbox zine reader on the root navigator — the real
  /// [ListZineView] hydrated from the hidden preliminary list. Replaces the
  /// old bottom-sheet preview.
  void _openFullZine(OnboardingPreliminaryZine zine) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => OnboardingZinePage(
          listId: zine.listId,
          zinesProvider: widget.provider,
          saveLabel: widget.saveLabel,
          savedLabel: widget.savedLabel,
        ),
      ),
    );
  }
}

/// One themed zine cover in the row (Figma 7672:32921 — the canonical
/// shelf-card treatment): a 4:5 [ListZineCover] with the shelf corner-peel
/// hint overlaid and a circular translucent quick-save bookmark pinned
/// bottom-right, then the zine name, an editor-attribution row (avatar +
/// "Edt. {name}" • item count), and — for the most-followed batch — a
/// description line at Ink 50%. Generated ("Curated for you") zines carry no
/// owner or description, so their row shows the curated label + count with no
/// avatar and the description line is omitted. Tapping the cover body opens
/// the full sandbox reader; tapping the bookmark toggles the save.
class _ZineCoverCard extends StatelessWidget {
  const _ZineCoverCard({
    required this.zine,
    required this.index,
    required this.saved,
    required this.saving,
    required this.onOpen,
    required this.onQuickSave,
    required this.onUnsave,
  });

  final OnboardingPreliminaryZine zine;

  /// Position within the row — feeds the peel gate so the first card is
  /// guaranteed to show the corner-peel affordance.
  final int index;
  final bool saved;
  final bool saving;
  final VoidCallback onOpen;
  final VoidCallback onQuickSave;
  final VoidCallback onUnsave;

  // 4:5 cover (Figma 177.967 × 222.459), rounded 8.
  static const _width = 178.0;
  static const _coverHeight = 222.0;
  static const _coverRadius = 8.0;

  @override
  Widget build(BuildContext context) {
    final ownerName = zine.ownerName?.isNotEmpty == true
        ? zine.ownerName!
        : (zine.ownerHandle?.isNotEmpty == true ? zine.ownerHandle! : null);
    final hasEditor = ownerName != null;
    final description = zine.description;
    final hasDescription = description != null && description.isNotEmpty;

    return GestureDetector(
      onTap: onOpen,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: _width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(_coverRadius),
                  child: SizedBox(
                    width: _width,
                    height: _coverHeight,
                    child: ListZineCover(
                      recipe: zine.coverRecipe,
                      title: zine.name,
                    ),
                  ),
                ),
                // Corner-peel hint — the same widget the Discovery shelves use.
                // Gates itself (waits for the cover, guarantees a peel on the
                // first card). Clipped to the cover radius so it stays inside.
                Positioned.fill(
                  child: ZineCoverPeelOverlay(
                    coverRecipe: zine.coverRecipe,
                    name: zine.name,
                    indexInShelf: index,
                    alwaysPeel: true,
                    clipRadius: BorderRadius.circular(_coverRadius),
                  ),
                ),
                Positioned(
                  bottom: 9,
                  right: 9,
                  child: _QuickSaveButton(
                    saved: saved,
                    saving: saving,
                    onTap: saved ? onUnsave : onQuickSave,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Title — Zalando Sans Light 18 / lh 1.0, up to 2 lines.
            Text(
              zine.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.body(
                fontSize: 18,
                fontWeight: FontWeight.w300,
                height: 1.0,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 8),
            // Editor row: avatar (most-followed only) + "Edt. {name}" •
            // item count. Generated zines have no owner → curated label, no
            // avatar.
            Row(
              children: [
                if (hasEditor) ...[
                  PersonDot(
                    url: zine.ownerAvatarUrl,
                    name: ownerName,
                    seed: zine.ownerId,
                    size: 20,
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    hasEditor
                        ? Lt.of(context).onboardingChatZinesByEditor(ownerName)
                        : Lt.of(context).onboardingChatZinesCuratedForYou,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(
                      fontSize: 14,
                      fontWeight: FontWeight.w300,
                      color: AppColors.sokoInk,
                    ),
                  ),
                ),
                if (zine.ownerIsExpert) ...[
                  const SizedBox(width: 4),
                  const ExpertBadge(compact: true),
                ],
                const SizedBox(width: 6),
                Text(
                  '•',
                  style: AppTheme.body(
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                    color: AppColors.sokoInk,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  Lt.of(
                    context,
                  ).onboardingChatZinesItemCountShort(zine.itemCount),
                  style: AppTheme.body(
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                    color: AppColors.sokoInk,
                  ),
                ),
              ],
            ),
            if (hasDescription) ...[
              const SizedBox(height: 8),
              Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.body(
                  fontSize: 14,
                  fontWeight: FontWeight.w300,
                  height: 1.2,
                  color: AppColors.sokoInk.withValues(alpha: 0.5),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The quick-save button pinned to a cover's bottom-right corner (Figma
/// `7672:32928`): a ~28px circle of translucent grey over a light backdrop
/// blur, with a centered bookmark glyph — the ink outline while unsaved and
/// solid Soko Ink once saved (or hovered — a web-only preview of the saved
/// state), matching the like/dislike thumbs' active treatment.
///
/// Owns its own tap so it wins the gesture arena over the card's open-reader
/// tap. It's a toggle: tap to save, tap again to un-save. It only goes inert
/// (null tap) while a save/unsave is in flight — crucially it must NOT null its
/// tap when [saved], or the tap would fall through to the card's open-reader
/// handler ("tapping un-save enters the zine").
class _QuickSaveButton extends StatefulWidget {
  const _QuickSaveButton({
    required this.saved,
    required this.saving,
    required this.onTap,
  });

  final bool saved;
  final bool saving;
  final VoidCallback onTap;

  @override
  State<_QuickSaveButton> createState() => _QuickSaveButtonState();
}

class _QuickSaveButtonState extends State<_QuickSaveButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Paper-white in both states over the frosted grey chip — the same
    // treatment as the like/dislike thumbs (SokoThumbCluster): only the
    // outline→fill swap signals selection, never a colour change. Saved OR
    // hovered → solid white bookmark; otherwise the white outline.
    final glyph = SokoToggleGlyph.bookmarkChip(
      active: widget.saved || _hovered,
      height: 13,
      fillColor: AppColors.sokoPaper,
      lineColor: AppColors.sokoPaper,
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // PressPop → same tap pop as the save/like/dislike controls; suppressed
      // while saving (the row is dimmed and taps are no-ops in that window).
      child: PressPop(
        onTap: widget.saving ? () {} : widget.onTap,
        pop: !widget.saving,
        child: AnimatedOpacity(
          opacity: widget.saving ? 0.5 : 1,
          duration: const Duration(milliseconds: 150),
          // Circular translucent-grey chip over a soft backdrop blur, clipped
          // to the circle so the blur only affects the chip's footprint.
          child: ClipOval(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 3.7, sigmaY: 3.7),
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color.fromRGBO(121, 121, 121, 0.3),
                  shape: BoxShape.circle,
                ),
                child: glyph,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
