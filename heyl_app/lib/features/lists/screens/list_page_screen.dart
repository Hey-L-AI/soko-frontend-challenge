import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart'
    show AuthReferrer, unifiedAnalyticsProvider;
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../discovery/widgets/shell_sliver_page.dart';
import '../../instagram_share/providers/instagram_share_polling_provider.dart';
import '../../instagram_share/widgets/instagram_share_sheet.dart';
import '../../share/utils/share_deep_link.dart';
import '../../share/widgets/soko_share_sheet.dart';
import '../providers/list_followers_provider.dart';
import '../providers/unified_list_provider.dart';
import '../utils/zine_cover_seed.dart';
import '../widgets/add_items_to_list_sheet.dart';
import '../widgets/delete_list_sheet.dart';
import '../widgets/empty_zine_state.dart';
import '../widgets/list_page_header.dart';
import '../widgets/list_view_mode/list_view_mode_body.dart';
import '../widgets/share_list_sheet.dart';
import '../widgets/zine/list_zine_skeleton.dart';
import '../widgets/zine/list_zine_view.dart';
import '../widgets/zine_load_error_state.dart';

/// Which body [ListPageScreen] should render once the header is up.
///
/// A pure function, and deliberately so: this decision is precisely where the
/// page used to break, and it had no test because the only way to reach it was
/// through the whole shell. Extracting it makes the three states assertable
/// without scaffolding a screen.
///
/// The two defects it encodes against (both reported 2026-09-15, both showing
/// the SAME symptom — a zine frozen on its cover with no pager, nothing
/// scrollable, and no way out but Back):
///
///  - **A failed items fetch was invisible.** `loadItems` records `state.error`
///    and leaves `itemsLoaded` false with `items` empty; nothing here read
///    `error`, so it fell through to the zine view, whose static cover means
///    "items still loading". It never stopped meaning that.
///  - **The empty state was owner-gated.** A 0-item zine opened by anyone but
///    its owner skipped [EmptyZineState] entirely and hit the same dead cover.
///    Ownership gates the *Add* CTA, not the state.
enum ListPageBody {
  /// The items request failed and we have nothing to show. Offer a retry.
  itemsError,

  /// An item fetch completed and the list really is empty.
  empty,

  /// Render the normal body (zine pager, list view, or edit mode).
  content,
}

/// Resolve [ListPageBody] from the load state. See the enum for the history.
@visibleForTesting
ListPageBody resolveListPageBody(UnifiedListState state) {
  // Guarded on `items.isEmpty` so a failed background tail — or a failed quiet
  // refresh — never replaces a page the user is already reading with an error.
  if (state.error != null && state.items.isEmpty)
    return ListPageBody.itemsError;

  // `itemsLoaded` (a fetch actually completed), NOT `!isLoadingItems`: the
  // empty hero must never flash over the instant cover before items have been
  // fetched (PROD-4XXX — the cover-only seed window after a Library warm).
  // Edit mode is owner-only and renders its own body.
  if (state.itemsLoaded && state.items.isEmpty && !state.editMode) {
    return ListPageBody.empty;
  }

  return ListPageBody.content;
}

/// Admin-only redesigned list page (`/lists/:listId`). Foundations ticket
/// PROD-1702 — header + Zine/Lista toggle + body slot stub. The Zine view
/// body lands in PROD-1700 #4; the List view body in #5.
///
/// Mounts inside [DiscoveryShell] on a sliver-aware route (PROD-1977 —
/// see `_isShellSliverRoute` in `discovery_shell.dart`). The page owns
/// its own `CustomScrollView` via [ShellSliverHost], consuming the
/// shell's chrome metadata + scroll controller from the surrounding
/// [ShellSliverScope]. This is the actual viewport-culling unlock for
/// the List view's 355-item lists (PROD-1967 trigger).
///
/// The page body is wrapped in `ColoredBox(AppColors.sokoPaper)` so it
/// paints its own background. The shell's Scaffold also has
/// `backgroundColor: sokoPaper`, but on iOS (both native Cupertino and
/// Mobile Safari, both routed through `CupertinoPage` via `_detailPage`)
/// the Scaffold bg does NOT reliably paint through `CustomScrollView`'s
/// transparent gaps below the chrome — the body shows a darker grey
/// surface tint instead. The sibling detail screens
/// ([venue_detail_screen], [event_detail_screen],
/// [list_in_context_detail_screen]) all kept an inner `ColoredBox`
/// during the PROD-1977 migration for the same reason; this page was
/// the lone outlier and regressed on iOS. PROD-2018-followup.
///
/// See `docs/designs/list-page-redesign.md` § 7.1 (header) + § 6.4 (back
/// navigation) + § 9.2 (decisions), and
/// `docs/learnings/discoveryshell-sliver-aware-host.md` for the sliver
/// contract.
class ListPageScreen extends ConsumerStatefulWidget {
  final String listId;

  /// Initial view mode override — `?view=list` / `?view=zine` from the
  /// route's query param (PROD-1764). When null, the screen falls back
  /// to the default Zine view per § 9.2 #1. Used by the chat success
  /// state's "Ver lista" action to land users directly in List view.
  final ListViewMode? initialViewMode;

  /// PROD-3319 — non-null when the route carried a recognised `?share=`
  /// param (share-nudge push deep link). Auto-presents the share sheet
  /// once the list loads; see [ShareDeepLinkAutoPresent].
  final ShareDeepLinkAction? autoShareAction;

  const ListPageScreen({
    super.key,
    required this.listId,
    this.initialViewMode,
    this.autoShareAction,
  });

  @override
  ConsumerState<ListPageScreen> createState() => _ListPageScreenState();
}

class _ListPageScreenState extends ConsumerState<ListPageScreen>
    with ShareDeepLinkAutoPresent<ListPageScreen> {
  @override
  ShareDeepLinkAction? get autoShareAction => widget.autoShareAction;

  /// Held so [dispose] never has to touch `ref` — `ref.read` inside
  /// `ConsumerState.dispose()` **always throws** (`Bad state: Cannot use "ref"
  /// after the widget was disposed`), because `StatefulElement.unmount()` nulls
  /// `_widget` in `super.unmount()` before calling `state.dispose()`. That is
  /// why the `exitEditMode()` below used to sit in a `try/catch` that swallowed
  /// every single call — PROD-1783's behaviour never actually ran. See
  /// `docs/learnings/ref-read-in-consumerstate-dispose-always-throws.md`.
  ///
  /// Re-captured on every [build] rather than once in `initState`: the family
  /// entry is **invalidated** while this page can still be mounted (the block
  /// dialog does `ref.invalidate(unifiedListProvider(listId))` when you block a
  /// user from this list), which disposes the old notifier and builds a new
  /// one. A one-shot capture would leave this pointing at a disposed
  /// `StateNotifier`, and `exitEditMode()` on that throws — re-introducing the
  /// very "dispose() aborts early" failure this change exists to remove.
  /// `build` already watches the provider, so it re-runs on invalidation and on
  /// a `listId` swap, which keeps this field pointed at the live notifier.
  UnifiedListNotifier? _listNotifier;

  /// PROD-3211: measures screen init → first loaded render for
  /// `screen_load_complete` (the zine open showed 20+ second skeletons and
  /// we had no performance events at all). One-shot per mount.
  final Stopwatch _loadStopwatch = Stopwatch()..start();
  bool _loadTracked = false;

  @override
  void initState() {
    super.initState();
    // Default the screen to Zine view per § 9.2 #1. Force on every mount
    // so navigation away + back returns to Zine; a user-driven toggle to
    // List within this widget's lifecycle still persists.
    //
    // PROD-1764: when the route carries `?view=list` (or `?view=zine`),
    // honour that instead of the Zine default.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(unifiedListProvider(widget.listId).notifier);
      notifier.setViewMode(widget.initialViewMode ?? ListViewMode.zine);
      // PROD-4XXX: guarantee the full load (metadata + first page + tail)
      // runs on open. Idempotent — a no-op when the factory already
      // full-loaded (default path), and the upgrade trigger when the Library
      // warmed this list with a lightweight cover+first-pages prefetch.
      // ignore: discarded_futures
      notifier.ensureFullyLoaded();
    });
  }

  @override
  void dispose() {
    // PROD-1783: exit edit mode when the user navigates away so coming
    // back to the list lands on the read-only surface again — the next
    // visit simply observes `editMode: false`.
    //
    // Uses the notifier captured in [build]; NEVER reach for `ref` here.
    // `mounted` guards the narrow window where the entry was invalidated and
    // this page is torn down before the rebuild that would refresh the field.
    final notifier = _listNotifier;
    if (notifier != null && notifier.mounted) notifier.exitEditMode();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(unifiedListProvider(widget.listId));
    // Keep the teardown handle pointed at the LIVE notifier — see
    // [_listNotifier]. The `watch` above is what re-runs this on invalidation.
    _listNotifier = ref.read(unifiedListProvider(widget.listId).notifier);

    // PROD-3211: first build with a loaded list = the skeleton is gone.
    // Post-frame so the duration includes the loaded frame's paint.
    if (!_loadTracked && state.list != null) {
      _loadTracked = true;
      _loadStopwatch.stop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(unifiedAnalyticsProvider)
            .trackScreenLoadComplete(
              screen: 'list_page',
              durationMs: _loadStopwatch.elapsedMilliseconds,
            );
      });
    }

    // PROD-3319: `?share=` deep link → auto-present the share sheet once
    // the list loads. Routes through [_handleShare], so the owner-private
    // "make public?" warning applies exactly as on a manual tap.
    maybeAutoPresentShare(
      ready: state.list != null,
      present: () => _handleShare(analyticsEntryPoint: shareDeepLinkEntryPoint),
    );

    // PROD-1755: silently re-fetch when an Instagram share completes so the
    // new items appear without a manual pull-to-refresh. Mirrors the listener
    // in the legacy [ListViewScreen]; the polling provider also fans out by
    // both slug + UUID family keys so re-entry works even when we weren't
    // mounted at completion time.
    ref.listen<InstagramSharePollingState>(instagramSharePollingProvider, (
      previous,
      next,
    ) {
      final wasCompleted = previous?.isCompleted ?? false;
      if (!next.isCompleted || wasCompleted) return;
      // ignore: discarded_futures
      ref.read(unifiedListProvider(widget.listId).notifier).loadItemsQuietly();
    });

    // PROD-1977: the page owns its own CustomScrollView via
    // ShellSliverHost. The host reads chrome reservation + scroll
    // controller + physics + optional refresh handler from
    // [ShellSliverScope] (set up by the shell on sliver-aware routes —
    // see `_isShellSliverRoute` in `discovery_shell.dart`).
    //
    // [ColoredBox] explicitly paints the page bg so we don't rely on
    // the Scaffold bg painting through the transparent CustomScrollView
    // — see the class doc above for the iOS-specific reason.
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: ShellSliverHost(slivers: _buildSlivers(context, state)),
    );
  }

  List<Widget> _buildSlivers(BuildContext context, UnifiedListState state) {
    if (state.isNotFound) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _CenteredMessage(text: Lt.of(context).publicListNotFound),
        ),
      ];
    }
    if (state.list == null) {
      // PROD-4160-followup — on the FIRST (uncached) open, paint the zine cover
      // from the Library tap's [ZineCoverSeed] instead of a bare spinner, so the
      // Library → cover `Hero` has its destination laid out on frame 1 (else the
      // flight is skipped and the morph only runs on the second, cached open).
      // Falls back to the spinner on a cold deep-link (no seed, no source hero).
      final coverSeed = ref.zineCoverSeed(widget.listId);
      if (coverSeed != null) {
        return [
          // Reserve the header's vertical footprint BEFORE the cover so the
          // Library → cover Hero lands at the cover's FINAL resting position.
          // Without this, the header ([ListPageHeader] — stats line + action
          // row) only mounts once the list data arrives and inserts ABOVE the
          // cover, shoving the just-landed cover down (~header height) — read
          // as the cover "snapping" right after the flight. Mirrors
          // ListPageHeader's non-edit footprint (stats ~20 + 16 gap + action
          // row ~40 + 20 bottom pad); tune if that header's height changes.
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
          SliverToBoxAdapter(
            child: ZineCoverLoading(
              listId: widget.listId,
              recipe: coverSeed.recipe,
              title: coverSeed.title,
            ),
          ),
        ];
      }
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CircularProgressIndicator(color: AppColors.sokoInk),
          ),
        ),
      ];
    }

    // Back arrow + 42 px Mobile/H1 list name are owned by the shell-
    // level [PinnedPageChrome]; this body starts with the (scrolling)
    // metadata block — stats line + action row — followed by the zine
    // or list view body.
    final headerSliver = SliverToBoxAdapter(
      child: ListPageHeader(
        state: state,
        onModeChanged: _onModeChanged,
        onShare: _handleShare,
        onEdit: _handleEdit,
        onAdd: _handleAdd,
        onSetVisibility: _handleSetVisibility,
        onDelete: _handleDelete,
        onFollow: _handleFollow,
        onSaveAsOwnZine: _handleSaveAsOwnZine,
      ),
    );

    // PROD-1956 / PROD-4XXX: while items are still loading on first open,
    // the List view has no free cover to show, so it keeps the zine-shaped
    // skeleton. The Zine view instead renders its metadata-only cover
    // immediately (see the zine branch below) and streams pages in — no
    // full-screen skeleton. Gated on `items.isEmpty` so quiet refreshes
    // (`loadItemsQuietly()` from the Instagram share listener above) never
    // replace the live UI with a skeleton; only the first load shows it.
    if (state.viewMode != ListViewMode.zine &&
        state.isLoadingItems &&
        state.items.isEmpty) {
      return [
        headerSliver,
        const SliverToBoxAdapter(child: ListZineSkeleton()),
      ];
    }

    // An items fetch that FAILED lands here: `loadItems` swallows the error
    // into `state.error`, clears `isLoadingItems`, and leaves `itemsLoaded`
    // false with `items` empty. This screen never read `state.error`, so that
    // combination fell through to the zine view's "still loading" static cover
    // and stayed there — no spinner, no message, no retry, and on a short page
    // nothing even scrollable (reported 2026-09-15). Metadata and items are two
    // separate parallel requests, so "header rendered, body empty" is a
    // reachable steady state, not a passing frame.
    //
    // Guarded on `items.isEmpty` so a failed background tail or a failed quiet
    // refresh never replaces a page the user is already reading with an error.
    final bodyState = resolveListPageBody(state);

    if (bodyState == ListPageBody.itemsError) {
      return [
        headerSliver,
        SliverToBoxAdapter(
          child: ZineLoadErrorState(
            onRetry: () {
              // ignore: discarded_futures
              ref.read(unifiedListProvider(widget.listId).notifier).refresh();
            },
          ),
        ),
      ];
    }

    // PROD-1852 Figma frame 6353:28267 — an empty list shows the newspaper
    // hero, regardless of the Zine/Lista toggle. The owner additionally gets
    // the "Adicionar algo" CTA; a visitor gets illustration + headline.
    // PROD-4XXX: gated on `itemsLoaded` (an item fetch actually completed)
    // instead of `!isLoadingItems` so the hero never flashes over the
    // instant cover before items have been fetched (e.g. the cover-only
    // seed window after a Library warm).
    //
    // NOT gated on `isOwner`. It used to be, which meant the only empty-state
    // widget in the app was unreachable for visitors: a 0-item zine opened by
    // anyone but its owner fell through to the zine view's static cover and
    // froze there (same reported symptom as the error path above). Ownership
    // now gates only the CTA, inside [EmptyZineState].
    if (bodyState == ListPageBody.empty) {
      final list = state.list!;
      return [
        headerSliver,
        SliverToBoxAdapter(
          child: EmptyZineState(
            listId: list.id,
            listName: list.name,
            canAdd: state.isOwner,
          ),
        ),
        // ListSuggestionsSection removed (PROD-2004 final) — the
        // "Suggested for you" CTA and section sat below EmptyZineState.
        // The feature was disabled while the search-results pipeline
        // (Google fallback name/image parsing) is sorted out.
      ];
    }

    // Edit mode is owner-only and renders the legacy `ReorderableListView`-
    // based body. Wrapped in a single `SliverToBoxAdapter` (same shape as
    // the non-opted-in path) — eager-build cost is fine here, the page is
    // owner-only and short-lived.
    if (state.editMode && state.isOwner) {
      return [
        headerSliver,
        SliverToBoxAdapter(
          child: ListViewModeBody(listId: widget.listId, state: state),
        ),
      ];
    }

    if (state.viewMode == ListViewMode.zine) {
      return [
        headerSliver,
        SliverToBoxAdapter(
          child: ListZineView(listId: widget.listId, state: state),
        ),
      ];
    }

    if (state.viewMode == ListViewMode.list) {
      // PROD-1977: read-mode List view emits real slivers, so off-screen
      // rows are not built. This is the viewport-culling unlock for long
      // lists (PROD-1967 trigger).
      return [
        headerSliver,
        ...buildListViewModeBodySlivers(
          context,
          ref,
          listId: widget.listId,
          state: state,
        ),
      ];
    }

    return [
      headerSliver,
      SliverToBoxAdapter(child: _BodyStub(viewMode: state.viewMode)),
    ];
  }

  void _onModeChanged(ListViewMode mode) {
    final previous = ref.read(unifiedListProvider(widget.listId)).viewMode;
    ref.read(unifiedListProvider(widget.listId).notifier).setViewMode(mode);
    // PROD-3209: only user-driven toggles reach this callback (the mount
    // default goes through setViewMode directly in initState).
    if (previous != mode) {
      ref
          .read(unifiedAnalyticsProvider)
          .trackZineViewModeChange(
            zineId:
                ref.read(unifiedListProvider(widget.listId)).list?.id ??
                widget.listId,
            mode: mode.name,
          );
    }
  }

  /// [analyticsEntryPoint] overrides the `entry_point` on
  /// `share_intent_fired` — `deep_link` when invoked by the PROD-3319
  /// `?share=` auto-present, null (→ `share_sheet`) for the manual button.
  void _handleShare({String? analyticsEntryPoint}) {
    final state = ref.read(unifiedListProvider(widget.listId));
    final list = state.list;
    if (list == null) return;
    if (state.isOwner && list.visibility == ListVisibility.private) {
      _showPrivateListShareWarning(
        context,
        state,
        analyticsEntryPoint: analyticsEntryPoint,
      );
    } else {
      showSokoShareSheet(
        context: context,
        ref: ref,
        shareContext: 'list',
        entityId: list.id,
        shareUrl: buildListShareUrl(list),
        analyticsEntryPoint: analyticsEntryPoint,
      );
    }
  }

  /// Owner-on-private-list share path: ask whether to flip the list to
  /// public before opening the share sheet.
  void _showPrivateListShareWarning(
    BuildContext context,
    UnifiedListState state, {
    String? analyticsEntryPoint,
  }) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.lock_outline, color: primaryColor),
            const SizedBox(width: 12),
            Expanded(child: Text(l10n.shareListPrivateTitle)),
          ],
        ),
        content: Text(l10n.shareListPrivateMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.listActionCancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              _makeListPublicAndShare(
                state,
                analyticsEntryPoint: analyticsEntryPoint,
              );
            },
            style: FilledButton.styleFrom(backgroundColor: primaryColor),
            child: Text(l10n.shareListMakePublic),
          ),
        ],
      ),
    );
  }

  Future<void> _makeListPublicAndShare(
    UnifiedListState state, {
    String? analyticsEntryPoint,
  }) async {
    final success = await _setVisibility(ListVisibility.public);
    if (!success) return;
    final updatedState = ref.read(unifiedListProvider(widget.listId));
    if (mounted && updatedState.list != null) {
      showSokoShareSheet(
        context: context,
        ref: ref,
        shareContext: 'list',
        entityId: updatedState.list!.id,
        shareUrl: buildListShareUrl(updatedState.list!),
        analyticsEntryPoint: analyticsEntryPoint,
      );
    }
  }

  /// Owner-only: persist a visibility flip with optimistic UI. Captures the
  /// previous visibility before the flip, mutates state for instant feedback,
  /// then PATCHes the backend. On failure we revert to the original
  /// visibility and surface a SnackBar — returns false so callers (share
  /// flow, dropdown toggle) can skip their success follow-up.
  Future<bool> _setVisibility(ListVisibility next) async {
    final notifier = ref.read(unifiedListProvider(widget.listId).notifier);
    final previous = ref
        .read(unifiedListProvider(widget.listId))
        .list
        ?.visibility;
    if (previous == null || previous == next) return previous == next;
    notifier.updateVisibilityOptimistic(next);
    try {
      await ref
          .read(listsProvider.notifier)
          .updateList(widget.listId, UserListUpdate(visibility: next));
      await notifier.refresh();
      return true;
    } catch (e) {
      notifier.updateVisibilityOptimistic(previous);
      if (mounted) {
        showSoko(ref, message: e.toString(), variant: SokoVariant.error);
      }
      return false;
    }
  }

  /// Owner-only segmented-toggle action: set visibility to an explicit value.
  /// Used by the inline `ListVisibilityToggle` below the title. Reuses
  /// [_setVisibility]'s optimistic update + error revert; no SnackBar on
  /// success — the pill itself is the visual confirmation.
  Future<void> _handleSetVisibility(ListVisibility next) async {
    final state = ref.read(unifiedListProvider(widget.listId));
    if (state.list == null || !state.isOwner) return;
    await _setVisibility(next);
  }

  /// Owner-only dropdown action: confirm via [DeleteListSheet], then
  /// delete + navigate back to the lists hub. Passes the fully-resolved
  /// [UserList] from `unifiedListProvider` directly to
  /// `listsProvider.deleteList`; the provider no longer performs any
  /// id-based lookup on `state.lists` (PROD-2084 — that lookup crashed
  /// on deep-link entry where `state.lists` was empty).
  Future<void> _handleDelete() async {
    final state = ref.read(unifiedListProvider(widget.listId));
    final list = state.list;
    if (list == null || !state.isOwner) return;
    final l10n = Lt.of(context);
    final router = GoRouter.of(context);
    final confirmed = await showDeleteListSheet(
      context,
      ref: ref,
      listName: list.name,
      onDelete: () async {
        try {
          await ref.read(listsProvider.notifier).deleteList(list);
          return true;
        } catch (e, st) {
          // PROD-2084 — localized, friendly copy. Previously surfaced
          // the raw `e.toString()` (e.g. "Bad state: No element") to
          // the user; now mirrors the rest of the lists feature with a
          // generic retry-able message regardless of the underlying
          // error class.
          //
          // Also forward to Sentry. Best-effort and non-blocking —
          // before this PR the delete catch was the only signal that
          // anything went wrong, so the original "Bad state: No
          // element" bug stayed invisible until a user reported it
          // directly. `unawaited` ensures the captureException Future
          // never delays or fails the surrounding handler.
          unawaited(Sentry.captureException(e, stackTrace: st));
          showSoko(
            ref,
            message: l10n.listDeleteError,
            variant: SokoVariant.error,
          );
          return false;
        }
      },
    );
    if (confirmed != true || !mounted) return;
    // PROD-2084 — no explicit `ref.invalidate(...)` here. The
    // listen+invalidate anti-pattern (see
    // docs/learnings/riverpod-listen-and-invalidate-fight.md from
    // PROD-1918) would race a refetch against the tombstone-filtered
    // state under BE read-after-write lag, allowing the just-deleted
    // list to reappear in the library.
    //
    // Instead we trust the tombstone signal end-to-end:
    //   - yoursShelfProvider is autoDispose. After navigation it
    //     re-mounts and runs build(), which filters the fresh API
    //     response against `recentlyDeletedListIds`.
    //   - If the shelf happens to still be alive, its
    //     `ref.listen(listsProvider, ...)` patches the cached state
    //     by removing tombstoned ids.
    //   - listsHubItemsProvider reads the tombstone set via
    //     `ref.watch(listsProvider.select(...))`, so it rebuilds
    //     automatically when a tombstone is added and filters its
    //     synthetic map pins / calendar dots accordingly. The family
    //     (PROD-2128) watches both modes against the same tombstone set.
    router.go(AppRoutes.library);
    showSoko(
      ref,
      message: l10n.listDeletedSuccess,
      variant: SokoVariant.success,
    );
  }

  /// PROD-1783: tapping Edit enters page-level edit mode. The notifier
  /// forces `viewMode = list` in the same flip so the cover row + inline
  /// editors only ever paint inside the List view body. Replaces the
  /// previous `EditListDialog` modal — that flow is still alive on the
  /// legacy `ListViewScreen` for non-admin callers.
  void _handleEdit() {
    final state = ref.read(unifiedListProvider(widget.listId));
    if (state.list == null || !state.isOwner) return;
    // Async since PROD-zine-sort: an active sort is restored (and refetched)
    // before edit mode opens, so the reorder never sees the sorted rows.
    // ignore: discarded_futures
    ref.read(unifiedListProvider(widget.listId).notifier).enterEditMode();
  }

  /// PROD-1852 (revised on `investigate/PROD-zine-add-item-freeze`):
  /// owner-only Add button. Opens [AddItemsToListSheet] as a modal bottom
  /// sheet on top of the list page. Replaces the previous full-page route
  /// (`/lists/:id/add-items`), which forced the list view (Mapbox cover
  /// map + PROD-1955 zine pager) to dispose + remount on each round trip
  /// — that mount churn was driving a render-time exception storm.
  ///
  /// Passes the resolved list UUID (`state.list.id`) — NOT
  /// `widget.listId`, which may be the URL slug. The backend `POST
  /// /lists/{list_id}/items` endpoint requires a UUID and 422s on slugs.
  ///
  /// The sheet returns `true` when the user taps "Share Instagram link"
  /// in its footer — same handoff contract the page used.
  Future<void> _handleAdd() async {
    final state = ref.read(unifiedListProvider(widget.listId));
    final list = state.list;
    if (list == null || !state.isOwner) return;
    final result = await showAddItemsToListSheet(
      context,
      ref: ref,
      listId: list.id,
      listName: list.name,
    );
    if (result == true && mounted) {
      // ignore: use_build_context_synchronously
      showInstagramShareSheet(context, ref: ref, source: 'list_page_add_items');
    }
  }

  void _handleFollow() {
    // PROD-1979 — gate at the caller. The provider's `toggleFollow`
    // keeps its `!_isAuthenticated()` early-return as defense-in-depth,
    // but the user-facing CTA lives here where we have context + ref.
    requireAuth(
      context,
      ref,
      action: Lt.of(context).guestFollowAction,
      referrer: AuthReferrer.guestFollowList,
      onAuthenticated: () async {
        final ok = await ref
            .read(unifiedListProvider(widget.listId).notifier)
            .toggleFollow();
        if (!ok || !mounted) return;
        // Refresh the zine's followers list + cover "Followed by …" line so the
        // viewer's own row appears/disappears in the same beat as the toggle,
        // instead of only after a manual reload. Keyed by the resolved UUID —
        // the route id may be a slug.
        final resolvedId = ref
            .read(unifiedListProvider(widget.listId))
            .list
            ?.id;
        if (resolvedId != null) {
          ref.invalidate(listFollowersProvider(resolvedId));
        }
      },
    );
  }

  /// PROD-1953 weekly-bundle CTA. Today: stubbed — the OpenAPI spec has
  /// no `POST /lists/{id}/duplicate` (or equivalent) endpoint that
  /// forks a system-managed list into a user-owned zine. Per
  /// CLAUDE.md we don't invent endpoints client-side, so the button
  /// surfaces a "coming soon" SnackBar until the BE lands.
  void _handleSaveAsOwnZine() {
    final l10n = Lt.of(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.listsHubComingSoon)));
  }
}

class _BodyStub extends StatelessWidget {
  final ListViewMode viewMode;

  const _BodyStub({required this.viewMode});

  @override
  Widget build(BuildContext context) {
    final isZine = viewMode == ListViewMode.zine;
    final stubText = isZine
        ? '[stub] Zine view — implemented in PROD-1700 #4'
        : '[stub] List view — implemented in PROD-1700 #5';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 80),
      child: Center(
        child: Text(
          stubText,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w300,
            color: AppColors.sokoInk,
          ),
        ),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  final String text;

  const _CenteredMessage({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, color: AppColors.sokoInk),
        ),
      ),
    );
  }
}
