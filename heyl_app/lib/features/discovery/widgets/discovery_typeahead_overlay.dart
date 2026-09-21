import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/chat_bar.dart';
import '../../../shared/widgets/scallop_divider.dart';
import '../../legal/widgets/ai_disclosure_sheet.dart';
import '../providers/search_category_provider.dart';
import '../providers/search_results_provider.dart';
import 'discovery_shell.dart';
import 'typeahead_filter_chips.dart';
import 'typeahead_result_row.dart';

/// PROD-1983: snapshot of typeahead state captured when the user taps a
/// result card. The card tap pops the overlay and pushes a detail page;
/// when the user back-arrows out of that detail, [_TypeaheadResumer]
/// reads this snapshot and re-opens the typeahead with the same query +
/// filter so the user lands back on the suggestions list they were
/// browsing instead of on Discovery's empty home.
@immutable
class TypeaheadResumeState {
  final String query;
  final TypeaheadFilter filter;

  const TypeaheadResumeState({required this.query, required this.filter});
}

/// PROD-1983: holds the most recent [TypeaheadResumeState] written by
/// [_DiscoveryTypeaheadPageState._handleResultTap]. Consumed and cleared
/// by [typeaheadResumeNavObserver] when the shell navigator pops back
/// to Discovery (i.e. the user back-arrowed out of the pushed detail
/// page).
final lastTypeaheadResumeProvider = StateProvider<TypeaheadResumeState?>(
  (_) => null,
);

/// PROD-1983: shell-navigator observer that re-opens the typeahead
/// overlay synchronously the moment the user pops back to Discovery
/// from a detail page they reached via a typeahead result tap.
///
/// Registered on the same `ShellRoute.observers` list as
/// [discoveryNavObserver] so its `didPop` callback fires during the
/// pop transaction itself — *not* on the post-frame deferral
/// [discoveryNavObserver] uses for change-notifier listeners
/// (`discovery_shell.dart:_setTop`). Pushing the dialog inside the
/// pop callback means the shell-nav pop and the root-nav typeahead
/// push are processed for the same frame, so the user never sees a
/// flash of Discovery between the detail page disappearing and the
/// typeahead reappearing.
///
/// Cache pre-warming (so the resumed overlay shows results
/// instantly, no spinner) is handled separately by [TypeaheadResumer]
/// via [lastTypeaheadResumeProvider].
final typeaheadResumeNavObserver = _TypeaheadResumeNavObserver();

class _TypeaheadResumeNavObserver extends NavigatorObserver {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    final settings = previousRoute?.settings;
    final prevName = settings is Page ? settings.name : null;
    if (prevName != discoveryPageName) return;
    final navContext = navigator?.context;
    if (navContext == null) return;
    final container = ProviderScope.containerOf(navContext, listen: false);
    final resume = container.read(lastTypeaheadResumeProvider);
    if (resume == null) return;
    container.read(lastTypeaheadResumeProvider.notifier).state = null;
    showDiscoveryTypeahead(
      navContext,
      initialQuery: resume.query,
      initialFilter: resume.filter,
      instant: true,
    );
  }
}

/// Debounce window before the typed query is pushed into the results
/// provider. Mirrors `_kSearchDebounce` in `discovery_action_bar.dart` so
/// the two surfaces feel identical.
const Duration _kTypeaheadDebounce = Duration(milliseconds: 600);

/// Open the discovery chat-input typeahead as a top-level overlay
/// (PROD-1909). Uses `showGeneralDialog` instead of a GoRoute so the URL
/// stays clean on web and the overlay bypasses `DiscoveryShell`'s
/// `Scaffold > SingleChildScrollView` (per the no-nested-Scaffold
/// constraint in `linear-learnings/SKILL.md`).
Future<void> showDiscoveryTypeahead(
  BuildContext context, {
  String initialQuery = '',
  TypeaheadFilter initialFilter = TypeaheadFilter.all,
  bool instant = false,
}) {
  return showGeneralDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    // PROD-1983: when [instant] is set the overlay snaps in with no
    // fade and no Hero flight. Used by [TypeaheadResumer] so the user
    // doesn't see a flash of Discovery between popping the detail and
    // the typeahead reappearing.
    transitionDuration: instant
        ? Duration.zero
        : const Duration(milliseconds: 180),
    pageBuilder: (_, __, ___) => _DiscoveryTypeaheadPage(
      initialQuery: initialQuery,
      initialFilter: initialFilter,
    ),
    transitionBuilder: (_, anim, __, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(opacity: curved, child: child);
    },
  );
}

class _DiscoveryTypeaheadPage extends ConsumerStatefulWidget {
  final String initialQuery;
  final TypeaheadFilter initialFilter;
  const _DiscoveryTypeaheadPage({
    required this.initialQuery,
    required this.initialFilter,
  });

  @override
  ConsumerState<_DiscoveryTypeaheadPage> createState() =>
      _DiscoveryTypeaheadPageState();
}

class _DiscoveryTypeaheadPageState
    extends ConsumerState<_DiscoveryTypeaheadPage>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  Timer? _debounceTimer;

  // ---- Drag-to-dismiss (only when no results visible) -----------------
  /// Single controller driving the vertical translation. `value = 0`
  /// means fully visible at the top; `value = 1` means fully off-screen
  /// at the bottom. During a drag we set the value directly; on release
  /// we either animate to 0 (snap back, stay open) or 1 (dismiss, pop).
  /// Only the empty-state (no results visible) accepts drag gestures —
  /// otherwise the list captures the vertical scroll.
  late final AnimationController _slideController;

  /// Debounced query — drives the family-keyed results providers.
  String _debouncedQuery = '';

  /// Live text used for empty-state copy + composer-state ("hasText").
  bool _hasText = false;

  /// Live indicator: query length ≥ [typeaheadShortQueryThreshold].
  /// Updates synchronously on every keystroke (separate from
  /// [_debouncedQuery]) so the composer's send-pill label appears the
  /// moment the user crosses the 4-char boundary, without waiting for
  /// the 600 ms search debounce.
  bool _isLongEnough = false;

  late TypeaheadFilter _filter;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
    _filter = widget.initialFilter;
    final trimmed = _controller.text.trim();
    _hasText = trimmed.isNotEmpty;
    _isLongEnough = trimmed.length >= ApiConstants.typeaheadShortQueryThreshold;
    _debouncedQuery = trimmed;
    _controller.addListener(_onTextChanged);
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 0.0, // start fully visible
    );
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    _slideController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final trimmed = _controller.text.trim();
    final hasText = trimmed.isNotEmpty;
    final isLongEnough =
        trimmed.length >= ApiConstants.typeaheadShortQueryThreshold;
    // Single setState per keystroke so we don't double-rebuild the tree
    // (each setState would otherwise re-enter the composer's reconcile,
    // which is sensitive to focus loss on Flutter web).
    if (hasText != _hasText || isLongEnough != _isLongEnough) {
      setState(() {
        _hasText = hasText;
        _isLongEnough = isLongEnough;
      });
    }
    _debounceTimer?.cancel();
    if (trimmed.isEmpty) {
      // Clear immediately so the empty hint state returns without delay.
      if (_debouncedQuery.isNotEmpty) {
        setState(() => _debouncedQuery = '');
      }
      return;
    }
    _debounceTimer = Timer(_kTypeaheadDebounce, () {
      if (!mounted) return;
      if (_debouncedQuery == trimmed) return;
      setState(() => _debouncedQuery = trimmed);
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      if (_hasText) {
        _handleSend();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    // Capture nav + router BEFORE pop — context becomes invalid after.
    final rootNav = Navigator.of(context, rootNavigator: true);
    final router = GoRouter.of(context);
    rootNav.pop();
    router.go(AppRoutes.chat, extra: {'autoSendMessage': text});
  }

  void _handleResultTap(SearchResultRow row) {
    final String? path = switch (row) {
      EventSearchResultRow(:final event) =>
        (event.eventId ?? event.id).isEmpty
            ? null
            : '/events/${event.eventId ?? event.id}',
      // Places: only navigate when we have a real `venueId` (UUID).
      // Google-fallback rows (`venueId == null`) are filtered out
      // upstream in `_resolveSearchState`, but guard here too in case
      // a future call site routes around the filter.
      PlaceSearchResultRow(:final place) =>
        place.venueId == null || place.venueId!.isEmpty
            ? null
            : '/venues/${place.venueId}',
      ListSearchResultRow(:final list) => '/lists/${list.urlIdentifier}',
    };
    if (path == null) return;
    // Capture router BEFORE pop — context becomes invalid after the
    // overlay disposes. Pop so the detail page renders above the
    // discovery shell instead of below this root-navigator overlay
    // (which is what made the detail invisible in v1).
    final router = GoRouter.of(context);
    final extra = row is ListSearchResultRow ? const {'referrer': '/'} : null;
    // PROD-1983: snapshot query + filter so [TypeaheadResumer] can
    // re-open the typeahead with the same state when the user
    // back-arrows out of the pushed detail page. Set BEFORE the pop —
    // `ref` is still valid mid-dispose, and the shell observer only
    // notifies on the subsequent `router.push`, so the resumer won't
    // mis-fire while we're still in this navigation transaction.
    ref.read(lastTypeaheadResumeProvider.notifier).state = TypeaheadResumeState(
      query: _controller.text,
      filter: _filter,
    );
    Navigator.of(context, rootNavigator: true).pop();
    router.push(path, extra: extra);
  }

  Future<void> _handleMicTap() async {
    // Voice mic is intentionally disabled inside the typeahead overlay
    // (v1 scope). Composer still renders the icon hidden via
    // `voiceEnabled: false`, so this is never actually invoked.
  }

  void _close() {
    Navigator.of(context, rootNavigator: true).pop();
  }

  // ---- Drag-to-dismiss handlers ---------------------------------------
  /// Empty-state drag: only wired when no results are visible (the list
  /// captures vertical scroll otherwise). Direct-manipulation: drag delta
  /// maps 1:1 to `_slideController.value` (0 = open, 1 = off-screen at
  /// bottom). Release decides snap-back vs dismiss based on distance +
  /// fling velocity.
  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!mounted) return;
    final h = MediaQuery.of(context).size.height;
    if (h <= 0) return;
    final delta = details.delta.dy / h;
    // Clamp so users can't drag UP past the resting open position.
    _slideController.value = (_slideController.value + delta).clamp(0.0, 1.0);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (!mounted) return;
    final velocity = details.primaryVelocity ?? 0;
    // Dismiss if dragged past 25% OR flung downward with enough velocity.
    final shouldDismiss = _slideController.value > 0.25 || velocity > 700;
    if (shouldDismiss) {
      _slideController
          .animateTo(1.0, duration: const Duration(milliseconds: 180))
          .whenComplete(() {
            if (mounted) _close();
          });
    } else {
      // Snap back to fully open.
      _slideController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final state = _resolveSearchState();
    // Chips visible only once at least one filter has data. Pre-query and
    // zero-results states render just the Soko empty hint — no chip row.
    final showChips = state.hasAnyResults;
    // Drag-to-dismiss is only available when there are no results visible
    // (otherwise vertical drag belongs to the result list's scroll).
    final dragToDismissEnabled = !state.hasAnyResults;

    final scaffold = Scaffold(
      backgroundColor: AppColors.sokoPaper,
      resizeToAvoidBottomInset: true,
      // Cap the overlay body at the same desktop max-width every other page
      // uses. The overlay launches via `showGeneralDialog` on the root
      // navigator (see [showDiscoveryTypeahead]), so it renders OUTSIDE
      // [DiscoveryShell] and does not pick up the shell-level [PageContent]
      // wrapper automatically — re-state the constraint here.
      body: SafeArea(
        child: PageContent(
          child: Column(
            children: [
              // Close (X) — top-right.
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
                  child: IconButton(
                    icon: const Icon(
                      LucideIcons.x,
                      size: 22,
                      color: AppColors.sokoInk,
                    ),
                    tooltip: l10n.discoveryChatTypeaheadCloseA11y,
                    onPressed: _close,
                  ),
                ),
              ),
              // Result list (fills remaining vertical space).
              Expanded(child: _buildResultsBody(l10n, state)),
              // Filter chips slot — kept always present (zero-height when
              // empty) so the composer's Column index stays stable across
              // results arriving. Toggling `if (showChips)` here used to
              // dispose+recreate the composer's TextField every time the
              // results state flipped, dropping focus + the soft keyboard.
              Padding(
                padding: showChips
                    ? const EdgeInsets.only(top: 8, bottom: 12)
                    : EdgeInsets.zero,
                child: showChips
                    ? TypeaheadFilterChips(
                        selected: _filter,
                        onChanged: (next) => setState(() => _filter = next),
                      )
                    : const SizedBox.shrink(),
              ),
              // Composer pinned above keyboard. Wrapped in a [Hero] with the
              // shared `kChatBarHeroTag` so the bar flies from Discovery's
              // top-of-page rest position down to here when the typeahead
              // opens (and back on pop). The [flightShuttleBuilder] always
              // renders the Discovery chat-bar's appearance during the
              // flight so the destination's autofocus + "Chat" pill don't
              // pop in mid-air.
              //
              // Tag-reuse note: the same tag is also used for the
              // Discovery → /chat send flight (see `discovery_chat_bar.dart`
              // + `message_input.dart`). Those flights run sequentially
              // (open typeahead → flight 1; press Send → pop overlay →
              // push /chat → flight 2), not concurrently, so the shared
              // tag does not cause a hero conflict.
              //
              // Send slot upgrades from circle → "Chat" pill once the
              // user has typed enough characters that starting a chat
              // session is a likely next action. Threshold reuses the
              // short-query cutoff so the two surfaces (filter strictness,
              // send affordance) flip together.
              //
              // Soko-Ink scallop motif sits directly above the composer
              // — same visual contract as the chat input on `/chat`.
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: ScallopDivider(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Hero(
                  tag: kChatBarHeroTag,
                  flightShuttleBuilder: _chatBarFlightShuttle,
                  child: Material(
                    color: Colors.transparent,
                    child: ChatBarTopRow(
                      controller: _controller,
                      focusNode: _focusNode,
                      placeholder: l10n.discoveryActionBarSearchHint,
                      hasText: _hasText,
                      voiceEnabled: false,
                      onSend: _handleSend,
                      onMicTap: _handleMicTap,
                      autofocus: true,
                      sendLabel: _isLongEnough
                          ? l10n.discoveryChatTypeaheadSendChat
                          : null,
                    ),
                  ),
                ),
              ),
              // PROD-2265: AI-disclosure line between the composer and the
              // keyboard. The chat-bar surfaces carry this in their bottom
              // strip; the typeahead overlay uses the strip-less
              // [ChatBarTopRow], so render the shared line standalone
              // (centered) here for parity. The underlined "third-party AI
              // providers" link opens the same shared disclosure sheet.
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 12),
                child: AiDisclosureStripText(
                  textAlign: TextAlign.center,
                  onSeeMore: () => AiDisclosureSheet.show(context, ref),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Apply the slide-translation (drag-to-dismiss). When at rest the
    // translateY is 0; mid-drag the body follows the finger; on release
    // either snaps back to 0 or animates to off-screen and pops.
    //
    // The tree shape is identical regardless of `dragToDismissEnabled`
    // — we only swap the gesture callbacks to null when drag is
    // disabled. Conditionally wrapping with a GestureDetector at the
    // root would change the widget type on every results-state flip,
    // causing Flutter to dispose+recreate the entire subtree (including
    // the composer's TextField), which dropped focus + soft keyboard.
    final screenHeight = MediaQuery.of(context).size.height;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: dragToDismissEnabled ? _onVerticalDragUpdate : null,
      onVerticalDragEnd: dragToDismissEnabled ? _onVerticalDragEnd : null,
      child: AnimatedBuilder(
        animation: _slideController,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, _slideController.value * screenHeight),
            child: Opacity(
              // Subtle fade as the panel slides away — keeps the dismiss
              // feeling natural without overdoing it.
              opacity: 1.0 - (_slideController.value * 0.4),
              child: child,
            ),
          );
        },
        child: scaffold,
      ),
    );
  }

  _SearchState _resolveSearchState() {
    final query = _debouncedQuery;
    if (query.length < kDiscoverySearchMinQueryLength) {
      return const _SearchState.preQuery();
    }

    final eventsAsync = ref.watch(
      discoverySearchResultsProvider(
        DiscoverySearchKey(
          category: DiscoverySearchCategory.eventos,
          query: query,
        ),
      ),
    );
    final placesAsync = ref.watch(
      discoverySearchResultsProvider(
        DiscoverySearchKey(
          category: DiscoverySearchCategory.sitios,
          query: query,
        ),
      ),
    );
    final zinesAsync = ref.watch(
      discoverySearchResultsProvider(
        DiscoverySearchKey(
          category: DiscoverySearchCategory.zines,
          query: query,
        ),
      ),
    );

    // Pick the score floor from query length. Tunable via dart-define so
    // QA can override without a deploy. Setting either threshold to 0.0
    // disables filtering for that bucket.
    final threshold = query.length < ApiConstants.typeaheadShortQueryThreshold
        ? ApiConstants.typeaheadMinScoreShortQuery
        : ApiConstants.typeaheadMinScoreLongQuery;

    // Drop Google-fallback places (those with no `venueId`) — the
    // `/venues/{id}` route is UUID-only on the backend, so tapping a
    // Google-only row throws a 422 `uuid_parsing` ValidationException.
    // `mode='fast'` is documented as "local-first with lightweight Google
    // fallback" so a few of these do leak through. For the typeahead
    // we only want results that can navigate cleanly.
    final placesFiltered =
        (placesAsync.valueOrNull?.rows ?? const <SearchResultRow>[])
            .where(_isNavigablePlace)
            .toList();

    return _SearchState(
      query: query,
      events: _filterAndSortByScore(
        eventsAsync.valueOrNull?.rows ?? const <SearchResultRow>[],
        threshold,
      ),
      places: _filterAndSortByScore(placesFiltered, threshold),
      // Zines have no `relevance_score` (see `UserListsListOut`) — keep
      // the backend's order untouched.
      zines: zinesAsync.valueOrNull?.rows ?? const <SearchResultRow>[],
      isLoading:
          eventsAsync.isLoading ||
          placesAsync.isLoading ||
          zinesAsync.isLoading,
      hasError:
          eventsAsync.hasError || placesAsync.hasError || zinesAsync.hasError,
    );
  }

  /// True if a row can route to a clean detail page. Filters out Google-
  /// fallback places (no `venueId` → UUID parse failure on `/venues/{id}`).
  /// Events always have a UUID `eventId` per the OpenAPI contract; zines
  /// always have a `urlIdentifier`. So this only filters places.
  bool _isNavigablePlace(SearchResultRow row) {
    if (row is! PlaceSearchResultRow) return true;
    final id = row.place.venueId;
    return id != null && id.isNotEmpty;
  }

  /// Drop rows below [threshold] (null scores are kept — defensive, since
  /// the backend may omit the field for older payloads or Google-fallback
  /// places) and sort the remainder DESC by score, sending nulls to the
  /// bottom of the group.
  List<SearchResultRow> _filterAndSortByScore(
    List<SearchResultRow> rows,
    double threshold,
  ) {
    final filtered =
        rows
            .where(
              (r) => r.relevanceScore == null || r.relevanceScore! >= threshold,
            )
            .toList()
          ..sort(
            (a, b) =>
                (b.relevanceScore ?? -1).compareTo(a.relevanceScore ?? -1),
          );
    return filtered;
  }

  Widget _buildResultsBody(Lt l10n, _SearchState state) {
    if (state.isPreQuery) {
      return const _EmptyHint();
    }

    if (state.isLoading && !state.hasAnyResults) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sokoInk,
          ),
        ),
      );
    }

    if (state.hasError && !state.hasAnyResults) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            l10n.discoverySearchError,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w300,
              color: AppColors.sokoShade3,
            ),
          ),
        ),
      );
    }

    if (!state.hasAnyResults) {
      // Total miss across every filter — Soko character + "search for
      // anything or ask me" copy, matching pre-query state.
      return const _EmptyHint();
    }

    final maxResults = ApiConstants.typeaheadMaxResults;
    final maxZines = ApiConstants.typeaheadMaxZines;

    // Non-"All" tabs are flat single-section lists capped at the relevant
    // per-tab limit (`maxZines` for zines, `maxResults` for everything else).
    if (_filter != TypeaheadFilter.all) {
      final (List<SearchResultRow> source, int cap) = switch (_filter) {
        TypeaheadFilter.events => (state.events, maxResults),
        TypeaheadFilter.places => (state.places, maxResults),
        TypeaheadFilter.zines => (state.zines, maxZines),
        TypeaheadFilter.all => (const [], 0), // unreachable
      };
      final rows = source.take(cap).toList();
      if (rows.isEmpty) {
        return _EmptyCopy(text: _emptyCopyFor(l10n, _filter, state.query));
      }
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        // Keep the soft keyboard open while the user scrolls / taps
        // results — the user dismisses it explicitly (close X, device
        // back, or the keyboard's own "Done" key).
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final row = rows[index];
          return TypeaheadResultRow(
            key: ValueKey(row.rowKey),
            row: row,
            onTap: () => _handleResultTap(row),
          );
        },
      );
    }

    // "All" tab structure (PROD-1909 follow-up):
    //   Top: events + places merged into one list and sorted DESC by
    //        `relevance_score` — they share the score so cross-source
    //        ranking is meaningful and avoids interleaving misses.
    //   Bottom: zines always sit underneath, in their own labeled section.
    //
    // The zine header only renders when there are also events/places
    // above it; a zines-only "All" reads as a flat list (the chip row
    // already communicates that "All" is the active filter).
    //
    // Total cap = [maxResults]. Events+places fill first (higher signal
    // since they have scores); zines take any remaining slots so they
    // always have a chance to appear, just at the bottom.
    final eventsAndPlacesFull = _filterAndSortByScore(
      [...state.events, ...state.places],
      // Re-sort the union — events and places were already filtered per
      // source in `_resolveSearchState`, so the threshold here is just
      // -infinity (anything that survived per-source filtering stays).
      double.negativeInfinity,
    );
    final eventsAndPlaces = eventsAndPlacesFull.take(maxResults).toList();
    // Zines have their own independent cap — they don't compete with
    // the events+places budget. So a packed `maxResults` events+places
    // list still shows up to [maxZines] zines below it.
    final zines = state.zines.take(maxZines).toList();

    final hasTop = eventsAndPlaces.isNotEmpty;
    final hasZines = zines.isNotEmpty;
    final showZinesHeader = hasTop && hasZines;

    final List<Widget> children = [];
    for (final row in eventsAndPlaces) {
      children.add(
        TypeaheadResultRow(
          key: ValueKey(row.rowKey),
          row: row,
          onTap: () => _handleResultTap(row),
        ),
      );
    }
    if (hasTop && hasZines) {
      // 8 px breathing room before the zines section so the header reads
      // as a clean break, not a continuation of the merged list.
      children.add(const SizedBox(height: 8));
    }
    if (hasZines) {
      if (showZinesHeader) {
        children.add(_GroupHeader(label: l10n.discoveryCategoryZines));
      }
      for (final row in zines) {
        children.add(
          TypeaheadResultRow(
            key: ValueKey(row.rowKey),
            row: row,
            onTap: () => _handleResultTap(row),
          ),
        );
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      // Same keyboard-open contract as the single-filter tabs above.
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
      children: children,
    );
  }

  String _emptyCopyFor(Lt l10n, TypeaheadFilter filter, String query) {
    switch (filter) {
      case TypeaheadFilter.events:
        return l10n.discoveryChatTypeaheadEmptyEvents(query);
      case TypeaheadFilter.places:
        return l10n.discoveryChatTypeaheadEmptyPlaces(query);
      case TypeaheadFilter.zines:
        return l10n.discoveryChatTypeaheadEmptyZines(query);
      case TypeaheadFilter.all:
        return l10n.discoverySearchNoResults(query);
    }
  }
}

/// Tiny uppercase section header rendered above the zines group in the
/// "All" tab. Stays muted — the colored accent on each row carries the
/// category signal; the header just structures the list.
class _GroupHeader extends StatelessWidget {
  final String label;
  const _GroupHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          height: 1.2,
          letterSpacing: 1.0,
          color: AppColors.sokoShade3,
        ),
      ),
    );
  }
}

/// Resolved typeahead state — captures the three async streams + their
/// rollup flags. Computed once in `build()` so chip visibility and the
/// result body see the same snapshot.
class _SearchState {
  final String query;
  final List<SearchResultRow> events;
  final List<SearchResultRow> places;
  final List<SearchResultRow> zines;
  final bool isLoading;
  final bool hasError;
  final bool isPreQuery;

  const _SearchState({
    required this.query,
    required this.events,
    required this.places,
    required this.zines,
    required this.isLoading,
    required this.hasError,
  }) : isPreQuery = false;

  const _SearchState.preQuery()
    : query = '',
      events = const [],
      places = const [],
      zines = const [],
      isLoading = false,
      hasError = false,
      isPreQuery = true;

  bool get hasAnyResults =>
      events.isNotEmpty || places.isNotEmpty || zines.isNotEmpty;
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/illustrations/soko-seating-and-reading.webp',
              width: 115,
              height: 115,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 10),
            Text(
              l10n.discoveryChatTypeaheadHint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w300,
                height: 1.3,
                letterSpacing: -0.16,
                color: AppColors.sokoInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyCopy extends StatelessWidget {
  final String text;
  const _EmptyCopy({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w300,
            color: AppColors.sokoShade3,
          ),
        ),
      ),
    );
  }
}

/// Hero shuttle for the Discovery chat-bar ↔ typeahead-composer flight.
///
/// In both directions we render the *Discovery* chat-bar's appearance
/// (clean rest state — typewriter placeholder, no entered text, no
/// "Chat" pill, no autofocus-driven keyboard pop) so the bar reads as a
/// single object smoothly translating between rest positions, regardless
/// of what the typeahead composer happened to be showing when the flight
/// started.
///
/// - On `push` (Discovery → typeahead): `fromHeroContext` is the
///   Discovery source — use its child.
/// - On `pop` (typeahead → Discovery): `toHeroContext` is the Discovery
///   destination — use its child.
Widget _chatBarFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final BuildContext discoveryCtx = flightDirection == HeroFlightDirection.push
      ? fromHeroContext
      : toHeroContext;
  return (discoveryCtx.widget as Hero).child;
}

/// PROD-1983: zero-size widget mounted inside [DiscoveryScreen] that
/// holds the three `discoverySearchResultsProvider` family entries
/// (events / places / zines for the captured query) alive across the
/// typeahead pop → detail push → detail pop cycle. Without it the
/// providers auto-dispose the moment the typeahead pops and the
/// re-opened overlay would surface a loading spinner before the cached
/// results re-appear.
///
/// The actual re-opening of the overlay is handled by
/// [typeaheadResumeNavObserver], which fires synchronously inside the
/// pop transaction so the shell-nav pop and the root-nav typeahead
/// push are processed for the same frame.
class TypeaheadResumer extends ConsumerStatefulWidget {
  const TypeaheadResumer({super.key});

  @override
  ConsumerState<TypeaheadResumer> createState() => _TypeaheadResumerState();
}

class _TypeaheadResumerState extends ConsumerState<TypeaheadResumer> {
  final List<ProviderSubscription<dynamic>> _keepAlive = [];

  @override
  void dispose() {
    _releaseKeepAlive();
    super.dispose();
  }

  void _releaseKeepAlive() {
    for (final sub in _keepAlive) {
      sub.close();
    }
    _keepAlive.clear();
  }

  @override
  Widget build(BuildContext context) {
    // Acquire keep-alive subscriptions when [_handleResultTap] writes a
    // resume snapshot; release them post-frame after the observer has
    // re-pushed the typeahead (the new overlay's initState attaches its
    // own listeners on that frame, so releasing earlier would leave the
    // providers with zero listeners for a microtask and trigger
    // autoDispose → refetch → spinner).
    ref.listen<TypeaheadResumeState?>(lastTypeaheadResumeProvider, (
      prev,
      next,
    ) {
      if (next == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _releaseKeepAlive();
        });
        return;
      }
      _releaseKeepAlive();
      final q = next.query.trim();
      if (q.length < kDiscoverySearchMinQueryLength) return;
      final container = ProviderScope.containerOf(context, listen: false);
      for (final cat in DiscoverySearchCategory.values) {
        _keepAlive.add(
          container.listen(
            discoverySearchResultsProvider(
              DiscoverySearchKey(category: cat, query: q),
            ),
            (_, __) {},
          ),
        );
      }
    });
    return const SizedBox.shrink();
  }
}
