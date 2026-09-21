import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/guest_feature_placeholder.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../providers/map_past_search_reexecutor.dart';
import '../providers/map_search_history_provider.dart';
import 'map_past_searches_clear_sheet.dart';
import 'map_suggest_rows.dart';

/// Whether list rows are shown in the panel.
///
/// **ON since PROD-3568.** It was `false` while list execution didn't exist:
/// PROD-3498 shipped keyword/venue/event/location only, because `POST
/// /map/pins` had no list scoping (Decision #20 had no backend), so a list row
/// would resolve, bump recency and then visibly do nothing.
///
/// The filtering was always at RENDER only and nothing was deleted server-side,
/// which is what makes this flip cheap: entries recorded before the cut come
/// back with it. In practice there are few — `kMapSuggestShowLists` gated the
/// only producer, so history could barely accumulate. That asymmetry is why the
/// ticket orders the suggest flag first: this one reveals what that one
/// creates.
const bool kMapPastSearchesShowLists = true;

/// Leading type icon per history entry — same glyphs as the live
/// suggestion rows (PROD-3497's `mapSuggestIconFor`), so a re-executed row
/// reads as the thing it was.
IconData mapPastSearchIconFor(MapSearchHistoryType type) => switch (type) {
  MapSearchHistoryType.keyword => LucideIcons.search,
  MapSearchHistoryType.venue => LucideIcons.store,
  MapSearchHistoryType.event => LucideIcons.calendar,
  MapSearchHistoryType.location => LucideIcons.map_pin,
  MapSearchHistoryType.list => LucideIcons.book_open,
};

/// PROD-3499 — the 0-typed-chars state of the focused map search mode:
/// past-search rows (tap = re-execute with a fresh resolve, Decision #21
/// staleness), per-row delete + clear-all (Decision #31), the no-history
/// explainer (Decision #25), and the guest login state (Decision #41).
///
/// Rendered by the dropdown ladder switcher when the bar text is empty
/// (PROD-3497's `MapSuggestDropdown`); the container above provides
/// scrolling and width. Rows render through the shared
/// `MapSuggestRowShell` (E2: history rows share anatomy with live
/// suggestions), plus this ticket's additive `trailing`/`onLongPress`.
class MapPastSearchesPanel extends ConsumerStatefulWidget {
  const MapPastSearchesPanel({super.key});

  @override
  ConsumerState<MapPastSearchesPanel> createState() =>
      _MapPastSearchesPanelState();
}

class _MapPastSearchesPanelState extends ConsumerState<MapPastSearchesPanel> {
  /// One re-execution at a time — a second tap while a resolve is in
  /// flight is dropped (no visual state; resolves are sub-second).
  bool _executing = false;

  Future<void> _onRowTap(MapSearchHistoryEntry entry, int index) async {
    if (_executing) return;
    _executing = true;
    try {
      final locale = Localizations.localeOf(context).languageCode;
      final outcome = await ref
          .read(mapPastSearchReExecutorProvider)
          .execute(entry, locale: locale);
      if (!mounted) return;
      switch (outcome) {
        case MapPastSearchTapOutcome.executed:
          await ref
              .read(unifiedAnalyticsProvider)
              .trackMapPastSearchUsed(type: entry.type.wire, position: index);
        case MapPastSearchTapOutcome.stale:
          showSokoFromContext(
            context,
            message: Lt.of(context).mapPastSearchStaleToast,
          );
          await ref
              .read(mapSearchHistoryProvider.notifier)
              .removeStale(entry.id);
        case MapPastSearchTapOutcome.transientError:
          // A network blip is not staleness — keep the row (Decision #21
          // removal is reserved for genuinely dead targets).
          break;
      }
    } finally {
      _executing = false;
    }
  }

  Future<void> _onClearAll() async {
    final notifier = ref.read(mapSearchHistoryProvider.notifier);
    await showMapPastSearchesClearSheet(
      context,
      ref: ref,
      onClear: notifier.clearAll,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    if (!ref.watch(isAuthenticatedProvider)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: GuestFeaturePlaceholder(
          icon: LucideIcons.history,
          subtitle: l10n.mapPastSearchesGuestExplainer,
          compact: true,
          onSignUp: () {
            ref
                .read(unifiedAnalyticsProvider)
                .trackAuthPrompt(
                  page: AuthPage.login,
                  action: AuthPromptAction.view,
                  referrer: AuthReferrer.guestMapPastSearches,
                );
            navigateToLoginPreservingReturn(
              context,
              ref,
              referrer: AuthReferrer.guestMapPastSearches,
            );
          },
        ),
      );
    }

    final history = ref.watch(mapSearchHistoryProvider);
    return history.when(
      loading: () => const SizedBox(
        height: 64,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.sokoInkSecondary,
            ),
          ),
        ),
      ),
      error: (_, __) => _RetryRow(
        label: l10n.mapPastSearchesRetry,
        onRetry: () => ref.invalidate(mapSearchHistoryProvider),
      ),
      data: (all) {
        // Filtered BEFORE the empty check: a history of nothing but hidden
        // list rows must show the explainer, not an empty panel.
        final entries = kMapPastSearchesShowLists
            ? all
            : [
                for (final e in all)
                  if (e.type != MapSearchHistoryType.list) e,
              ];
        if (entries.isEmpty) {
          return MapSuggestExplainer(text: l10n.mapPastSearchesEmptyExplainer);
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.mapPastSearchesHeader,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.sokoShade2,
                      ),
                    ),
                  ),
                  Clickable(
                    onTap: _onClearAll,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Text(
                        l10n.mapPastSearchesClearAll,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.sokoShade3,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            for (final (index, entry) in entries.indexed)
              _HistoryRow(
                entry: entry,
                deleteLabel: l10n.mapPastSearchDelete,
                onTap: () => _onRowTap(entry, index),
                onDelete: () => ref
                    .read(mapSearchHistoryProvider.notifier)
                    .removeEntry(entry.id),
              ),
          ],
        );
      },
    );
  }
}

/// One past-search row — the shared `MapSuggestRowShell` anatomy (E2/D33)
/// with the history-only extras: a trailing delete affordance and
/// long-press-to-delete.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.deleteLabel,
    required this.onTap,
    required this.onDelete,
  });

  final MapSearchHistoryEntry entry;
  final String deleteLabel;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final imageUrl = entry.imageUrl;
    return MapSuggestRowShell(
      onTap: onTap,
      onLongPress: onDelete,
      icon: mapPastSearchIconFor(entry.type),
      title: entry.displayLabel,
      // Thumb only where the original selection had one (E2).
      thumb: imageUrl == null
          ? null
          : SokoCardImage(
              imageUrl: imageUrl,
              seed: entry.targetId ?? entry.id,
              kind: switch (entry.type) {
                MapSearchHistoryType.venue => SokoEntityKind.venue,
                MapSearchHistoryType.event => SokoEntityKind.event,
                _ => SokoEntityKind.neutral,
              },
              width: 48,
              height: 48,
              borderRadius: BorderRadius.circular(6),
            ),
      trailing: Semantics(
        button: true,
        label: deleteLabel,
        child: Tooltip(
          message: deleteLabel,
          // Tooltip contributes its own semantics label; without this the
          // name is announced twice (seen in staging QA).
          excludeFromSemantics: true,
          child: Clickable(
            onTap: onDelete,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Icon(LucideIcons.x, size: 16, color: AppColors.sokoShade3),
            ),
          ),
        ),
      ),
    );
  }
}

/// Decision #25 — the "you can search for…" explainer shown when the
/// user has no history yet. Copy grows as searchable domains are added.
///
/// PROD-3652 made it public and shared: the domain tags' prompt-to-type is the
/// same thing in the same slot (a full-width line of muted guidance where rows
/// would otherwise be), and two copies of this padding and type ramp would
/// drift the first time either is touched.
class MapSuggestExplainer extends StatelessWidget {
  const MapSuggestExplainer({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w300,
          height: 1.3,
          color: AppColors.sokoShade3,
        ),
      ),
    );
  }
}

/// Quiet failure row with retry — the shell's muted styling, matching
/// PROD-3497's retry-row pattern (B6): no error styling storm inside the
/// dropdown.
class _RetryRow extends StatelessWidget {
  const _RetryRow({required this.label, required this.onRetry});

  final String label;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return MapSuggestRowShell(
      onTap: onRetry,
      icon: LucideIcons.refresh_cw,
      title: label,
      muted: true,
      titleMaxLines: 2,
    );
  }
}
