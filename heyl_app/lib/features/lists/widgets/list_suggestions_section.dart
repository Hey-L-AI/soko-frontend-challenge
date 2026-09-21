import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/city_auto_scope_provider.dart';
import '../../../providers/city_scope_provider.dart';
import '../../../providers/lists_provider.dart';
import '../../moderation/content_blocked_handler.dart';
import '../models/search_scope.dart';
import '../providers/list_suggestions_provider.dart';
import '../providers/unified_list_provider.dart';
import 'add_to_list_sheet.dart';
import 'animated_suggestion_card.dart';
import 'suggestion_item_row.dart';

/// Section widget for AI-curated list suggestions.
///
/// Shows either:
/// A) A CTA to enable suggestions (when no prompt is set)
/// B) Suggestion cards with save/dismiss/refresh actions (when prompt is set)
class ListSuggestionsSection extends ConsumerStatefulWidget {
  final String listId;
  final String? prompt;
  final bool isOwner;

  const ListSuggestionsSection({
    super.key,
    required this.listId,
    required this.prompt,
    required this.isOwner,
  });

  @override
  ConsumerState<ListSuggestionsSection> createState() =>
      _ListSuggestionsSectionState();
}

class _ListSuggestionsSectionState
    extends ConsumerState<ListSuggestionsSection> {
  final _promptController = TextEditingController();
  bool _isEnabling = false;

  /// Track cards currently in exit animation
  final Map<String, SuggestionExitAnimation> _exitingCards = {};

  void _handleAdd(ItemSuggestion suggestion, int index) {
    if (_exitingCards.containsKey(suggestion.id)) return;

    // Fire the save immediately — the item appears in the list right away
    // via mergeOptimisticItemsLocally while the card animates out.
    ref
        .read(listSuggestionsProvider(widget.listId).notifier)
        .startSave(suggestion);

    // Track suggestion accept (PostHog)
    final itemType = suggestion.eventId != null ? 'event' : 'place';
    ref
        .read(unifiedAnalyticsProvider)
        .trackSuggestionAccept(
          listId: widget.listId,
          itemType: itemType,
          itemName: suggestion.name,
        );

    // Always fly upward so the card visually "transfers" to the list above
    setState(() {
      _exitingCards[suggestion.id] = SuggestionExitAnimation.flyUpward;
    });
  }

  /// Bookmark chip on a suggestion row (§ 8.3) — opens the
  /// "save to one of my lists" sheet for the suggestion. The card stays
  /// in place; saving to a different list is orthogonal to this list.
  void _handleSaveToOtherList(ItemSuggestion suggestion) {
    showAddToListSheet(
      context,
      suggestion,
      ref: ref,
      source: ListSource.listUi,
      // PROD-3873 — quicksave on tap, half-open peek on a fresh save.
      quickSaveIfUnsaved: true,
      skipDrawerWhenSaving: true,
    );
  }

  void _onExitComplete(ItemSuggestion suggestion) {
    setState(() {
      _exitingCards.remove(suggestion.id);
    });
    // Save already happened in _handleAdd via startSave — just remove the
    // card from the suggestions list now that the animation is done.
    ref
        .read(listSuggestionsProvider(widget.listId).notifier)
        .removeSuggestion(suggestion.id);
  }

  @override
  void initState() {
    super.initState();
    final initialPrompt = widget.prompt?.trim();
    if (initialPrompt != null && initialPrompt.isNotEmpty) {
      // Auto-load suggestions when prompt exists
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(listSuggestionsProvider(widget.listId).notifier)
            .loadSuggestions(initialPrompt);
      });
    }
  }

  /// Track the last save error we've shown so we don't re-show the same one.
  String? _lastShownSaveError;

  void _checkForSaveError(ListSuggestionsState suggestionsState) {
    final error = suggestionsState.lastSaveError;
    if (error != null && error != _lastShownSaveError) {
      _lastShownSaveError = error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(listSuggestionsProvider(widget.listId).notifier)
            .clearLastSaveError();
        showSoko(
          ref,
          message: Lt.of(context).listSuggestionsSaveError,
          variant: SokoVariant.error,
        );
      });
    }
  }

  @override
  void didUpdateWidget(covariant ListSuggestionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload whenever the prompt changes — new prompt, edited prompt, or
    // disabled. Cache is keyed by prompt hash so a new prompt naturally
    // triggers a fresh backend fetch; disabling clears the state.
    if (oldWidget.prompt != widget.prompt) {
      final notifier = ref.read(
        listSuggestionsProvider(widget.listId).notifier,
      );
      final trimmed = widget.prompt?.trim() ?? '';
      if (trimmed.isNotEmpty) {
        notifier.loadSuggestions(trimmed);
      } else {
        notifier.clear();
      }
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _enableSuggestions() async {
    final promptText = _promptController.text.trim();
    if (promptText.isEmpty) return;

    setState(() => _isEnabling = true);

    try {
      // Save prompt to list via PATCH
      await ref
          .read(listsProvider.notifier)
          .updateList(widget.listId, UserListUpdate(prompt: promptText));

      // Update optimistic state — no full refresh needed, just set the prompt
      // so the widget switches from CTA to suggestions view
      ref
          .read(unifiedListProvider(widget.listId).notifier)
          .updateListOptimistic(prompt: promptText);

      // Trigger suggestion loading directly (don't rely on didUpdateWidget —
      // Riverpod rebuilds can race with the provider lifecycle)
      ref
          .read(listSuggestionsProvider(widget.listId).notifier)
          .loadSuggestions(promptText);

      ref
          .read(unifiedAnalyticsProvider)
          .trackSuggestionPromptEnable(
            listId: widget.listId,
            prompt: promptText,
          );

      _promptController.clear();
    } catch (e) {
      if (mounted) {
        if (!handleContentBlocked(
          ref,
          context,
          e,
          field: ContentBlockedField.listPrompt,
        )) {
          // Stringifying the raw exception leaks DioException internals;
          // use a stable generic error string — same fallback the prompt
          // edit path uses.
          showSoko(
            ref,
            message: Lt.of(context).listSuggestionsSaveError,
            variant: SokoVariant.error,
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isEnabling = false);
      }
    }
  }

  Future<void> _updatePrompt(String newPrompt) async {
    try {
      ref
          .read(unifiedListProvider(widget.listId).notifier)
          .updateListOptimistic(prompt: newPrompt);

      await ref
          .read(listsProvider.notifier)
          .updateList(widget.listId, UserListUpdate(prompt: newPrompt));

      // Reload suggestions with new prompt (no full list refresh needed)
      ref
          .read(listSuggestionsProvider(widget.listId).notifier)
          .loadSuggestions(newPrompt);

      ref
          .read(unifiedAnalyticsProvider)
          .trackSuggestionPromptEdit(listId: widget.listId, prompt: newPrompt);
    } catch (e) {
      if (mounted) {
        if (!handleContentBlocked(
          ref,
          context,
          e,
          field: ContentBlockedField.listPrompt,
        )) {
          showSoko(
            ref,
            message: Lt.of(context).listSuggestionsSaveError,
            variant: SokoVariant.error,
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isOwner) return const SizedBox.shrink();

    // PROD-2004 follow-up: if the user changes the home-page city while the
    // suggestions section is mounted, refetch with the new scope. The
    // provider's cache is already keyed by scope so on its own a navigation
    // away+back would pull the right results, but reacting in-place avoids
    // showing stale Lisbon-flavoured suggestions while the user is staring
    // at the section after switching to Porto.
    ref.listen<SearchScope?>(cityScopeProvider, (_, __) => _onScopeChanged());
    ref.listen<AsyncValue<SearchScope?>>(
      cityAutoScopeProvider,
      (_, __) => _onScopeChanged(),
    );

    if (widget.prompt == null || widget.prompt!.isEmpty) {
      return _buildCta(context);
    }

    return _buildSuggestionsSection(context);
  }

  void _onScopeChanged() {
    final trimmed = widget.prompt?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    ref
        .read(listSuggestionsProvider(widget.listId).notifier)
        .loadSuggestions(trimmed, forceRefresh: true);
  }

  /// Section divider + header shared by CTA and suggestions views
  Widget _buildSectionHeader(BuildContext context, {Widget? trailing}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;
    final l10n = Lt.of(context);

    return Column(
      children: [
        Divider(color: borderColor, height: 1),
        const SizedBox(height: 12),
        Row(
          children: [
            Image.asset(
              'assets/images/soko-ai-icon.png',
              width: 20,
              height: 20,
              color: isDark ? null : AppColors.primaryDark,
              filterQuality: FilterQuality.medium,
            ),
            const SizedBox(width: 6),
            Text(
              l10n.listSuggestionsTitle,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            if (trailing != null) trailing,
          ],
        ),
      ],
    );
  }

  /// CTA state: no prompt set yet. Matches PROD-1852 Figma frame 9240 —
  /// a plain "Sugestões" heading on top of a Soko/Shade5 rounded input
  /// with a circular arrow send button on the right. Replaces the
  /// previous Soko-AI-icon + bordered-white-field layout so the
  /// empty-zine page reads as a single chrome family (header chips +
  /// Adicionar algo CTA + Sugestões input all in Soko/Shade5).
  Widget _buildCta(BuildContext context) {
    final l10n = Lt.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 16, 15, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Heading — matches the Figma weight; no Soko-AI image icon.
          Text(
            l10n.listSuggestionsCtaTitle,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 10),

          // Rounded Soko/Shade5 input with placeholder + circular send
          // button. No outline border — the fill is the chrome.
          TextField(
            controller: _promptController,
            onSubmitted: (_) => _enableSuggestions(),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w300,
              color: AppColors.sokoInk,
            ),
            decoration: InputDecoration(
              hintText: l10n.listSuggestionsCtaSubtitle,
              hintStyle: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w300,
                color: AppColors.sokoInk.withValues(alpha: 0.5),
              ),
              filled: true,
              fillColor: AppColors.sokoShade5,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              suffixIcon: _isEnabling
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.sokoInk,
                        ),
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _SuggestionsSendButton(onTap: _enableSuggestions),
                    ),
            ),
            maxLines: 1,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.go,
          ),
        ],
      ),
    );
  }

  /// Suggestions state: prompt is set, show suggestion cards
  Widget _buildSuggestionsSection(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final mutedColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;

    final suggestionsState = ref.watch(listSuggestionsProvider(widget.listId));
    // Watch listsProvider to rebuild when items are saved
    ref.watch(listsProvider);

    // Show snackbar if a background save failed
    _checkForSaveError(suggestionsState);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Shared section header with edit button
          _buildSectionHeader(
            context,
            trailing: GestureDetector(
              onTap: () => _showEditPromptDialog(context),
              child: Icon(Icons.edit_outlined, size: 16, color: mutedColor),
            ),
          ),

          // Current prompt display
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              widget.prompt!,
              style: TextStyle(
                fontSize: 13,
                color: mutedColor,
                fontStyle: FontStyle.italic,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Type toggle: Places (active) / Events (disabled until next iteration).
          // The affordance sits above the cards so it reads as "these cards
          // reflect the selected type".
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _buildTypeToggle(context),
          ),

          // Loading state — message + shimmer skeleton cards
          if (suggestionsState.isLoading) ...[
            // Status message
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor: AlwaysStoppedAnimation(primaryColor),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.listSuggestionsLoading,
                    style: TextStyle(fontSize: 12, color: mutedColor),
                  ),
                ],
              ),
            ),
            // Skeleton placeholder cards
            for (int i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ShimmerCard(isDark: isDark),
              ),
          ]
          // Error state
          else if (suggestionsState.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                children: [
                  Text(
                    l10n.listSuggestionsError,
                    style: TextStyle(fontSize: 13, color: mutedColor),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () {
                      final prompt = widget.prompt?.trim() ?? '';
                      if (prompt.isEmpty) return;
                      ref
                          .read(listSuggestionsProvider(widget.listId).notifier)
                          .loadSuggestions(prompt, forceRefresh: true);
                    },
                    child: Text(l10n.listSuggestionsFindMore),
                  ),
                ],
              ),
            )
          // Loaded: show the cards, optionally followed by either the
          // "Find more" button (pool has more to surface) OR the prompt
          // tips (fewer than 5 results total). Those two blocks are
          // mutually exclusive by construction.
          else if (suggestionsState.hasLoaded) ...[
            // "No matches" line shown above the tips when the pool is empty.
            if (suggestionsState.suggestions.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 12),
                child: Text(
                  l10n.listSuggestionsNoMatches,
                  style: TextStyle(fontSize: 13, color: mutedColor),
                  textAlign: TextAlign.center,
                ),
              ),

            // Suggestion cards.
            ...suggestionsState.suggestions.asMap().entries.expand((entry) {
              final index = entry.key;
              final suggestion = entry.value;
              final isSaved = _isSuggestionSaved(suggestion);
              final exitAnim = _exitingCards[suggestion.id];

              return [
                if (index > 0) Divider(height: 1, color: borderColor),
                AnimatedSuggestionCard(
                  key: ValueKey(suggestion.id),
                  exitAnimation: exitAnim,
                  onExitComplete: () => _onExitComplete(suggestion),
                  child: SuggestionItemRow(
                    suggestion: suggestion,
                    isSaved: isSaved,
                    onTap: () {
                      final id = suggestion.type == 'event'
                          ? suggestion.eventId
                          : suggestion.venueId;
                      if (id == null || id.isEmpty) return;
                      final path = suggestion.type == 'event'
                          ? '/lists/${widget.listId}/events/$id'
                          : '/lists/${widget.listId}/venues/$id';
                      context.push(path);
                    },
                    onAdd: isSaved ? null : () => _handleAdd(suggestion, index),
                    onSaveToOtherList: () => _handleSaveToOtherList(suggestion),
                  ),
                ),
              ];
            }),

            // "Find more" button — only while the cached pool still has
            // unseen items and we haven't hit the max display cap.
            if (suggestionsState.suggestions.isNotEmpty &&
                suggestionsState.canLoadMore)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SizedBox(
                  width: double.infinity,
                  height: 36,
                  child: OutlinedButton(
                    onPressed: suggestionsState.isLoading
                        ? null
                        : () {
                            final visibleBefore =
                                suggestionsState.suggestions.length;
                            ref
                                .read(
                                  listSuggestionsProvider(
                                    widget.listId,
                                  ).notifier,
                                )
                                .expandVisible();
                            ref
                                .read(unifiedAnalyticsProvider)
                                .trackSuggestionFindMore(
                                  listId: widget.listId,
                                  visibleCountBefore: visibleBefore,
                                );
                          },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: primaryColor,
                      side: BorderSide(color: borderColor),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      l10n.listSuggestionsFindMore,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
              ),

            // Prompt tips — shown when we have fewer than 5 results
            // (including zero). Helps the user write a stronger prompt.
            if (suggestionsState.suggestions.length < 5)
              _buildPromptTips(context),
          ],
        ],
      ),
    );
  }

  /// Prompt-writing tips shown below the cards whenever we have fewer than
  /// 5 results (including zero). The goal is to teach the user what kinds of
  /// hints produce better suggestions — specific types, location anchors,
  /// vibe / must-haves — so they can refine the prompt themselves.
  Widget _buildPromptTips(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mutedColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;

    Widget bullet(String text) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1, right: 8),
              child: Text(
                '•',
                style: TextStyle(fontSize: 13, color: mutedColor, height: 1.3),
              ),
            ),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 12, color: mutedColor, height: 1.3),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.listSuggestionsTipsHeading,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          bullet(l10n.listSuggestionsTipType),
          bullet(l10n.listSuggestionsTipLocation),
          bullet(l10n.listSuggestionsTipVibe),
        ],
      ),
    );
  }

  /// Places / Events pill toggle. Places is always selected in this first
  /// version. The Events pill is visibly "disabled" but still tappable —
  /// tapping it flashes a snackbar explaining that event suggestions are
  /// coming soon, so users understand why the pill can't be selected yet.
  Widget _buildTypeToggle(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;
    final mutedColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    Widget pill({
      required String label,
      required bool selected,
      required bool disabled,
      VoidCallback? onTap,
    }) {
      final bg = selected
          ? primaryColor.withValues(alpha: isDark ? 0.24 : 0.12)
          : Colors.transparent;
      final border = selected ? primaryColor : borderColor;
      final textColor = disabled
          ? mutedColor.withValues(alpha: 0.6)
          : (selected ? primaryColor : mutedColor);
      final pillBody = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border, width: 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: textColor,
          ),
        ),
      );
      if (onTap == null) return pillBody;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: pillBody,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pill(
          label: l10n.listSuggestionsTypePlaces,
          selected: true,
          disabled: false,
        ),
        const SizedBox(width: 6),
        pill(
          label: l10n.listSuggestionsTypeEvents,
          selected: false,
          disabled: true,
          onTap: () {
            showSoko(
              ref,
              message: l10n.listSuggestionsEventsComingSoon,
              variant: SokoVariant.info,
              duration: const Duration(seconds: 3),
            );
          },
        ),
      ],
    );
  }

  bool _isSuggestionSaved(ItemSuggestion suggestion) {
    final api = ref.read(listsApiProvider);
    // Check if this item is already in the current list
    if (suggestion.eventId != null) {
      return api.isInList(widget.listId, eventId: suggestion.eventId);
    }
    if (suggestion.venueId != null) {
      return api.isInList(widget.listId, venueId: suggestion.venueId);
    }
    if (suggestion.googlePlaceId != null) {
      return api.isInList(
        widget.listId,
        googlePlaceId: suggestion.googlePlaceId,
      );
    }
    return false;
  }

  Future<void> _disableSuggestions() async {
    try {
      // Clear prompt optimistically
      ref
          .read(unifiedListProvider(widget.listId).notifier)
          .updateListOptimistic(clearPrompt: true);

      // Clear suggestions state
      ref.read(listSuggestionsProvider(widget.listId).notifier).clear();

      // Persist to backend
      await ref
          .read(listsProvider.notifier)
          .updateList(widget.listId, const UserListUpdate(clearPrompt: true));

      ref
          .read(unifiedAnalyticsProvider)
          .trackSuggestionPromptDisable(listId: widget.listId);
    } catch (e) {
      if (mounted) {
        showSoko(ref, message: e.toString(), variant: SokoVariant.error);
      }
    }
  }

  void _showEditPromptDialog(BuildContext context) {
    final l10n = Lt.of(context);
    final controller = TextEditingController(text: widget.prompt);
    final isEmpty = ValueNotifier(controller.text.trim().isEmpty);

    controller.addListener(() {
      isEmpty.value = controller.text.trim().isEmpty;
    });

    showDialog(
      context: context,
      builder: (dialogContext) {
        final isDark = Theme.of(dialogContext).brightness == Brightness.dark;
        final primaryColor = isDark
            ? AppColors.primaryDarkMode
            : AppColors.primary;

        return AlertDialog(
          title: Text(l10n.listsPromptLabel),
          content: TextField(
            controller: controller,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: l10n.listSuggestionsPromptPlaceholder,
              border: const OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.sentences,
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.listsButtonCancel),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: isEmpty,
              builder: (_, isFieldEmpty, __) {
                if (isFieldEmpty) {
                  // "Disable suggestions" button (destructive style)
                  return ElevatedButton(
                    onPressed: () {
                      Navigator.of(dialogContext).pop();
                      _showDisableConfirmation(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade600,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(l10n.listSuggestionsDisable),
                  );
                }
                // Normal "Save" button
                return ElevatedButton(
                  onPressed: () {
                    final newPrompt = controller.text.trim();
                    if (newPrompt.isNotEmpty && newPrompt != widget.prompt) {
                      _updatePrompt(newPrompt);
                    }
                    Navigator.of(dialogContext).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(l10n.listsButtonSave),
                );
              },
            ),
          ],
        );
      },
    ).then((_) => controller.dispose());
  }

  void _showDisableConfirmation(BuildContext context) {
    final l10n = Lt.of(context);

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.listSuggestionsDisableConfirmTitle),
        content: Text(l10n.listSuggestionsDisableConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.listsButtonCancel),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _disableSuggestions();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
            ),
            child: Text(l10n.listSuggestionsDisableConfirmButton),
          ),
        ],
      ),
    );
  }
}

/// Shimmer skeleton card that mimics the suggestion card layout.
class _ShimmerCard extends StatefulWidget {
  final bool isDark;
  const _ShimmerCard({required this.isDark});

  @override
  State<_ShimmerCard> createState() => _ShimmerCardState();
}

class _ShimmerCardState extends State<_ShimmerCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _opacity = Tween<double>(
      begin: 0.3,
      end: 0.7,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shimmerColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    return FadeTransition(
      opacity: _opacity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            // Thumbnail placeholder — 54x54, rounded 6px
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: shimmerColor,
              ),
            ),
            const SizedBox(width: 12),
            // Text placeholders
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 12,
                    width: 140,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: shimmerColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 10,
                    width: 100,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: shimmerColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Send affordance for the Sugestões CTA input (Frame 9240). Uses the
/// Lucide `circle_arrow_right` glyph directly — the icon already
/// renders the circle stroke + arrow, so no outer filled container is
/// needed. 32 × 32 tap target with the glyph centred.
class _SuggestionsSendButton extends StatelessWidget {
  final VoidCallback onTap;

  const _SuggestionsSendButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: const SizedBox(
          width: 32,
          height: 32,
          child: Center(
            child: Icon(
              LucideIcons.circle_arrow_right,
              size: 14,
              color: AppColors.sokoInk,
            ),
          ),
        ),
      ),
    );
  }
}
