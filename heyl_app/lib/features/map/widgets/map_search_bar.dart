import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/map_search_history.dart';
import '../../../l10n/generated/l10n.dart';
import '../models/map_active_search.dart';
import '../providers/map_search_executor.dart';
import '../providers/map_search_history_provider.dart';
import '../providers/map_search_provider.dart';

/// The Map page's v2 search bar (PROD-3496) — a flat pill derived from the
/// retired v1 keyword field (Figma `6917-18150`: Ink8 hairline border, radius
/// 40, search glyph left, X clear right), resized to match its row-mate: the
/// floating `SokoBackButton` circle (Zé, 2026-07-28 — height 44 and the same
/// white fill, instead of the v1 field's 40px sokoPaper). Wired to
/// [mapSearchProvider]: gaining focus enters the focused search mode
/// (scrim + dropdown, rendered by `MapSearchFocusedOverlay`), typing mirrors
/// the text into state for the suggestion layer (FE-2 / PROD-3497).
///
/// Deliberately NO query execution here: `onSubmitted` and keyword commits
/// land with FE-3 (PROD-3498), suggestion fetching with FE-2. Final visual
/// design is pending — restyle when it lands (Decision #4).
class MapSearchBar extends ConsumerStatefulWidget {
  const MapSearchBar({super.key});

  @override
  ConsumerState<MapSearchBar> createState() => _MapSearchBarState();
}

class _MapSearchBarState extends ConsumerState<MapSearchBar> {
  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(onKeyEvent: _onKeyEvent);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    // Gaining field focus opens the mode. Losing it does NOT close the mode:
    // `TextInputAction.search` unfocuses on submit and Android back #1
    // dismisses the keyboard — both must keep the dropdown up (G2 /
    // Decision #33). Exits go through [MapSearchNotifier.exitFocus] only.
    if (_focusNode.hasFocus) {
      ref.read(mapSearchProvider.notifier).enterFocus();
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      ref.read(mapSearchProvider.notifier).exitFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onChanged(String value) {
    ref.read(mapSearchProvider.notifier).setText(value);
  }

  /// D7 — the keyboard's search key runs the **general keyword search**, never
  /// an implicit top-match selection. Gated at the same rung the pinned
  /// general row appears on (≥2 chars, Decision #36), so Enter can't fire
  /// something the dropdown wasn't offering.
  ///
  /// Deliberately fires **no analytics of its own.** A keyword search must be
  /// counted because it EXECUTED, not because a particular key was pressed —
  /// Enter's behaviour may change. `map_area_searched{trigger:'keyword'}` and
  /// `map_filter_change{filter:'keyword'}` both come off the executor and are
  /// producer-agnostic, so this path is already counted and stays correct if
  /// the key stops running a keyword search. (`map_suggest_selected` means "a
  /// dropdown row was picked", which this is not.) PROD-3500.
  ///
  /// The history write below IS Enter's own: recording is producer-side by
  /// design (the executor must not record, or `MapPastSearchReExecutor`'s
  /// recency bump double-writes), and Enter is a producer of a keyword
  /// selection for exactly as long as this line sits next to that call.
  void _onSubmitted(String value) {
    final query = value.trim();
    if (query.length < 2) return;
    unawaited(
      ref
          .read(mapSearchHistoryProvider.notifier)
          .recordSelection(
            type: MapSearchHistoryType.keyword,
            queryText: query,
            displayLabel: query,
          ),
    );
    unawaited(ref.read(mapSearchExecutorProvider).executeKeyword(query));
  }

  /// The X means two different things, by mode:
  /// - **focused** — clear the text, stay in the mode (the X is not an exit);
  /// - **idle with a search active** — D9: drop the active search and restore
  ///   the default pins for the current viewport/scope. The camera stays.
  void _clear() {
    _controller.clear();
    final search = ref.read(mapSearchProvider);
    if (search.focused) {
      ref.read(mapSearchProvider.notifier).setText('');
      return;
    }
    clearMapActiveSearch(ref);
  }

  /// The leading glyph: the active search's type icon (D8) or the plain
  /// search glyph. Same icons the suggestion rows use, so the bar visibly
  /// echoes the row that was picked.
  IconData _leadingIcon(MapActiveSearch? active) {
    if (active == null) return LucideIcons.search;
    return switch (active.type) {
      MapSearchTargetType.keyword => LucideIcons.search,
      MapSearchTargetType.venue => LucideIcons.store,
      MapSearchTargetType.event => LucideIcons.calendar,
      MapSearchTargetType.location => LucideIcons.map_pin,
      MapSearchTargetType.list => LucideIcons.book_open,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    // Only the clear-X visibility depends on state here — the field itself
    // repaints via the controller, so don't rebuild the bar per keystroke.
    final hasText = ref.watch(
      mapSearchProvider.select((s) => s.text.isNotEmpty),
    );
    // PROD-3498 — the active search drives the idle chrome (D8): type icon,
    // its label in place of the hint, and an X that un-searches.
    final active = ref.watch(mapSearchProvider.select((s) => s.active));

    // Exit is state-driven (back arrow / system back / Esc / desktop
    // map-click all just flip the provider): sync the field when the mode
    // closes. Programmatic clears don't re-fire [_onChanged], and unfocus
    // never re-enters the mode (only focus GAIN does), so no feedback loop.
    ref.listen(mapSearchProvider.select((s) => s.focused), (previous, next) {
      if (previous == true && next == false) {
        _controller.clear();
        _focusNode.unfocus();
        return;
      }
      // F5 — re-opening the bar with a search active pre-fills its label and
      // SELECTS it, so the next keystroke replaces the whole thing (and the
      // suggestion lanes see the label as the query meanwhile). Driven off the
      // provider rather than the focus callback so every entry point behaves
      // identically.
      if (next == true) {
        // PROD-3653 — take the keyboard whenever the MODE opens, not only when
        // the field was tapped. Focus normally flows field → mode
        // (`_onFocusChanged` calls `enterFocus`); a programmatic entry point
        // like the "Zine +" chip runs that arrow backwards, so without this the
        // bar appears with no keyboard and no caret and the user has to tap it
        // — reported on-device by Zé. `enterFocus` early-returns while already
        // focused, so `requestFocus` cannot loop back through the listener.
        //
        // Scoped to the false→true EDGE on purpose: dismissing the keyboard
        // while the mode is up (Android back #1) leaves `focused` true and
        // unfocuses the field, and Decision #33 requires that to STAY dismissed
        // with the dropdown growing into the freed space. Listening on the edge
        // means that case never re-raises it.
        if (!_focusNode.hasFocus) _focusNode.requestFocus();
        final seeded = ref.read(mapSearchProvider).text;
        if (seeded.isEmpty || _controller.text == seeded) return;
        _controller.value = TextEditingValue(
          text: seeded,
          selection: TextSelection(baseOffset: 0, extentOffset: seeded.length),
        );
      }
    });

    // Fixed-height Row (not TextField prefix/suffix) so the pill keeps its
    // height whether or not the X is showing — same construction as the v1
    // field. 44 + white match the floating SokoBackButton beside it.
    return GestureDetector(
      // Make the whole pill a tap target (icon + padding included) — the
      // TextField alone only claims its own line box.
      onTap: _focusNode.requestFocus,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(40),
          border: Border.all(color: AppColors.sokoInk8),
        ),
        child: Row(
          children: [
            Icon(_leadingIcon(active), size: 16, color: AppColors.sokoInk),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                onChanged: _onChanged,
                onSubmitted: _onSubmitted,
                textInputAction: TextInputAction.search,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.2,
                  color: AppColors.sokoInk,
                ),
                // Kill the app-wide inputDecorationTheme (filled + r12
                // border): the pill IS the outer Container, so the field
                // itself must be a borderless, unfilled, padding-free line.
                decoration: InputDecoration(
                  isCollapsed: true,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  // With a search active but the mode closed, the field is
                  // empty and its "hint" IS the active label — rendered at
                  // full strength, since it's a state, not a placeholder (D8).
                  hintText: active?.label ?? l10n.mapSearchHint,
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: AppColors.sokoInk.withValues(
                      alpha: active == null ? 0.5 : 1.0,
                    ),
                  ),
                ),
              ),
            ),
            if (hasText || active != null) ...[
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: l10n.mapSearchClear,
                child: GestureDetector(
                  onTap: _clear,
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: AppColors.sokoInk,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
