import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/discovery/providers/search_category_provider.dart';
import '../../l10n/generated/l10n.dart';
import 'search_category_tabs.dart';
import 'soko_search_input_pill.dart';
import 'search_category_tag_row.dart';

/// Default debounce window applied to typed input before the trimmed
/// query is pushed into [SearchOverlay.queryProvider]. 600 ms — same
/// "typing feel" across every search surface.
const Duration kSearchOverlayDefaultDebounce = Duration(milliseconds: 600);

/// Which category selector the overlay renders.
///
/// PROD-4081 — the two surfaces that SEARCH (Discovery, Procura) moved to the
/// shared Tag row so they match the feed's filter row; the `/lists` hub and the
/// profile's Saved tab keep the original pills, which carry an "All" option the
/// Tag row has no concept of.
enum SearchCategoryRowStyle {
  /// [SearchCategoryTabs] — the `BtSqIco` pills.
  pills,

  /// [SearchCategoryTagRow] — the scrolling Tag chips shared with the feed.
  tags,
}

/// Search-overlay row used by both `DiscoverySearchOverlay` and
/// `ListsSearchOverlay`. Renders:
///   - the rounded Soko-Ink-tinted input pill (magnifier + textfield +
///     close X)
///   - the centered [SearchCategoryTabs] (Zines / Eventos / Sítios)
///
/// Each surface plugs its own state providers in:
///   - [openProvider]   — `StateProvider<bool>` flipping the overlay
///     on/off (the X tap writes `false` here).
///   - [queryProvider]  — `StateProvider<String>` receiving the
///     debounced trimmed query.
///   - [categoryProvider] — `StateProvider<DiscoverySearchCategory>`
///     driving the selected tab.
///
/// This keeps the two surfaces visually identical (one widget; tweaks
/// to chrome land in one place) while keeping their state forked
/// (typing on `/lists` doesn't leak into `/discovery` and vice versa).
class SearchOverlay extends ConsumerStatefulWidget {
  /// `StateProvider<bool>` driving the overlay open/close.
  ///
  /// **This widget never reads or writes it** — verified, not assumed: the
  /// open/close flag is owned entirely by the hosts (the host's PopScope, the
  /// bottom-nav Home button (PROD-2280), the product tour, and Discovery's own
  /// [onCloseWhenEmpty] callback), and the X inside the input pill only clears
  /// the typed text. It survives as a parameter because the two existing
  /// callers pass it and it documents which flag governs the surface.
  ///
  /// PROD-4081 made it optional rather than deleting it: Procura is a *route*,
  /// so it has no open flag at all, and requiring one would have meant
  /// inventing a provider whose only job is to satisfy an argument nobody
  /// reads. Deleting it outright is a separate cleanup across the two callers
  /// that still pass it.
  final StateProvider<bool>? openProvider;

  /// `StateProvider<String>` that receives the debounced trimmed
  /// query. The overlay owns the controller + debounce; consumers
  /// (results providers) just watch this provider.
  final StateProvider<String> queryProvider;

  /// `StateProvider<DiscoverySearchCategory>` for the selected tab.
  /// Forked per surface so navigating across pages doesn't carry
  /// stale category state.
  final StateProvider<DiscoverySearchCategory> categoryProvider;

  /// Placeholder text shown when the input is empty. Discovery passes
  /// "Pesquisar na Soko" / "Search Soko"; Lists passes
  /// "Procura nas tuas listas" / "Search your lists".
  final String hintText;

  /// Debounce window before the trimmed input is pushed into
  /// [queryProvider]. Defaults to [kSearchOverlayDefaultDebounce].
  final Duration debounce;

  /// PROD-2026 — forwards to [SearchCategoryTabs.includeAll]. The
  /// `/yours` hub sets this to `true` so its tab row gains an "All"
  /// pill (rendering zines + events + places stacked). Discovery
  /// keeps the original 3-pill layout (default `false`).
  final bool includeAllCategory;

  /// PROD-2221 — optional widget rendered to the right of the input
  /// pill on the same row (with a 6 px gap). The input becomes
  /// `Expanded` so it grows up to this trailing widget. When `null`
  /// (the default + `/lists` hub behavior), the input takes the full
  /// row width as today. Discovery passes its
  /// [ActionBarLocationPill] here so the user's selected city stays
  /// visible while typing.
  final Widget? inputTrailing;

  /// Builder variant of [inputTrailing] for surfaces that need to size
  /// the trailing widget based on the row's actual available width
  /// (e.g. Discovery's location pill, which runs its own responsive
  /// cascade against [LayoutBuilder] constraints). When set, takes
  /// precedence over [inputTrailing].
  final Widget Function(BuildContext context, double trailingMaxWidth)?
  inputTrailingBuilder;

  /// PROD-4179 — make the ✕ close on the FIRST tap, even with text in the
  /// field, clearing the query on the way out.
  ///
  /// The default is the two-stage control PROD-2280 shipped: clear while there
  /// is text, close only when already empty. The feed's inline Procura mode
  /// wants one tap to exit (Zé, 2026-09-03) — there is no route to pop there,
  /// so the ✕ is the primary way out and a first tap that only clears reads as
  /// the control being broken. Requires [onCloseWhenEmpty] to be wired; without
  /// it there is nothing to close and this does nothing.
  final bool closeOnFirstClear;

  /// Optional [Key] attached to the X close button. The product tour
  /// (`_TourCursor`) reads this key's RenderBox position to drive its
  /// cursor toward the X when transitioning out of the discoverCity
  /// step. Null for non-Discovery hosts (Lists, etc.) — keeps the
  /// tour-coupling at the call-site level rather than baked into the
  /// shared widget.
  final Key? closeButtonKey;

  /// Optional per-category `Key`s applied to each chip inside
  /// [SearchCategoryTabs]. The product tour's looping demo cursor
  /// (`_TourDescobreTabsCursor`) reads these keys to find each tab's
  /// position. Null for non-Discovery hosts.
  final Map<DiscoverySearchCategory, Key>? categoryChipKeys;

  /// PROD-2240 — when `false`, the overlay does NOT auto-request focus on
  /// mount, so the soft keyboard doesn't pop open on mobile the moment the
  /// overlay reveals. Default `true` preserves the "tap → type immediately"
  /// behavior used by every existing caller (desktop, the `/yours` hub).
  final bool autoFocus;

  /// Optional filter strip rendered beneath the category tabs, ONLY while
  /// the Events tab is selected. Discovery passes its `EventFiltersBar`
  /// here (time-range + category pills); the `/lists` hub leaves this null,
  /// so filters stay a Discovery-only surface.
  final WidgetBuilder? eventFiltersBuilder;

  /// Optional filter strip rendered beneath the category tabs, ONLY while
  /// the Places tab is selected. Discovery passes its `PlaceFiltersBar`
  /// here; the `/lists` hub leaves this null.
  final WidgetBuilder? placeFiltersBuilder;

  /// Forwards to [SearchCategoryTabs.fillWidth]. Discovery passes `true`
  /// so the category row spans the full width; `/lists` keeps the
  /// scrollable content-sized layout (default `false`).
  final bool fillWidthTabs;

  /// Forwards to [SearchCategoryTabs.categoryOrder]. Discovery passes an
  /// order that appends the Leitores tab; surfaces that leave it null
  /// keep the default Events / Places / Zines row.
  final List<DiscoverySearchCategory>? categoryOrder;

  /// Optional close handler invoked when the input's X is tapped while the
  /// field is **already empty** (nothing left to clear). When set, the X
  /// becomes a two-stage control: first tap clears the typed text, a
  /// second tap (empty field) closes the overlay. Discovery uses this to
  /// return to the home feed (restoring scroll); surfaces that leave it
  /// `null` keep the original "X only ever clears text" behavior.
  final VoidCallback? onCloseWhenEmpty;

  /// PROD-4081 — which selector to render. See [SearchCategoryRowStyle].
  final SearchCategoryRowStyle categoryRowStyle;

  /// PROD-4081 — the host page's horizontal padding, so the Tag row can escape
  /// it and run edge-to-edge (Zé, 2026-08-31).
  ///
  /// Only meaningful with [SearchCategoryRowStyle.tags]. The overlay is one
  /// child of a Column the page pads as a whole, so this row cannot simply be
  /// mounted outside that padding the way the feed's is — it has to grow back
  /// out. Pass the exact figure the page applied; 0 leaves the row inside it.
  final double categoryRowBleed;

  const SearchOverlay({
    super.key,
    this.openProvider,
    required this.queryProvider,
    required this.categoryProvider,
    required this.hintText,
    this.debounce = kSearchOverlayDefaultDebounce,
    this.includeAllCategory = false,
    this.inputTrailing,
    this.inputTrailingBuilder,
    this.closeButtonKey,
    this.categoryChipKeys,
    this.autoFocus = true,
    this.eventFiltersBuilder,
    this.placeFiltersBuilder,
    this.fillWidthTabs = false,
    this.categoryOrder,
    this.onCloseWhenEmpty,
    this.closeOnFirstClear = false,
    this.categoryRowStyle = SearchCategoryRowStyle.pills,
    this.categoryRowBleed = 0,
  });

  @override
  ConsumerState<SearchOverlay> createState() => _SearchOverlayState();
}

class _SearchOverlayState extends ConsumerState<SearchOverlay> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onSearchChanged);
    // The overlay mounts when the host flips `openProvider` to true —
    // request focus next frame so the keyboard appears without the
    // user needing to tap again. Callers can opt out via `autoFocus:
    // false` (PROD-2240 — Discovery skips this on mobile so the soft
    // keyboard doesn't cover the default content).
    if (widget.autoFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.removeListener(_onSearchChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final trimmed = _controller.text.trim();
    if (trimmed.isEmpty) {
      _debounceTimer?.cancel();
      _setQuery('');
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(widget.debounce, () => _setQuery(trimmed));
  }

  void _setQuery(String value) {
    if (!mounted) return;
    final notifier = ref.read(widget.queryProvider.notifier);
    if (notifier.state != value) notifier.state = value;
  }

  // The X inside the input pill is a two-stage control (PROD-2280 +
  // follow-up): when there's typed text it clears the text + query and
  // stays open; when the field is *already empty* it closes the overlay
  // via [onCloseWhenEmpty] (Discovery returns to the home feed, restoring
  // scroll). Hosts that don't pass the callback keep the original
  // clear-only behavior. Focus is left untouched on the clear path so the
  // soft-keyboard state follows whatever the user was doing.
  void _clearInput() {
    _debounceTimer?.cancel();
    // PROD-4179 — one tap out, for hosts that asked for it. The clear still
    // happens: the surface is being left, so leaving a query behind would
    // reopen onto a stale search.
    if (widget.closeOnFirstClear && widget.onCloseWhenEmpty != null) {
      if (_controller.text.isNotEmpty) {
        _controller.clear();
        _setQuery('');
      }
      widget.onCloseWhenEmpty!.call();
      return;
    }
    if (_controller.text.isEmpty) {
      widget.onCloseWhenEmpty?.call();
      return;
    }
    _controller.clear();
    _setQuery('');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final selected = ref.watch(widget.categoryProvider);

    // Search input pill — the shared [SokoSearchInputPill] since PROD-4179.
    // Pulled out so the same pill is used here and in the feed's inline Procura
    // chrome, which morphs its filter-row circle into it; it is also used in
    // both of this widget's own modes ("input takes full row" and
    // "input + trailing widget on the same row", PROD-2221 Discovery).
    final inputPill = SokoSearchInputPill(
      controller: _controller,
      focusNode: _focusNode,
      hintText: widget.hintText,
      clearSemanticLabel: l10n.discoveryActionBarSearchClose,
      clearButtonKey: widget.closeButtonKey,
      onClear: _clearInput,
    );

    // PROD-2221 — when the host passes [inputTrailing] / [inputTrailingBuilder],
    // wrap the input pill in `Expanded` and lay it out alongside the
    // trailing widget (Discovery's location pill). Otherwise the input
    // takes the full row width as today.
    final hasTrailing =
        widget.inputTrailingBuilder != null || widget.inputTrailing != null;
    final Widget inputRow = hasTrailing
        ? LayoutBuilder(
            builder: (context, constraints) {
              // Reserve a sensible minimum for the input itself (about
              // half the row, never less than 140 px so the placeholder
              // stays readable on iPhone-SE-class widths) — the rest is
              // the trailing widget's budget.
              const inputMinReserve = 140.0;
              final trailingBudget =
                  (constraints.maxWidth - inputMinReserve - 6.0).clamp(
                    0.0,
                    constraints.maxWidth,
                  );
              final trailing =
                  widget.inputTrailingBuilder?.call(context, trailingBudget) ??
                  widget.inputTrailing!;
              return Row(
                children: [
                  Expanded(child: inputPill),
                  const SizedBox(width: 6),
                  trailing,
                ],
              );
            },
          )
        : inputPill;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        inputRow,
        const SizedBox(height: 12),
        // Centered Zines / Eventos / Sítios pills (plus an optional
        // leading "All" pill on surfaces that opt in via
        // [SearchOverlay.includeAllCategory]).
        if (widget.categoryRowStyle == SearchCategoryRowStyle.tags)
          SearchCategoryTagRow(
            selected: selected,
            escapeHorizontalPadding: widget.categoryRowBleed,
            categoryOrder: widget.categoryOrder,
            onSelect: (cat) =>
                ref.read(widget.categoryProvider.notifier).state = cat,
            chipKeys: widget.categoryChipKeys,
          )
        else
          SearchCategoryTabs(
            selected: selected,
            includeAll: widget.includeAllCategory,
            fillWidth: widget.fillWidthTabs,
            categoryOrder: widget.categoryOrder,
            onSelect: (cat) =>
                ref.read(widget.categoryProvider.notifier).state = cat,
            chipKeys: widget.categoryChipKeys,
          ),
        // Events-only filter strip (time range + categories). Only the
        // Events tab exposes filters; other tabs render nothing here.
        if (widget.eventFiltersBuilder != null &&
            selected == DiscoverySearchCategory.eventos) ...[
          const SizedBox(height: 8),
          widget.eventFiltersBuilder!(context),
        ],
        if (widget.placeFiltersBuilder != null &&
            selected == DiscoverySearchCategory.sitios) ...[
          const SizedBox(height: 8),
          widget.placeFiltersBuilder!(context),
        ],
      ],
    );
  }
}
