import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/soko_haptics.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/dashed_border_painter.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/list_thumbnail_stack.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_text_field.dart';
import '../../moderation/content_blocked_handler.dart';
import '../utils/list_membership_staging.dart';
import '../utils/unsave_cascade.dart';
import '../utils/zine_cover_recipe.dart';
import '../providers/unified_list_provider.dart';
import '../screens/create_zine_screen.dart';
import 'cascade_unsave_confirm_dialog.dart';

/// PROD-3983 — the detents of the post-quicksave sheet, as fractions of the
/// viewport. Shared by the `DraggableScrollableSheet` that hosts it and by
/// [_ExtentDragArea], which resizes it from the drag handle: the two must agree
/// or the handle would settle somewhere the sheet won't stay.
const double _kPeekExtent = 0.40;
const double _kFullExtent = 0.95;
const double _kMinExtent = 0.25;

/// Released below this, the sheet closes instead of springing back to
/// [_kPeekExtent]. Sits between the peek and the floor.
const double _kDismissExtent = 0.33;

/// Viewport-fractions per second that count as a fling rather than a drag.
const double _kFlingVelocity = 0.7;

const double _kExtentEpsilon = 0.005;

/// Maps a backend save-refusal `error_code` (carried by
/// [ListsNotifier.saveRejectedPrefix]) to localized copy. Unknown codes fall
/// back to the generic retry message.
String _localizedSaveRejection(Lt l10n, String errorCode) {
  switch (errorCode) {
    case 'PLACE_NOT_SAVEABLE':
      return l10n.addToListErrorPlaceNotSaveable;
    case 'PLACE_UNAVAILABLE':
      return l10n.addToListErrorPlaceUnavailable;
    default:
      return l10n.addToListErrorSaveFailed;
  }
}

/// Result from the add to list sheet
class AddToListResult {
  final bool success;
  final List<String> addedListIds;
  final List<String> removedListIds;

  const AddToListResult({
    required this.success,
    this.addedListIds = const [],
    this.removedListIds = const [],
  });

  /// Check if a specific list was removed
  bool wasRemovedFrom(String listId) => removedListIds.contains(listId);

  /// Check if a specific list was added to
  bool wasAddedTo(String listId) => addedListIds.contains(listId);
}

/// Bottom sheet for adding an item to one or more lists
class AddToListSheet extends ConsumerStatefulWidget {
  final ItemSuggestion place;

  /// Source of the action for analytics tracking.
  /// Use [ListSource] constants: 'chat' or 'list_ui'
  final String? source;

  /// PROD-3116 — when set, saves target this single occurrence of the event
  /// rather than the whole event. Only meaningful for event items.
  final String? eventOccurrenceId;

  /// PROD-3873 — when the sheet is presented half-open (a peek) inside a
  /// [DraggableScrollableSheet], the drag controller is threaded in here so
  /// dragging the list also resizes the sheet. Null for the normal full-height
  /// presentation, where the sheet owns its own [ScrollController].
  final ScrollController? externalScrollController;

  /// PROD-3983 — compact chrome for the short (1/3) presentation: the pink
  /// banner loses its subtitle and shrinks its thumbnail, so a list row still
  /// fits above the footer.
  final bool compact;

  /// PROD-3983 — the sheet's own extent controller, so the drag handle can
  /// resize the sheet (it sits outside the scrollable the
  /// [DraggableScrollableSheet] listens to).
  final DraggableScrollableController? extentController;

  /// The quicksave that opened this sheet, still in flight.
  ///
  /// The sheet no longer waits for it. Which sheet to show is decided from
  /// "was this already saved", which is known synchronously — so the drawer
  /// appears on the tap and this resolves underneath it. On success it fills
  /// [_AddToListSheetState._quickSavedListId] (the tip's fallback target, read
  /// only when the user commits). On a rejection it reports and closes: the
  /// bookmark has reverted, so an "also file it in a zine" nudge would be
  /// offering something that did not happen.
  ///
  /// Null for the manage-an-existing-save presentation, which has no save
  /// behind it.
  final Future<QuickSaveResult>? pendingQuickSave;

  /// PROD-4553 — the save-flow correlation key allocated in
  /// [showAddToListSheet] at the tap that opened this flow. Shared with the
  /// [pendingQuickSave] that may have preceded the sheet, so a note the user
  /// adds when committing the drawer joins the same save flow.
  final String saveFlowId;

  const AddToListSheet({
    super.key,
    required this.place,
    this.source,
    this.eventOccurrenceId,
    this.externalScrollController,
    this.compact = false,
    this.extentController,
    this.pendingQuickSave,
    required this.saveFlowId,
  });

  @override
  ConsumerState<AddToListSheet> createState() => _AddToListSheetState();
}

class _AddToListSheetState extends ConsumerState<AddToListSheet> {
  // In-session ticks vs "was it in the list on open?" — see
  // [ListMembershipStaging]. Persist diffs these; async preselect must not
  // overwrite a tap (PROD-4185).
  final _staging = ListMembershipStaging();
  final _tipController = TextEditingController();
  // Focus on the note input drives the sticky-footer's keyboard avoidance.
  // We only lift the footer when the user is actually typing a note —
  // tapping the search field at the top should not push the footer up.
  final _noteFocusNode = FocusNode();

  // Search state
  final _searchController = TextEditingController();
  Timer? _debounceTimer;
  String _lastSearchQuery = '';
  List<UserList> _searchResults = [];
  bool _isSearching = false;
  int _searchGeneration = 0;

  // PROD-2138: true while `_persistNoteAndClose` has API work in flight.
  // Locks the Save button + the rest of the sheet body (via IgnorePointer +
  // opacity dim) so the user can't double-tap, edit selections, or dismiss
  // the sheet mid-commit. Cleared by sheet pop on success / by a setState
  // on error so the user can retry.
  bool _isSaving = false;

  // PROD-3983 — true while the draggable sheet sits at (or near) the short
  // detent. Drives the compact banner and the hidden footer, and flips live as
  // the user drags, so the banner blooms back to full size on the way up.
  bool _isShort = false;
  static const _shortExtentCutoff = 0.5;

  // Infinite-scroll + pre-selection bookkeeping
  bool _isLoadingMore = false;
  final ScrollController _ownScrollController = ScrollController();
  // Use the drag controller when the sheet is presented half-open (peek);
  // otherwise the sheet's own controller. Never dispose the external one — the
  // DraggableScrollableSheet owns its lifecycle.
  ScrollController get _scrollController =>
      widget.externalScrollController ?? _ownScrollController;
  final Set<String> _processedListIds = {};
  // True when _loadPreSelectedLists succeeded — skip the local-cache fallback
  // for new pages/search results to avoid stale-positive pre-selects.
  bool _preSelectionIsAuthoritative = false;
  // Lists that already contain this item, rendered at the top of the sheet in
  // browse mode so the user sees "where it's already saved" before scanning
  // the rest. Populated by _loadPreSelectedLists (authoritative path); empty
  // in the fallback path — the fallback relies on `_staging.initial` to sort
  // `listsState.lists` with matches first (see _buildListContent).
  List<UserList> _preSelectedLists = [];

  /// The list the quicksave filed the item into, once it answers. Null until
  /// then, and null forever on the manage-an-existing-save presentation.
  String? _quickSavedListId;

  @override
  void initState() {
    super.initState();
    _isShort = widget.compact;
    final pending = widget.pendingQuickSave;
    if (pending != null) _resolveQuickSave(pending);
    widget.extentController?.addListener(_onExtentChanged);
    // Listen to tip changes to enable save button
    _tipController.addListener(_onTipChanged);
    // Rebuild when the note input's focus changes — drives the sticky
    // footer's conditional keyboard-avoidance padding.
    _noteFocusNode.addListener(_onNoteFocusChanged);
    // Search + infinite-scroll listeners
    _searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
    // Pre-select lists that already contain this item
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeListSelection();
    });
  }

  /// Adopt the quicksave's answer once it lands, under the already-open sheet.
  ///
  /// Three outcomes, three behaviours. A success just records the list id. A
  /// rate-limit or a rejection (street / closed / non-business) means the save
  /// did NOT happen and the bookmark has already reverted — so report it and
  /// close, rather than leave a nudge open for a save that isn't there. A
  /// generic failure keeps the sheet up: a manual add from here is the retry.
  ///
  /// ⚠️ The close is a visible flinch — the sheet opens and goes again. That is
  /// the accepted cost of opening on the tap: rejection cannot be predicted
  /// before the round-trip, and the alternative is every ordinary save waiting
  /// out the POST behind a blank screen.
  Future<void> _resolveQuickSave(Future<QuickSaveResult> pending) async {
    final result = await pending;
    if (!mounted) return;
    if (result case QuickSaveSuccess(:final listId)) {
      setState(() => _quickSavedListId = listId);
      return;
    }
    final message = _quickSaveFailureMessage(Lt.of(context), result);
    if (message != null) {
      showSoko(ref, message: message, variant: SokoVariant.error);
    }
    // A rate-limit or a rejection means the item is NOT saved and the bookmark
    // has reverted, so the nudge would be offering something untrue. A generic
    // failure keeps the sheet up — a manual add from here is the retry.
    if (result is QuickSaveRateLimited || result is QuickSaveRejected) {
      Navigator.of(context).pop();
    }
  }

  /// Initialize list selection. Runs two fetches in parallel:
  ///
  /// - [loadLists] — refreshes `listsProvider.state.lists` to page 1 of the
  ///   user's 50 most-recently-updated lists (replaces any stale 10-item
  ///   preview that the Lists Hub's discover endpoint may have left in state).
  /// - [_loadPreSelectedLists] — asks the backend "which of my lists contain
  ///   this item?" via `listMyLists(contains_*=X)` (PROD-1435), and uses the
  ///   response to authoritatively pre-check the checkboxes. Falls back to
  ///   the local-cache best-effort path via [_processNewLists] if it fails
  ///   (e.g. backend not yet shipped, offline, etc.).
  Future<void> _initializeListSelection() async {
    // PROD-3873 — the coupled auto lists (Saved Items + the matching typed
    // list) are system-managed, so they miss the fast cached-lists path and
    // would otherwise pop in only when the `contains_*` lookup returns, a beat
    // behind the curated zines. Since a saved item is ALWAYS in them (the
    // server fan-out guarantees it), surface them optimistically from cache the
    // moment the drawer opens; `_loadPreSelectedLists` refines this when it
    // lands (it only adds, never clears, so there's no flicker).
    if (_armAutoListsOptimistically()) setState(() {});

    // Kick off both fetches in parallel, then await separately so the types
    // stay clean (loadLists is Future<void>, _loadPreSelectedLists is
    // Future<Set<String>?>; Future.wait on mixed types is awkward).
    final preSelectedFuture = _loadPreSelectedLists();
    final loadListsFuture = ref.read(listsProvider.notifier).loadLists();
    final authoritativeIds = await preSelectedFuture;
    await loadListsFuture;
    if (!mounted) return;
    // Re-arm after loadLists refreshes state.lists (in case it was cold on open).
    _armAutoListsOptimistically();

    // [_loadPreSelectedLists] returns the authoritative IDs when it succeeds,
    // or null when it fails/isn't applicable. When null, fall back to the
    // best-effort check against the local item cache so the pre-PROD-1435
    // behavior is preserved.
    _preSelectionIsAuthoritative = authoritativeIds != null;

    final updatedState = ref.read(listsProvider);
    if (!_preSelectionIsAuthoritative) {
      _processNewLists(updatedState.lists);
    }

    // If no lists selected (new item), pre-select default list but don't add
    // to initial (so it counts as a change). Skip system-managed defaults
    // (e.g. `saved_items`) — system lists are removal-only from this sheet,
    // so quietly arming a stage-add on them would surprise the user when
    // they press Save.
    final def = updatedState.defaultList;
    _staging.maybeSelectDefault(
      def?.id,
      isSystemManaged: def?.isSystemManaged ?? true,
    );

    setState(() {});
  }

  /// Fetch the set of lists already containing this item via the
  /// `contains_venue_id` / `contains_event_id` / `contains_google_place_id`
  /// filter on `listMyLists` (PROD-1435). Populates [_staging.initial],
  /// [_staging.selected], and [_processedListIds] so every matching list is
  /// pre-checked regardless of pagination.
  ///
  /// Only one identity is sent per call (priority: eventId → venueId →
  /// googlePlaceId, matching [IListsApi.isInList]) — the backend ANDs
  /// multiple filters, which isn't the semantic we want here. Event-first
  /// matters because Instagram-ingested events carry both an event_id and
  /// a venue_id, but the lists hold the event, not the venue separately —
  /// querying by venue_id would return zero matches and silently leave
  /// the lists unchecked.
  ///
  /// Returns the set of authoritatively pre-selected list IDs on success,
  /// or null on failure (backend not yet shipped, offline, item has no
  /// identity, etc.) so the caller can fall back to best-effort.
  Future<Set<String>?> _loadPreSelectedLists() async {
    final venueId = widget.place.venueId;
    final eventId = widget.place.eventId;
    final googlePlaceId = widget.place.googlePlaceId;
    if (venueId == null && eventId == null && googlePlaceId == null) {
      return null;
    }
    try {
      final response = await ref
          .read(listsApiProvider)
          .listMyLists(
            containsEventId: eventId,
            containsVenueId: eventId != null ? null : venueId,
            containsGooglePlaceId: (eventId != null || venueId != null)
                ? null
                : googlePlaceId,
            limit: 100,
          );
      final ids = <String>{};
      for (final list in response.items) {
        ids.add(list.id);
        _staging.applyKnownMembership(list.id);
        _processedListIds.add(list.id);
      }
      // Keep the full UserList objects so _buildListContent can render them
      // at the top in browse mode (matches the sheet's new UX: "where is this
      // already saved?" above "where else could I save it?").
      _preSelectedLists = response.items;
      return ids;
    } catch (e) {
      debugPrint('[AddToListSheet] _loadPreSelectedLists failed: $e');
      return null;
    }
  }

  /// PROD-3873 — when the item is already saved, optimistically pre-select the
  /// coupled auto-managed lists (Saved Items + the matching typed list) from the
  /// in-memory lists cache so they render immediately instead of lagging behind
  /// the `contains_*` network lookup. Returns true if it added anything.
  bool _armAutoListsOptimistically() {
    final isSaved = ref.read(isItemSavedProvider)(
      eventId: widget.place.eventId,
      venueId: widget.place.venueId,
      googlePlaceId: widget.place.googlePlaceId,
    );
    if (!isSaved) return false;
    final isEvent =
        widget.place.type == 'event' || widget.place.eventId != null;
    final autoLists = ref
        .read(listsProvider)
        .lists
        .where(
          (l) =>
              l.isSavedItems || (isEvent ? l.isSavedEvents : l.isSavedPlaces),
        );
    var added = false;
    for (final l in autoLists) {
      if (_preSelectedLists.every((x) => x.id != l.id)) {
        _preSelectedLists.add(l);
        added = true;
      }
      if (_staging.applyKnownMembership(l.id)) added = true;
      _processedListIds.add(l.id);
    }
    return added;
  }

  /// Pre-selects any lists (from [lists]) that the local item cache says
  /// contain the current item. Tracks [_processedListIds] so each list is
  /// only evaluated once — a manual uncheck by the user won't be overwritten
  /// on re-evaluation. Does NOT call setState; callers decide.
  void _processNewLists(Iterable<UserList> lists) {
    final api = ref.read(listsApiProvider);
    for (final list in lists) {
      if (_processedListIds.contains(list.id)) continue;
      _processedListIds.add(list.id);
      final isInList = api.isInList(
        list.id,
        eventId: widget.place.eventId,
        venueId: widget.place.venueId,
        googlePlaceId: widget.place.googlePlaceId,
      );
      if (isInList) {
        _staging.applyKnownMembership(list.id);
      }
    }
  }

  /// Infinite-scroll trigger: in browse mode (no active search), when the
  /// user is within 200px of the bottom AND there are more pages AND no
  /// fetch is already in flight, load the next page and pre-select any new
  /// rows that the local cache knows about.
  void _onScroll() {
    if (_searchController.text.isNotEmpty) return;
    if (_isLoadingMore) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels < pos.maxScrollExtent - 200) return;

    final listsState = ref.read(listsProvider);
    if (!listsState.hasMoreOwned || listsState.isLoading) return;

    setState(() => _isLoadingMore = true);
    ref.read(listsProvider.notifier).loadLists(loadMore: true).whenComplete(() {
      if (!mounted) return;
      // When pre-selection was resolved authoritatively via the
      // `contains_*` call, newly-paginated lists are known-not-containing
      // (they weren't in the authoritative set) — skip the local-cache
      // fallback to avoid stale-positive matches.
      if (!_preSelectionIsAuthoritative) {
        _processNewLists(ref.read(listsProvider).lists);
      }
      setState(() => _isLoadingMore = false);
    });
  }

  /// Debounced search trigger. Fires [_performSearch] 400ms after the last
  /// keystroke; clears results immediately when the field is emptied.
  void _onSearchChanged() {
    final query = _searchController.text.trim();
    if (query == _lastSearchQuery) return;
    _lastSearchQuery = query;
    _debounceTimer?.cancel();
    // Bump generation on every text change so any in-flight _performSearch
    // discards its response when it returns.
    ++_searchGeneration;
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }
    _debounceTimer = Timer(const Duration(milliseconds: 400), _performSearch);
  }

  /// Server-side search via the existing `q=` param on `listMyLists`. Calls
  /// the API directly (not through [listsProvider]) to avoid clobbering the
  /// shared global `state.lists` that other screens depend on. Uses
  /// [_searchGeneration] to discard stale responses when the user has since
  /// cleared or retyped the query.
  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    final generation = ++_searchGeneration;
    setState(() => _isSearching = true);
    try {
      final response = await ref
          .read(listsApiProvider)
          .listMyLists(q: query, limit: 50);
      if (!mounted || generation != _searchGeneration) return;
      _searchResults = response.items;
      if (!_preSelectionIsAuthoritative) {
        _processNewLists(response.items);
      }
      setState(() => _isSearching = false);
    } catch (e) {
      debugPrint('[AddToListSheet] Search failed: $e');
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _isSearching = false);
    }
  }

  @override
  void dispose() {
    widget.extentController?.removeListener(_onExtentChanged);
    _tipController.removeListener(_onTipChanged);
    _tipController.dispose();
    _noteFocusNode.removeListener(_onNoteFocusChanged);
    _noteFocusNode.dispose();
    _debounceTimer?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _scrollController.removeListener(_onScroll);
    // Only dispose the controller we own — the external drag controller belongs
    // to the DraggableScrollableSheet (PROD-3873).
    _ownScrollController.dispose();
    super.dispose();
  }

  void _onNoteFocusChanged() {
    // Trigger a rebuild so `_StickyFooter` re-evaluates whether to apply the
    // keyboard inset. Cheap — only fires on focus enter/exit.
    setState(() {});
  }

  void _onTipChanged() {
    // Trigger rebuild to update save button state
    setState(() {});
  }

  /// Per-row chip toggle. Local-only — stages selection in `_staging.selected`;
  /// the actual add/remove API calls are batched and fired from
  /// `_persistNoteAndClose` when the user presses Save.
  ///
  /// System-managed lists (`saved_items`, `from_instagram_share`,
  /// `from_onboarding`, `weekly_bundle`) are removal-only from this sheet: if
  /// the item isn't already in the system list, tapping the row is a no-op.
  /// If it is, tapping unticks (stages a removal).
  void _onExtentChanged() {
    final controller = widget.extentController;
    if (controller == null || !controller.isAttached) return;
    final short = controller.size < _shortExtentCutoff;
    if (short != _isShort && mounted) setState(() => _isShort = short);
  }

  void _togglePerRow(UserList list) {
    // The footer used to be hidden at the short detent, so staging a change
    // grew the sheet to make room for it. It is now always visible there (the
    // Confirm button is what tells the user the save already happened), so
    // ticking a row no longer moves the sheet under their finger.
    final isSelected = _staging.selected.contains(list.id);
    // System lists can't be manually ADDED (they're auto-managed), but a saved
    // one can be un-ticked (removal) and re-ticked (undo). Block only a genuine
    // add of a system list the item was never in.
    if (list.isSystemManaged &&
        !isSelected &&
        !_staging.initial.contains(list.id)) {
      return;
    }
    // #2521 — only the AUTO-FILED save lists (Saved Items / My Places /
    // My Events) cascade together: deselecting any one of them removes the
    // entity from every owned list, so the preview unticks the whole owned
    // group (and re-ticking restores it). A zine no longer cascades on removal,
    // so it toggles alone. Lists the item isn't in yet (genuine adds) stay
    // independent too.
    final coupledGroup = _preSelectedLists
        .where((l) => l.isOwner || l.isSavedCollection)
        .map((l) => l.id)
        .toSet();
    final group = listRemovalCascades(list) ? coupledGroup : {list.id};
    setState(() {
      _staging.toggleGroup(wasSelected: isSelected, group: group);
    });
  }

  /// "Clear all" link on the "Already saved in" header — empties
  /// `_staging.selected` in one tap. Any pre-existing memberships are now
  /// staged for removal; the actual API calls fire from
  /// `_persistNoteAndClose` when the user presses Save.
  void _clearAllSelections() {
    if (_staging.selected.isEmpty) return;
    setState(_staging.clearAll);
  }

  /// The lists a typed tip should be written to. Empty when there is no tip, or
  /// when the commit is about to unsave the item entirely.
  ///
  /// Ticked some zines? The note was written while filing into those, so it is
  /// theirs — the backend agrees and refuses to fan a tip out beyond the list
  /// it was written on.
  ///
  /// Ticked nothing? The note is about the save itself, so it goes to the whole
  /// auto-filed save group — `saved_items` AND the typed list (`saved_places` /
  /// `saved_events`). Those are not three curations; they are one save shown
  /// three ways, which is why #2521 already unsaves them as a unit. Writing
  /// only to `saved_items` left the tip missing from "My Events" / "My Places",
  /// which is where the user actually browses.
  List<String> _tipTargets({
    required String tip,
    required List<String> added,
    required List<String> removed,
  }) {
    if (tip.isEmpty) return const [];
    if (added.isNotEmpty) return added;

    final group = _preSelectedLists
        .where((l) => l.isSavedCollection)
        .map((l) => l.id)
        .toList();
    // Deselecting any auto save list cascades the item out of every owned list
    // (#2521) — no surviving row to annotate.
    if (group.any(removed.contains)) return const [];
    if (group.isNotEmpty) return group;

    // `contains_*` hasn't landed yet: fall back to the list the quicksave just
    // reported. Current backends return the typed membership; older backends
    // return the Saved Items ledger, so its typed mirror may miss the tip.
    final quickSaved = _quickSavedListId;
    if (quickSaved == null || removed.contains(quickSaved)) return const [];
    return [quickSaved];
  }

  /// Footer "Guardar" action. Per-row chips stage selection locally; this is
  /// where we actually commit the diff against `_staging.initial` to the
  /// notifier APIs and surface the single consolidated success snackbar.
  ///
  /// No-op when nothing changed — closes the sheet without a snackbar. Adds
  /// and removes run in parallel; failures fall back to a single error
  /// message (the user reopens the sheet to retry, matching prior behaviour
  /// when a single-row commit failed).
  Future<void> _persistNoteAndClose() async {
    // PROD-2138: guard against double-tap. The Save button is also disabled
    // when `_isSaving` is true (see _StickyFooter), but the guard catches
    // any path that bypasses the disabled state (programmatic call, etc.).
    if (_isSaving) return;

    // The quicksave may still be in the air: this sheet opens on the tap and no
    // longer waits for it. Its list id is the tip's fallback target, so settle
    // it BEFORE computing where the tip goes — a Save fast enough to beat the
    // POST would otherwise drop the tip silently.
    if (_quickSavedListId == null && widget.pendingQuickSave != null) {
      await widget.pendingQuickSave;
      if (!mounted) return;
    }

    final added = _staging.addedIds;
    final removed = _staging.removedIds;

    final navigator = Navigator.of(context);
    final l10n = Lt.of(context);
    final notifier = ref.read(listsProvider.notifier);
    final tip = _tipController.text.trim();

    // Where a typed tip goes — see [_tipTargets] for the rule. Identical on
    // both presentations: the short post-quicksave sheet and the full manage
    // sheet run the same code.
    final tipTargets = _tipTargets(tip: tip, added: added, removed: removed);

    // Adds and tip-writes are the SAME request. `POST /lists/{id}/items` is
    // idempotent on an item already in the list AND upserts the tip while it's
    // there, so a tip needs no separate PATCH and no membership-row id — which
    // the full sheet has no way to obtain (`contains_*` returns lists, not
    // rows). That is what lets one code path serve both sheets.
    final writes = <String>{...added, ...tipTargets}.toList();

    if (writes.isEmpty && removed.isEmpty) {
      navigator.pop(const AddToListResult(success: true));
      return;
    }

    // PROD-3873 — cascade-unsave disclosure. For the OWNER, removing the item
    // from any of their lists removes it from EVERY list they hold it in. The
    // backend does this unconditionally, so we must warn before the DELETE and
    // name the lists that will lose it. `_preSelectedLists` is the `contains_*`
    // blast radius; a collaborator's own-item removal (non-owned lists) stays a
    // single-row removal with no confirmation.
    // Owned lists in the entity's blast radius. The auto-managed saved lists
    // are always the user's own even when the API leaves `user_role` null, so
    // treat them as owned too (PROD-3873) — this drives both the cascade signal
    // and the post-removal view invalidation.
    final ownedAffected = _preSelectedLists
        .where((l) => l.isOwner || l.isSavedCollection)
        .toList();
    // #2521 — decide the cascade + which curated zines to disclose in one pure
    // step. Cascade fires only when an auto-filed save list is deselected;
    // zines to confirm are non-empty only when that cascade also clears them.
    final decision = unsaveConfirmDecision(
      containingLists: _preSelectedLists,
      removedListIds: removed,
    );
    final cascades = decision.cascades;
    // Confirm only when the cascade will ALSO clear the user's curated zines.
    // Deselecting a zine (no cascade) or an item only in the auto save lists
    // (no zine to warn about) unsaves silently.
    if (decision.zineNamesToConfirm.isNotEmpty) {
      final confirmed = await showCascadeUnsaveConfirmDialog(
        context,
        listNames: decision.zineNamesToConfirm,
      );
      if (!mounted) return;
      if (!confirmed) {
        // Cancelled — undo the un-ticks so the UI keeps showing them saved,
        // and abort the commit (the user can retry).
        setState(() => _staging.selected.addAll(removed));
        return;
      }
    }

    // Flip into the saving state — disables Save + locks the sheet body.
    setState(() => _isSaving = true);

    bool anyFailed = false;
    final futures = <Future<void>>[];

    String? blockedMessage;
    String? saveRejectedCode;
    if (writes.isNotEmpty) {
      final c = Completer<void>();
      notifier.addToListsOptimistic(
        writes,
        widget.place,
        tip: tip.isNotEmpty ? tip : null,
        source: widget.source,
        eventOccurrenceId: widget.eventOccurrenceId,
        saveFlowId: widget.saveFlowId,
        onSuccess: () {
          if (!c.isCompleted) c.complete();
        },
        onError: (errorMessage, _, __) {
          anyFailed = true;
          // PROD-2264 — surface the wordlist-filter copy when the tip
          // was rejected. [ListsNotifier._extractErrorMessage] tags
          // those with [ListsNotifier.contentBlockedPrefix] so the
          // sheet can render the backend message inline.
          if (errorMessage.startsWith(ListsNotifier.contentBlockedPrefix)) {
            blockedMessage = errorMessage.substring(
              ListsNotifier.contentBlockedPrefix.length,
            );
          } else if (errorMessage.startsWith(
            ListsNotifier.saveRejectedPrefix,
          )) {
            // The place itself can't be saved (a street/area or closed
            // venue). The sentinel carries the backend error_code; map it
            // to localized copy below.
            saveRejectedCode = errorMessage.substring(
              ListsNotifier.saveRejectedPrefix.length,
            );
          }
          if (!c.isCompleted) c.complete();
        },
      );
      futures.add(c.future);
    }
    if (removed.isNotEmpty) {
      futures.add(
        // #2521 — cascade only when an auto save list was deselected; the
        // backend then drops the entity from every owned list, so we skip the
        // sibling DELETEs and reconcile the coupled views. A zine-only removal
        // (cascades == false) DELETEs just that row and leaves the save intact.
        notifier.removeFromLists(removed, widget.place, cascade: cascades).then(
          (ok) {
            if (!ok) anyFailed = true;
          },
        ),
      );
    }

    await Future.wait(futures);

    // Refresh any list-detail providers that are currently mounted so they
    // reflect the new membership without waiting for the next visit. Keyed on
    // `writes`, not `added`: a tip-only write changes no membership but does
    // change what a mounted list view should render.
    for (final id in writes) {
      _refreshAffectedList(id);
    }
    // PROD-3873 — a removal cascades: the item left every owned list, not just
    // the one(s) un-ticked, and the `204` carried no body. Re-read the server's
    // saved-state truth (so bookmarks elsewhere clear) and refresh every
    // affected list's open view by BOTH id and slug (the family-key gotcha).
    if (removed.isNotEmpty) {
      // ignore: discarded_futures
      ref.read(listsProvider.notifier).loadAllOwnedItems(force: true);
      final affected = ownedAffected.isNotEmpty
          ? ownedAffected
          : _preSelectedLists;
      for (final list in affected) {
        for (final key in {
          list.id,
          if (list.slug != null && list.slug!.isNotEmpty) list.slug!,
        }) {
          _refreshAffectedList(key);
        }
      }
    }

    if (!mounted) return;
    if (anyFailed) {
      // PROD-2138: clear the saving lock so the user can retry. The toast
      // tells them what went wrong; leaving the sheet open + Save re-enabled
      // matches the prior contract (the original "reopens the sheet to
      // retry" docstring above).
      setState(() => _isSaving = false);
      // PROD-2264 — when the failure was the wordlist filter (CONTENT_BLOCKED
      // on the tip), prefer the backend's already-localized message and
      // fire `content_blocked` analytics. Fall back to the generic
      // [addToListError] toast for any other failure.
      if (blockedMessage != null) {
        final message = blockedMessage!.isNotEmpty
            ? blockedMessage!
            : l10n.moderationContentBlockedFallback;
        ref
            .read(unifiedAnalyticsProvider)
            .trackContentBlocked(
              field: ContentBlockedField.listItemTip.analyticsValue,
            );
        showSoko(ref, message: message, variant: SokoVariant.error);
      } else if (saveRejectedCode != null) {
        // The place couldn't be saved (a street/area or a closed venue) —
        // show the specific, localized reason instead of a generic failure.
        showSoko(
          ref,
          message: _localizedSaveRejection(l10n, saveRejectedCode!),
          variant: SokoVariant.error,
        );
      } else {
        showSoko(ref, message: l10n.addToListError, variant: SokoVariant.error);
      }
      return;
    }
    showSoko(
      ref,
      message: _summaryMessage(l10n, added.length, removed.length),
      variant: SokoVariant.success,
    );
    // No need to clear _isSaving — the sheet is about to unmount.
    navigator.pop(
      AddToListResult(
        success: true,
        addedListIds: added,
        removedListIds: removed,
      ),
    );
  }

  String _summaryMessage(Lt l10n, int addedN, int removedN) {
    // Nothing moved between lists, so the only thing that happened is the note
    // — this branch is only reachable when a tip was written (the caller
    // returns early when there is nothing at all to commit). Saying "removed
    // from 0 lists" was the old fall-through.
    if (addedN == 0 && removedN == 0) return l10n.addToListTipSaved;
    if (addedN > 0 && removedN > 0) return l10n.addToListUpdateSuccess;
    if (addedN > 0) {
      return addedN == 1
          ? l10n.addToListSuccess(addedN)
          : l10n.addToListSuccessPlural(addedN);
    }
    return removedN == 1
        ? l10n.addToListRemoveSuccess(removedN)
        : l10n.addToListRemoveSuccessPlural(removedN);
  }

  // Batch-save flow retired in PROD-1861 — per-row toggle in `_togglePerRow`
  // now commits each list change immediately via the optimistic notifier
  // APIs. Old _handleSave / _buildSaveSection / _getErrorMessage /
  // _getButtonText lived here; they're preserved in git history if a
  // retry/rollback surface needs to come back.

  /// Force the affected list's [unifiedListProvider] to reload its items so
  /// the detail screen (if currently mounted) shows the new event right
  /// after a successful per-row toggle. The lists hub picks up the new
  /// `previewImages` via the `loadLists()` that the notifier already fires
  /// — this just covers the items list on the detail surface.
  ///
  /// `ref.exists` keeps this cheap when the user is not on that list's
  /// detail screen: we skip building the provider just to call refresh on
  /// something nobody is watching.
  void _refreshAffectedList(String listId) {
    final provider = unifiedListProvider(listId);
    if (!ref.exists(provider)) return;
    ref.read(provider.notifier).refresh();
  }

  // PROD-1919: dismiss the sheet and route to the canonical CreateZineScreen
  // for new-list creation. The originating item is auto-saved into the new
  // list via `addToListsOptimistic` inside `onListCreated`, mirroring the
  // per-row toggle shape in `_togglePerRow` (so the user doesn't have to
  // come back to the sheet and tick the row themselves).
  void _openCreateZineFlow() {
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    // Capture the notifier BEFORE popping the sheet. Once `navigator.pop`
    // runs, this state is disposed and `ref.read(...)` would throw — that
    // exception bubbles into CreateZineScreen's submit-handler catch and
    // surfaces as "couldn't create list" even though the list was created.
    // The notifier itself lives in the ProviderScope, so the reference is
    // stable across the sheet teardown.
    final listsNotifier = ref.read(listsProvider.notifier);
    final tip = _tipController.text.trim();
    final place = widget.place;
    final source = widget.source;

    // Pop with the current diff — keeps `AddToListResult` intact for the
    // sheet's callers. The new list's id isn't known yet; the optimistic
    // notifier inside `onListCreated` will update `listsProvider` directly.
    navigator.pop(
      AddToListResult(
        success: true,
        addedListIds: _staging.addedIds,
        removedListIds: _staging.removedIds,
      ),
    );

    router.push(
      AppRoutes.discoveryListCreate,
      extra: CreateZineRouteExtra(
        source: source,
        // showSuccessState defaults to false → CreateZineScreen pops itself
        // and pushes the new list's detail page, so the user lands on the
        // list with the item already saved.
        onListCreated: (list) async {
          listsNotifier.addToListsOptimistic(
            [list.id],
            place,
            tip: tip.isNotEmpty ? tip : null,
            source: source,
            // Same sheet session, so the save into the just-created zine stays
            // on this flow (PROD-4553).
            saveFlowId: widget.saveFlowId,
            onSuccess: () {},
            onError: (_, __, ___) {},
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final listsState = ref.watch(listsProvider);
    final isSaved = _staging.selected.isNotEmpty;

    // PROD-2138: while a save is in flight, lock the sheet:
    //  - PopScope blocks system-back and scrim-tap dismissal
    //  - IgnorePointer drops row/search/note interactions
    //  - AnimatedOpacity dims the body to ~50% so the lock is visible
    // Save button is also disabled (handled inside _StickyFooter).
    // PROD-3983 — the handle only resizes the sheet on the draggable (post-
    // quicksave) presentation; the standard full-height sheet has no extent to
    // drive and keeps the modal route's plain dismissal drag.
    final extentController = widget.extentController;
    Widget header = _PinkItemHeader(
      place: widget.place,
      isSaved: isSaved,
      createLabel: l10n.addToListCreateNewShort,
      onCreate: _openCreateZineFlow,
      // PROD-3983 — at the short detent the sheet shows nothing but the
      // zines: the banner collapses to a bare drag handle and the search
      // row folds away. Both come back on the way up.
      collapsed: widget.compact && _isShort,
    );
    if (extentController != null) {
      header = _ExtentDragArea(controller: extentController, child: header);
    }

    return PopScope(
      canPop: !_isSaving,
      child: DSSheetShell(
        // Drag handle lives INSIDE the pink header so the bar at the top of the
        // sheet is fully pink (Figma `6353:32028`).
        showDragHandle: false,
        header: header,
        body: IgnorePointer(
          ignoring: _isSaving,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: _isSaving ? 0.5 : 1.0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: (widget.compact && _isShort)
                      ? const SizedBox(width: double.infinity, height: 8)
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(height: 12),
                            _SearchRow(
                              controller: _searchController,
                              hint: l10n.addToListSearchPlaceholder,
                              createLabel: l10n.addToListCreateNewShort,
                              onCreate: _openCreateZineFlow,
                            ),
                            const SizedBox(height: 10),
                          ],
                        ),
                ),
                Expanded(
                  child: _buildListContent(l10n: l10n, listsState: listsState),
                ),
              ],
            ),
          ),
        ),
        // The footer is pinned at every detent, including the short one. It
        // costs ~70 px of zine rows, and buys the two things the short sheet
        // was missing: a Confirm button that reads as "you are done, nothing
        // more is being asked of you", and the tip field next to it.
        footer: _StickyFooter(
          noteController: _tipController,
          noteFocusNode: _noteFocusNode,
          noteHint: l10n.addToListTipLabel,
          saveLabel: l10n.addToListSaveAction,
          onSave: _persistNoteAndClose,
          isSaving: _isSaving,
        ),
      ),
    );
  }

  /// Build the list area. Handles 4 states:
  /// - `_isSearching` → spinner
  /// - search active + no results → "No lists found" empty state
  /// - search active → render `_searchResults`
  /// - browse (default) → render pre-selected then other lists, attach
  ///   `_scrollController` for infinite scroll. The "Create new list" row is
  ///   no longer part of this list — it sits in the sheet header (PROD-1861).
  Widget _buildListContent({required Lt l10n, required ListsState listsState}) {
    final searchActive = _searchController.text.isNotEmpty;

    if (_isSearching) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (searchActive && _searchResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off_rounded,
                size: 48,
                color: AppColors.sokoShade3.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.addToListSearchNoResults,
                style: const TextStyle(color: AppColors.sokoShade3),
              ),
            ],
          ),
        ),
      );
    }

    if (!searchActive && listsState.isLoading && listsState.lists.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }

    // Pre-selected lists source — see `_loadPreSelectedLists` doc-comment.
    // System-managed lists (saved_items, weekly_bundle, etc.) are filtered
    // out of `otherLists` so the user can't add to them from this sheet —
    // but kept in `preSelected` when the item is already there, so the
    // user can untick to remove.
    final List<UserList> preSelected;
    final List<UserList> otherLists;
    if (searchActive) {
      preSelected = const [];
      otherLists = _searchResults.where((l) => !l.isSystemManaged).toList();
    } else if (_preSelectedLists.isNotEmpty) {
      preSelected = _preSelectedLists;
      final preSelectedIds = preSelected.map((l) => l.id).toSet();
      otherLists = listsState.lists
          .where((l) => !preSelectedIds.contains(l.id) && !l.isSystemManaged)
          .toList();
    } else {
      preSelected = listsState.lists
          .where((l) => _staging.initial.contains(l.id))
          .toList();
      otherLists = listsState.lists
          .where((l) => !_staging.initial.contains(l.id) && !l.isSystemManaged)
          .toList();
    }

    final hasFooterSpinner = !searchActive && _isLoadingMore;
    final footerCount = hasFooterSpinner ? 1 : 0;
    final preSelectedCount = preSelected.length;
    // Two section headers: "Already saved in" above pre-selected lists, and
    // "Save to" above the rest of the user's lists (search results too).
    // Each header renders independently — only when its section is non-empty.
    // PROD-3983 — no section headers at the short detent; the sheet is just
    // the three zines.
    final bare = widget.compact && _isShort;
    final showSavedInHeader = !bare && preSelectedCount > 0;
    final showSaveToHeader = !bare && otherLists.isNotEmpty;
    final headerCount =
        (showSavedInHeader ? 1 : 0) + (showSaveToHeader ? 1 : 0);
    final itemCount =
        headerCount + preSelectedCount + otherLists.length + footerCount;

    return ListView.separated(
      controller: searchActive ? null : _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      itemCount: itemCount,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        var cursor = index;
        if (showSavedInHeader) {
          if (cursor == 0) {
            return _SectionHeader(
              label: l10n.addToListSavedInSection,
              trailing: _staging.selected.isNotEmpty
                  ? _ClearAllLink(
                      label: l10n.addToListClearAll,
                      onTap: _clearAllSelections,
                    )
                  : null,
            );
          }
          cursor -= 1;
        }
        if (cursor < preSelectedCount) {
          return _buildListRow(preSelected[cursor], l10n);
        }
        cursor -= preSelectedCount;
        if (showSaveToHeader) {
          if (cursor == 0) {
            return _SectionHeader(label: l10n.addToListSaveToSection);
          }
          cursor -= 1;
        }
        if (cursor < otherLists.length) {
          return _buildListRow(otherLists[cursor], l10n);
        }
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      },
    );
  }

  /// PROD-1861 list row: 60 px tall, 45 px stacked-thumbnail tile on the
  /// left, name + item-count in Soko tokens, + / ✓ chip on the right.
  /// Default state: dashed `sokoInk @ 30 %` border, transparent background.
  /// Selected state: solid `sokoPink` border, soft `sokoLight3` background.
  Widget _buildListRow(UserList list, Lt l10n) {
    final isSelected = _staging.selected.contains(list.id);
    final rowContent = Material(
      color: isSelected ? AppColors.sokoLight3 : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _togglePerRow(list),
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              ListThumbnailStack(
                previewImages: list.previewImages,
                coverImageUrl: list.coverImageUrl,
                coverRecipe: ZineCoverRecipe.fromUserList(list),
                title: list.name,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      list.name,
                      style: const TextStyle(
                        fontFamily: 'Zalando Sans',
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        height: 1.0,
                        letterSpacing: -0.36,
                        color: AppColors.sokoInk,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.listsItemCount(list.itemCount),
                      style: const TextStyle(
                        fontFamily: 'Zalando Sans',
                        fontSize: 14,
                        fontWeight: FontWeight.w300,
                        height: 1.2,
                        letterSpacing: -0.14,
                        color: AppColors.sokoShade4,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: _RowChip(isSelected: isSelected),
              ),
            ],
          ),
        ),
      ),
    );

    // Selected → solid pink frame painted as a normal Border on top of the
    // pink-tinted Material. Unselected → dashed ink-30% frame via
    // `DashedBorderPainter`.
    if (isSelected) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.sokoPink, width: 1),
        ),
        child: rowContent,
      );
    }
    return CustomPaint(
      painter: DashedBorderPainter(
        color: AppColors.sokoInk.withValues(alpha: 0.30),
      ),
      child: rowContent,
    );
  }
}

/// Show the add to list sheet.
///
/// Guests are intercepted at this chokepoint (PROD-1979): if the user is
/// not authenticated, the login prompt sheet is shown instead and the
/// add-to-list sheet never opens. Callers don't need their own gate —
/// they only need to pass a [referrer] when the default `guestSaveList`
/// origin is too generic for the auth funnel (e.g. chat, map).
///
/// If [ref] is provided, the bottom navigation will be hidden while the sheet
/// is open. [source] tracks where the action originated from (use
/// [ListSource] constants).
/// The user-facing reason a quicksave did not land, or null on success.
///
/// One rule, two readers: the no-sheet path toasts it and stops; the open sheet
/// toasts it and then decides whether to close. Splitting the copy across the
/// two lets them drift, and a wrong reason is worse than no reason.
String? _quickSaveFailureMessage(Lt l10n, QuickSaveResult result) =>
    switch (result) {
      QuickSaveSuccess() => null,
      // Shared 30/min bucket with the explicit add route — say "slow down".
      QuickSaveRateLimited() => l10n.quickSaveRateLimited,
      // Street / closed / non-business — the specific reason (#1328).
      QuickSaveRejected(:final errorCode) => _localizedSaveRejection(
        l10n,
        errorCode,
      ),
      QuickSaveFailed() => l10n.addToListError,
    };

/// Toast a quicksave that did not land. No-op on success.
///
/// Only for the no-sheet path (cards, chat, map). When a sheet is open it owns
/// the reporting — it can also close itself, which this cannot.
void _reportQuickSaveFailure(
  BuildContext context,
  WidgetRef ref,
  QuickSaveResult result,
) {
  final message = _quickSaveFailureMessage(Lt.of(context), result);
  if (message == null) return;
  showSoko(ref, message: message, variant: SokoVariant.error);
}

Future<AddToListResult?> showAddToListSheet(
  BuildContext context,
  ItemSuggestion place, {
  WidgetRef? ref,
  bool useRootNavigator = true,
  String? source,
  String? referrer,
  String? eventOccurrenceId,
  // PROD-3873 — quicksave-first. When true and the item isn't already saved,
  // file it into Saved Items immediately (server-resolved, no picker) before
  // the sheet opens, so the bookmark fills on tap and the drawer becomes an
  // optional "also file it in a zine" step. Requires [ref].
  bool quickSaveIfUnsaved = false,
  // PROD-3983 — on a fresh quicksave, don't open the drawer at all: the save
  // is done, the bookmark fills and the device buzzes. Set true on
  // card/chat/map bookmarks. Tapping an already-saved bookmark still opens the
  // full drawer, so filing into a zine is one extra tap away, never lost.
  // Leave false on detail, where a fresh save opens the short drawer instead.
  bool skipDrawerWhenSaving = false,
}) async {
  if (ref != null && !ref.read(isAuthenticatedProvider)) {
    final l10n = Lt.of(context);
    await requireAuth(
      context,
      ref,
      action: l10n.guestSaveAction,
      referrer: referrer ?? AuthReferrer.guestSaveList,
      onAuthenticated: () {},
    );
    return null;
  }

  // PROD-4553 — one save-flow id per opening of the sheet. Allocated here, at
  // the user action that starts the flow and BEFORE the quick-save fires, then
  // shared with the quick-save and the drawer commit so an in-flow note joins
  // the insertion. A fresh id per invocation is exactly the "clear it when the
  // flow ends, new one for a later independent action" lifecycle.
  final saveFlowId = const Uuid().v4();

  // Quicksave and sheet run CONCURRENTLY. Which sheet to open depends only on
  // "was this already saved", and that is known before any request leaves — so
  // nothing here waits on the network.
  //
  // This used to `await` the POST before deciding, which cost twice: the drawer
  // appeared a round-trip after the tap, and during that blank gap a second tap
  // read the bookmark the first tap had ALREADY flipped optimistically, took the
  // manage-an-existing-save branch, and opened the full drawer underneath the
  // short one that was still coming.
  var freshSave = false;
  Future<QuickSaveResult>? pendingQuickSave;
  if (ref != null && quickSaveIfUnsaved) {
    final wasSaved = ref.read(isItemSavedProvider)(
      eventId: place.eventId,
      venueId: place.venueId,
      googlePlaceId: place.googlePlaceId,
    );
    if (!wasSaved) {
      // PROD-3983 — buzz on the TAP, not on the response. Optimistic: a save
      // that then fails still buzzed, but every failure path raises its own
      // error toast, and the alternative is making every save feel slow to
      // protect the rare one.
      //
      // Strength/constant per platform lives in [SokoHaptics.saveConfirm] —
      // tune it there, not here.
      SokoHaptics.saveConfirm();
      // Deliberately NOT awaited. `quickSave` flips the bookmark synchronously
      // before its first await, so the optimistic state the sheet arms its auto
      // lists from is in place by the time the sheet builds — we skip only the
      // waiting, not the ordering. It never throws (every failure comes back as
      // a `QuickSaveResult`), so an unawaited future cannot go unhandled.
      final pending = ref
          .read(listsProvider.notifier)
          .quickSave(
            place,
            eventOccurrenceId: eventOccurrenceId,
            saveFlowId: saveFlowId,
          );
      freshSave = true;
      if (skipDrawerWhenSaving) {
        // Cards, chat, map: saving is the whole interaction and no sheet opens,
        // so this is the only place the result can be reported.
        final result = await pending;
        if (!context.mounted) return null;
        _reportQuickSaveFailure(context, ref, result);
        return null;
      }
      // Detail: the sheet opens now and adopts this when it lands.
      pendingQuickSave = pending;
    }
  }

  // The DSSheetShell wrapping AddToListSheet already caps at 92 % of the
  // viewport — no extra ConstrainedBox needed.
  Widget sheetBuilder(BuildContext context) => AddToListSheet(
    place: place,
    source: source,
    eventOccurrenceId: eventOccurrenceId,
    saveFlowId: saveFlowId,
  );

  final extentController = DraggableScrollableController();

  if (ref != null) {
    if (freshSave) {
      // Detail, fresh save (PROD-3983). A third of the screen, draggable up.
      // The save already happened, so this is an optional "also file it in a
      // zine" nudge, not a modal. The pink item header is dropped — the detail
      // page behind the sheet already shows the item. No scrim: the page stays
      // undimmed, unlike the standard full-height drawers.
      return showDraggableSheetWithHiddenNav<AddToListResult>(
        context: context,
        ref: ref,
        controller: extentController,
        initialChildSize: _kPeekExtent,
        minChildSize: _kMinExtent,
        maxChildSize: _kFullExtent,
        snap: true,
        snapSizes: const [_kPeekExtent, _kFullExtent],
        barrierColor: Colors.transparent,
        // A tap outside must close the sheet. With `expand: true` (the helper's
        // default) the DraggableScrollableSheet mounts a full-height
        // transparent draggable area over the page, so "outside" is still the
        // sheet's own gesture area and the tap never reaches the modal
        // barrier. `false` positions the sheet by its current extent instead,
        // leaving the space above it to the barrier — which `isDismissible`
        // (default true) then closes on.
        expand: false,
        builder: (context, scrollController) => AddToListSheet(
          place: place,
          source: source,
          eventOccurrenceId: eventOccurrenceId,
          externalScrollController: scrollController,
          compact: true,
          extentController: extentController,
          pendingQuickSave: pendingQuickSave,
          saveFlowId: saveFlowId,
        ),
      );
    }
    return showBottomSheetWithHiddenNav<AddToListResult>(
      context: context,
      ref: ref,
      builder: sheetBuilder,
    );
  }

  return showModalBottomSheet<AddToListResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useRootNavigator: useRootNavigator,
    builder: sheetBuilder,
  );
}

// =========================================================================
// PROD-1861 — Private widgets used by the redesigned AddToListSheet.
// =========================================================================

/// Makes the sheet's drag handle actually drag (PROD-3983).
///
/// A [DraggableScrollableSheet] only changes size through the [ScrollController]
/// it hands its builder. That controller drives the zine list inside the sheet
/// body — so scrolling the list resized the sheet, but the handle, which sits in
/// the header above the scrollable, did nothing. Dragging it *down* appeared to
/// work only because `showModalBottomSheet`'s own dismissal drag sits underneath
/// and that gesture runs one direction. Hence: down moved, up didn't.
///
/// This detector drives the extent by hand. Same physics as the map results
/// drawer ([MapResultsSheet]): `jumpTo` while the finger is down (it leaves
/// `hasDragged` false, so the sheet won't auto-snap under us), then an explicit
/// snap on release. Releasing below [_kDismissExtent], or flinging down from the
/// peek, closes the sheet — preserving the dismissal the modal route used to
/// give us for free.
class _ExtentDragArea extends StatelessWidget {
  const _ExtentDragArea({required this.controller, required this.child});

  final DraggableScrollableController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final box = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) {
        if (!controller.isAttached || box <= 0) return;
        final next = (controller.size - d.primaryDelta! / box).clamp(
          _kMinExtent,
          _kFullExtent,
        );
        controller.jumpTo(next);
      },
      onVerticalDragEnd: (d) {
        if (!controller.isAttached || box <= 0) return;
        // Viewport-fractions per second, positive = the sheet growing.
        final velocity = -d.velocity.pixelsPerSecond.dy / box;
        final size = controller.size;

        final double target;
        if (velocity < -_kFlingVelocity) {
          // Flung down: drop one stop, or close if already at the bottom one.
          if (size <= _kPeekExtent + _kExtentEpsilon) {
            Navigator.of(context).maybePop();
            return;
          }
          target = _kPeekExtent;
        } else if (velocity > _kFlingVelocity) {
          target = _kFullExtent;
        } else if (size < _kDismissExtent) {
          Navigator.of(context).maybePop();
          return;
        } else {
          target = (size - _kPeekExtent).abs() <= (_kFullExtent - size).abs()
              ? _kPeekExtent
              : _kFullExtent;
        }
        controller.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      },
      child: child,
    );
  }
}

/// Pink banner that pins the item being saved at the top of the sheet.
/// Per Figma `6353:32028` — Soko/Light 3 background, thumbnail + name +
/// subtitle, read-only bookmark chip on the right that lights pink when the
/// item is in at least one list.
class _PinkItemHeader extends StatelessWidget {
  const _PinkItemHeader({
    required this.place,
    required this.isSaved,
    required this.createLabel,
    required this.onCreate,
    this.collapsed = false,
  });

  final ItemSuggestion place;
  final bool isSaved;
  final String createLabel;
  final VoidCallback onCreate;

  /// Short-sheet variant: the whole pink band folds away and only the drag
  /// handle is left, so the detent is spent on zine rows.
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Material(
      color: collapsed ? AppColors.sokoPaper : AppColors.sokoLight3,
      // PROD-3983 — the compact/full swap happens mid-drag, so tween the
      // height instead of snapping it.
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle on pink — same 40 × 4 bar that DSSheetShell draws by
            // default, just hosted here so the pink covers the whole top of the
            // sheet (Figma `6353:32028`).
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 8),
              child: Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.sokoShade4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            // Collapsed strip: thumbnail + item name on the left, "New zine"
            // floated right. The 44 px pill dictates the height; everything else
            // is as small as it needs to be.
            if (collapsed)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Row(
                  children: [
                    SokoCardImage(
                      imageUrl: place.imageUrl,
                      seed: place.venueId ?? place.eventId ?? place.id,
                      kind: SokoEntityKind.fromTypeString(place.type),
                      width: 32,
                      height: 32,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        place.name,
                        style: const TextStyle(
                          fontFamily: 'Zalando Sans',
                          fontSize: 16,
                          fontWeight: FontWeight.w300,
                          height: 1.2,
                          letterSpacing: -0.32,
                          color: AppColors.sokoInk,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _NewZinePill(label: createLabel, onTap: onCreate),
                  ],
                ),
              ),
            if (!collapsed)
              SizedBox(
                height: 80,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      SokoCardImage(
                        imageUrl: place.imageUrl,
                        seed: place.venueId ?? place.eventId ?? place.id,
                        kind: SokoEntityKind.fromTypeString(place.type),
                        width: 50,
                        height: 63,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.addToListTitle(place.name),
                              style: const TextStyle(
                                fontFamily: 'Zalando Sans',
                                fontSize: 18,
                                fontWeight: FontWeight.w300,
                                height: 1.0,
                                letterSpacing: -0.36,
                                color: AppColors.sokoInk,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (_subtitle != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                _subtitle!,
                                style: const TextStyle(
                                  fontFamily: 'Zalando Sans',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w300,
                                  height: 1.2,
                                  letterSpacing: -0.14,
                                  color: AppColors.sokoShade3,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _BookmarkChip(isSaved: isSaved),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Composes the subtitle line from whichever metadata fields the
  /// `ItemSuggestion` exposes. Returns null when nothing useful is set.
  ///
  /// For events, the venue name (`place.location`) is shown first so the
  /// user can tell where the event happens at a glance.
  String? get _subtitle {
    final isEvent = place.type == 'event';
    final venue = place.location;
    final parts = <String>[
      if (isEvent && venue != null && venue.isNotEmpty) venue,
      if (place.category != null && place.category!.isNotEmpty) place.category!,
      if (place.neighborhood != null && place.neighborhood!.isNotEmpty)
        place.neighborhood!,
    ];
    return parts.isEmpty ? null : parts.join(' • ');
  }
}

/// Section header rendered above a group of list rows inside the sheet's
/// scrollable area. Supports an optional [trailing] widget for inline
/// actions like the "Clear all" link on the "Already saved in" section.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'Zalando Sans',
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.2,
                letterSpacing: -0.14,
                color: AppColors.sokoShade3,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Underlined text link rendered inline on a section header — used today
/// for the "Clear all" affordance next to "Already saved in".
class _ClearAllLink extends StatelessWidget {
  const _ClearAllLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        // PROD-2138 (Diana polish): lead with a trashcan so the link reads
        // clearly as a destructive "remove from every zine" action, not a
        // neutral "clear selection".
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.delete_outline_rounded,
              size: 14,
              color: AppColors.sokoDark,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'Zalando Sans',
                fontSize: 14,
                fontWeight: FontWeight.w400,
                height: 1.2,
                letterSpacing: -0.14,
                // Matches the dark Create-list button at the top of the sheet
                // so the two affordances share the same accent.
                color: AppColors.sokoDark,
                decoration: TextDecoration.underline,
                decorationColor: AppColors.sokoDark,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wrapper over [SokoTextField] that adds the search-specific affordances:
/// magnifier prefix, conditional clear-button suffix bound to `controller`.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.hint});

  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return SokoTextField(
      controller: controller,
      hintText: hint,
      textInputAction: TextInputAction.search,
      prefix: const Icon(
        Icons.search_rounded,
        color: AppColors.sokoShade3,
        size: 18,
      ),
      suffix: controller.text.isNotEmpty
          ? IconButton(
              icon: const Icon(
                Icons.close_rounded,
                color: AppColors.sokoShade3,
                size: 18,
              ),
              onPressed: controller.clear,
              splashRadius: 18,
            )
          : null,
      // Match the tip field (which uses the same vertical:16 to overcome
      // `isDense: true` compaction); keeps both inputs aligned with the
      // Save / Create-list button.
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
    );
  }
}

/// PROD-3983 — search field + a 44 x 44 yellow `+` that routes to
/// `CreateZineScreen`. Previously the create CTA was a full-width row of its
/// own above the search field; folding it onto the same line reclaims ~54 px
/// of vertical space in a sheet that is now presented short.
/// PROD-3983 — yellow "New zine" CTA. Used twice: floated right in the
/// collapsed header strip, and on the search row when the sheet is expanded.
/// A bare `+` beside a search field reads as ambiguous (add? filter?), so it
/// carries a short label and a document-with-plus glyph.
class _NewZinePill extends StatelessWidget {
  const _NewZinePill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SokoCtaButton(
      label: label,
      icon: Icons.post_add_rounded,
      variant: SokoCtaVariant.yellow,
      expand: false,
      onPressed: onTap,
    );
  }
}

class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.controller,
    required this.hint,
    required this.createLabel,
    required this.onCreate,
  });

  final TextEditingController controller;
  final String hint;
  final String createLabel;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: _SearchField(controller: controller, hint: hint),
          ),
          const SizedBox(width: 8),
          _NewZinePill(label: createLabel, onTap: onCreate),
        ],
      ),
    );
  }
}

/// 30 × 30 px chip used on every list row. Renders a `+` when not selected,
/// a `✓` when selected (pink fill matches Figma `Property 1=Selected`).
class _RowChip extends StatelessWidget {
  const _RowChip({required this.isSelected});

  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: isSelected
            ? AppColors.sokoPink
            : AppColors.sokoInk.withValues(alpha: 0.08),
        shape: BoxShape.circle,
      ),
      child: Icon(
        isSelected ? Icons.check_rounded : Icons.add_rounded,
        size: 16,
        color: AppColors.sokoInk,
      ),
    );
  }
}

/// 30 × 30 px bookmark chip in the pink item header — read-only indicator
/// that lights pink (`Soko/Pink`) when the item is in at least one list.
/// Mirrors Figma `6353:32047`.
class _BookmarkChip extends StatelessWidget {
  const _BookmarkChip({required this.isSaved});

  final bool isSaved;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: isSaved
            ? AppColors.sokoPink
            : AppColors.sokoInk.withValues(alpha: 0.08),
        shape: BoxShape.circle,
      ),
      child: Icon(
        isSaved ? Icons.bookmark : Icons.bookmark_border,
        size: 14,
        color: AppColors.sokoInk,
      ),
    );
  }
}

/// Sticky footer pinned to the bottom of the sheet — note input on the left
/// + pink "Guardar" button on the right. Drop-shadow above the bar matches
/// Figma `6353:32072`.
class _StickyFooter extends StatelessWidget {
  const _StickyFooter({
    required this.noteController,
    required this.noteFocusNode,
    required this.noteHint,
    required this.saveLabel,
    required this.onSave,
    this.isSaving = false,
  });

  final TextEditingController noteController;
  final FocusNode noteFocusNode;
  final String noteHint;
  final String saveLabel;
  final VoidCallback onSave;
  // PROD-2138: when true, the Save button shows an inline spinner via
  // `SokoCtaButton.loading` and rejects taps. Sheet body also dims +
  // ignores pointers — see the build method in `_AddToListSheetState`.
  final bool isSaving;

  @override
  Widget build(BuildContext context) {
    // Only lift the footer above the keyboard when the *note* input is the
    // active focus. Tapping the search field at the top opens the keyboard
    // too, but in that case the user is looking at the top of the sheet —
    // sliding the footer up would just steal vertical space.
    final keyboardInset = noteFocusNode.hasFocus
        ? MediaQuery.of(context).viewInsets.bottom
        : 0.0;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Container(
        color: AppColors.sokoPaper,
        // Canonical sticky-footer padding: 12 px top / 14 px bottom,
        // matching share/import/instagram-share sheets.
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Row(
          // Bottom-align so the Save button stays anchored next to the
          // first line of the note as it grows from one to multiple lines.
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: SokoTextField(
                controller: noteController,
                focusNode: noteFocusNode,
                hintText: noteHint,
                textCapitalization: TextCapitalization.sentences,
                // Multi-line note: starts as a single line, grows up to 4
                // before scrolling internally. `null` maxLines pairs with
                // a finite minLines so the field auto-expands.
                minLines: 1,
                maxLines: 4,
                // Enforce the backend `tip` cap (500) so long notes never
                // 422 on save — the field hard-stops at the limit.
                maxLength: kUserListItemTipMaxLength,
                // SokoTextField forces `isDense: true`, which compacts the
                // input height even with custom padding. Vertical 16 (vs
                // the search field's 14) compensates for the absence of a
                // prefix icon, lifting the rendered pill to ~44 px so it
                // matches the Save button and the search field beside it.
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 16,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SokoCtaButton(
              // PROD-2138 (Diana polish): a checkmark, not a bookmark — this
              // commits staged changes (which may be removals or just a tip),
              // so a "save the item" bookmark glyph was misleading.
              label: saveLabel,
              icon: Icons.check_rounded,
              variant: SokoCtaVariant.pink,
              expand: false,
              loading: isSaving,
              onPressed: onSave,
            ),
          ],
        ),
      ),
    );
  }
}
