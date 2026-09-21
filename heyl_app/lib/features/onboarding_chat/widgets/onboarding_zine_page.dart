import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/models.dart' show SavedItemType, UserListItem;
import '../../../data/models/vibe_candidate.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../lists/providers/unified_list_provider.dart';
import '../../lists/widgets/zine/list_zine_view.dart';
import '../providers/onboarding_zines_controller.dart';
import 'onboarding_detail_page.dart';
import '../../../shared/widgets/soko_toggle_glyph.dart';

/// Full-screen, read-only ("sandbox") reader for one onboarding zine — the
/// real production [ListZineView] hydrated from the user's own hidden
/// `onboarding_preliminary` list via [unifiedListProvider]. Mirrors
/// [OnboardingDetailPage] (the per-item sandbox), but for a whole zine:
///
/// - Pushed on the ROOT navigator (over the onboarding gate) so it presents
///   as a normal page with a back button and pops straight back to
///   onboarding.
/// - [ListZineView] runs with `sandbox: true`, so every external link /
///   cross-screen nav / owner-edit affordance is suppressed and item taps
///   are re-routed to the sandbox event/venue detail ([_openItem]).
/// - The whole-zine **Save** lives here (not in [ListZineView]): the bottom
///   CTA calls the same [OnboardingZinesController.save] the cover
///   quick-save uses, so both stay in sync.
class OnboardingZinePage extends ConsumerWidget {
  const OnboardingZinePage({
    super.key,
    required this.listId,
    required this.zinesProvider,
    required this.saveLabel,
    required this.savedLabel,
  });

  /// The hidden `onboarding_preliminary` list id — the [unifiedListProvider]
  /// key AND the [OnboardingZinesController.save] target.
  final String listId;

  /// Screen-scoped onboarding zines provider — read for live saved/saving
  /// state so the Save CTA reflects (and drives) the same state as the
  /// carousel's cover quick-save.
  final StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>
  zinesProvider;

  final String saveLabel;
  final String savedLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listState = ref.watch(unifiedListProvider(listId));

    final Widget body;
    if (listState.isNotFound || listState.error != null) {
      body = _Error(message: Lt.of(context).onboardingChatZinesError);
    } else if (listState.list == null ||
        (listState.isLoadingItems && listState.items.isEmpty)) {
      // Still fetching the list OR its first page of items — hold a spinner
      // rather than flashing a bare cover with no pages.
      body = const _Loading();
    } else if (listState.items.isEmpty) {
      // List resolved but carries no readable items — show the error copy
      // instead of a lone solid-colour cover ("no pages" state).
      body = _Error(message: Lt.of(context).onboardingChatZinesError);
    } else {
      body = SingleChildScrollView(
        child: ListZineView(
          listId: listId,
          state: listState,
          sandbox: true,
          onSandboxItemTap: (item) {
            ref
                .read(unifiedAnalyticsProvider)
                .trackOnboardingStep(
                  step: 'zines.generated',
                  action: 'card_tap',
                );
            _openItem(context, item);
          },
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.sokoPaper,
      // No AppBar: the back button sits INSIDE the PageContent column so on
      // desktop it aligns with the centered 480-px body instead of floating at
      // the viewport edge. SafeArea now owns the top inset.
      body: SafeArea(
        child: PageContent(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
                child: Row(
                  children: [
                    SokoBackButton(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              Expanded(child: body),
              _SaveBar(
                zinesProvider: zinesProvider,
                listId: listId,
                saveLabel: saveLabel,
                savedLabel: savedLabel,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the sandbox event/venue detail for a tapped zine item, on the
  /// root navigator (same surface [OnboardingDetailPage] presents on).
  void _openItem(BuildContext context, UserListItem item) {
    final type = item.itemType == SavedItemType.event
        ? VibeCandidateType.event
        : VibeCandidateType.place;
    final entityId = item.eventId ?? item.venueId;
    if (entityId == null) return;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => OnboardingDetailPage(type: type, entityId: entityId),
      ),
    );
  }
}

/// Persistent bottom Save CTA — the exact button from the (removed) zine
/// preview sheet, wired to the onboarding zines controller. Watches the
/// provider so it flips to the saved (pink) state the moment the cover
/// quick-save or this button lands the copy. Pink (`selected`) matches the
/// in-app saved/following affordance (`ListPageHeader`), not the discovery
/// "Cria nova zine" yellow.
class _SaveBar extends ConsumerWidget {
  const _SaveBar({
    required this.zinesProvider,
    required this.listId,
    required this.saveLabel,
    required this.savedLabel,
  });

  final StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>
  zinesProvider;
  final String listId;
  final String saveLabel;
  final String savedLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(zinesProvider);
    final controller = ref.read(zinesProvider.notifier);
    final saved = state.isSaved(listId);
    final saving = state.isSaving(listId);

    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 12, 15, 20),
      // Only inert while a save/unsave is in flight — tapping when [saved] must
      // un-save (a toggle), not be a dead end.
      child: IgnorePointer(
        ignoring: saving,
        child: AnimatedOpacity(
          opacity: saving ? 0.5 : 1,
          duration: const Duration(milliseconds: 150),
          child: BtSqIco(
            key: Key('onboarding-zine-page-save-$listId'),
            icon: null,
            iconAsset: saved
                ? SokoToggleGlyph.bookmarkChipFill
                : SokoToggleGlyph.bookmarkChipOutline,
            label: saved ? savedLabel : saveLabel,
            variant: saved ? BtSqIcoVariant.selected : BtSqIcoVariant.normal,
            expand: true,
            height: 54,
            onTap: () {
              ref
                  .read(unifiedAnalyticsProvider)
                  .trackOnboardingStep(
                    step: 'zines.generated',
                    action: saved ? 'unsave' : 'save',
                  );
              if (saved) {
                controller.unsave(listId);
              } else {
                controller.save(listId);
              }
            },
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 80),
    child: Center(child: CircularProgressIndicator(color: AppColors.sokoPink)),
  );
}

class _Error extends StatelessWidget {
  const _Error({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 60),
    child: Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: AppTheme.body(fontSize: 16, color: AppColors.sokoInk),
      ),
    ),
  );
}
