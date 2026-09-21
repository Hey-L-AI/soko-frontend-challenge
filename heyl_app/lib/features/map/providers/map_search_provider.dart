import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../models/map_active_search.dart';
import '../utils/map_suggest_composer.dart' show MapSuggestSection;

/// State for the Map page's v2 search bar + focused search mode (PROD-3496).
///
/// [focused] is the focused-MODE gate, deliberately independent of the
/// text field's [FocusNode]: `TextInputAction.search` unfocuses the field on
/// submit (Flutter's `_finalizeEditing`), and dismissing the soft keyboard
/// while the mode is up (Android back #1) must keep the mode open with the
/// dropdown growing into the freed space (G2/Decision #33). Gate every
/// focused-mode surface (scrim, dropdown, exit routing) on THIS flag, never
/// on `FocusNode.hasFocus`.
@immutable
class MapSearchState {
  const MapSearchState({
    this.focused = false,
    this.text = '',
    this.active,
    this.domain,
    this.domainUnbounded = false,
  });

  /// Whether the focused search mode (scrim + dropdown) is active.
  final bool focused;

  /// The live bar text. Survives keyboard dismissal; cleared on exit.
  final String text;

  /// PROD-3498 — the search currently applied to the map, or null for the
  /// idle map. Survives leaving focused mode (that's the whole point: the bar
  /// keeps showing what you searched for, D8) and is replaced wholesale by the
  /// next execution (Decision #30).
  final MapActiveSearch? active;

  /// PROD-3652 — the selected domain tag, or null for the unscoped dropdown.
  ///
  /// Deliberately lives HERE and not on `MapSuggestState`, for one reason that
  /// pays for itself: the umbrella requires the tag to clear when focused mode
  /// exits, and every exit path already rebuilds this object from scratch
  /// ([exitFocus], [setActive], [clearActive]) — so that rule holds **by
  /// construction**, with no code to write and nothing to keep in sync. Putting
  /// it on the suggest notifier would have meant a fourth thing to remember to
  /// reset on each of those paths.
  ///
  /// Typed as a [MapSuggestSection] rather than a [MapSuggestDomain] because
  /// `locations` is a tag but not a `/map/suggest` domain — see
  /// `domainForSection`.
  final MapSuggestSection? domain;

  /// PROD-3653 — whether [domain] arrived from an entry point that must search
  /// **all of Soko** regardless of the map's active corpus.
  ///
  /// Exactly one thing sets it: the "De quem?" panel's `Zine +` chip. That chip
  /// is a *discovery* affordance, and the backend bounds every suggest domain to
  /// the corpus — so under "As tuas" it would offer only the user's own Zines,
  /// and there would be no way to reach anyone else's (PROD-3562's contract
  /// note). Suppressing the corpus for that one entry point is Zé's call
  /// (2026-08-05): a **manual** tap on the Zines tag in the row keeps the
  /// corpus, so the tag row's own contract with the banner is untouched.
  ///
  /// Deliberately a flag on the *selection* rather than a mode on the fetch
  /// layer: it is a property of how this tag was chosen, so it must die with the
  /// tag. [MapSearchNotifier.enterFocus] refuses it for any domain but
  /// [MapSuggestSection.lists], [MapSearchNotifier.setDomain] always writes
  /// false, and every state rebuild defaults it to false — so **"true only
  /// alongside `domain == lists`"** holds by construction rather than by anyone
  /// remembering to honour it.
  final bool domainUnbounded;

  @override
  bool operator ==(Object other) =>
      other is MapSearchState &&
      other.focused == focused &&
      other.text == text &&
      other.active == active &&
      other.domain == domain &&
      other.domainUnbounded == domainUnbounded;

  @override
  int get hashCode =>
      Object.hash(focused, text, active, domain, domainUnbounded);
}

/// Owns the focused-mode lifecycle. Every exit trigger (repurposed back
/// arrow, Android/browser back, Esc, desktop map-click, leave-guard) funnels
/// through [exitFocus] so the mode can't half-close.
class MapSearchNotifier extends StateNotifier<MapSearchState> {
  MapSearchNotifier({this.onSearchOpened}) : super(const MapSearchState());

  /// PROD-3500 — `map_search_opened`, wired to analytics by the provider.
  /// Optional so tests can construct a bare notifier; injected rather than
  /// read from a [Ref] so every focus rule stays assertable without mocks.
  final void Function()? onSearchOpened;

  /// Enter focused mode. Idempotent; keeps any text already in the bar.
  ///
  /// F5 — with a search active, the bar re-opens pre-filled with that label
  /// (the field selects it, so typing replaces it). The bar seeds [text] here
  /// rather than the caller, so every entry point behaves the same.
  ///
  /// PROD-3652 — [domain] preselects a tag. Null (every caller today) opens
  /// unscoped, which is the umbrella's rule: reopening always starts unscoped
  /// *except* via an entry point that sets one deliberately. This parameter is
  /// that exception, and the seam PROD-3653's "Zine" chip plugs into.
  ///
  /// PROD-3653 — [domainUnbounded] additionally drops the map's corpus from the
  /// suggest request for as long as that tag is in force. Only the `Zine +`
  /// chip passes it; see [MapSearchState.domainUnbounded] for why.
  ///
  /// **Ignored for any domain but [MapSuggestSection.lists]**, and the pair is
  /// written together so the flag can never outlive the tag it belongs to. The
  /// scoping is Zé's ("an edge case of this Zine + chip"), and enforcing it here
  /// rather than by caller discipline is the difference between a rule and a
  /// convention: a future entry point that wants an unbounded venues search has
  /// to come back and widen this deliberately, instead of getting it by passing
  /// a flag that was never reviewed for that domain.
  ///
  /// Guarded by the `focused` early-return like everything else here: a second
  /// call on an already-open bar must not silently re-scope what the user is
  /// looking at.
  void enterFocus({MapSuggestSection? domain, bool domainUnbounded = false}) {
    if (state.focused) return;
    final text = state.text.isNotEmpty
        ? state.text
        : (state.active?.label ?? '');
    state = MapSearchState(
      focused: true,
      text: text,
      active: state.active,
      domain: domain,
      domainUnbounded: domain == MapSuggestSection.lists && domainUnbounded,
    );
    // Behind the guard above on purpose: one event per OPEN, not per focus
    // gain. `TextInputAction.search` unfocuses on submit and Android back #1
    // dismisses the keyboard, both of which re-focus the field later in the
    // same session (Decision #33) — none of that is a new search.
    onSearchOpened?.call();
  }

  /// Mirror the bar's live text into state (FE-2 derives suggestions from
  /// it). No debounce here — fetch layers own their own debounce.
  void setText(String value) {
    if (state.text == value) return;
    state = MapSearchState(
      focused: state.focused,
      text: value,
      active: state.active,
      domain: state.domain,
      domainUnbounded: state.domainUnbounded,
    );
  }

  /// PROD-3652 — select a domain tag, or pass null to clear it. The tag row
  /// owns toggle semantics (re-tapping the selected tag calls this with null).
  ///
  /// Carries [focused] and [text] through: tapping a tag must not disturb what
  /// the user has typed, and the suggest lanes re-run off the domain change
  /// alone.
  ///
  /// PROD-3653 — always drops [MapSearchState.domainUnbounded]. This is the
  /// **whole** implementation of "only a tag that arrived via the `Zine +` chip
  /// searches outside the corpus": every other way a tag can be selected goes
  /// through here, so a manual tap keeps the corpus without a single line
  /// deciding that it should.
  ///
  /// The guard compares the **pair**, not the domain alone — the corpus-clearing
  /// transition `(lists, unbounded) → (lists, bounded)` leaves the domain equal,
  /// and swallowing it would leave the dropdown showing results fetched under
  /// the other scope.
  void setDomain(MapSuggestSection? domain) {
    if (state.domain == domain && !state.domainUnbounded) return;
    state = MapSearchState(
      focused: state.focused,
      text: state.text,
      active: state.active,
      domain: domain,
    );
  }

  /// Leave focused mode. Atomically clears the text — the bar falls back to
  /// the active-search chrome (D8) or, with nothing active, its idle
  /// placeholder. The active search itself is deliberately preserved: exiting
  /// the mode is not un-searching.
  ///
  /// PROD-3652 — the domain tag clears here too, and by construction: this
  /// rebuilds [MapSearchState] from scratch, so `domain` returns to its null
  /// default without a line of its own. `domain` joins the early-return guard
  /// for the same reason `text` is in it — a tag that outlived its focused
  /// session would be invisible (the row only renders while focused) and
  /// therefore impossible to clear, silently scoping the next search.
  ///
  /// PROD-3653 — `domainUnbounded` rides along for free for the same reason,
  /// and needs no guard clause of its own: it is only ever true alongside a
  /// non-null `domain`, which the guard below already covers.
  void exitFocus() {
    if (!state.focused && state.text.isEmpty && state.domain == null) return;
    state = MapSearchState(active: state.active);
  }

  /// PROD-3498 — commit an executed selection (Decision #30: it replaces
  /// whatever was active). Leaves focused mode in the same state write, so the
  /// camera unfreezes before the executor's camera command lands
  /// (`mapCameraFrozenProvider` watches `focused`).
  void setActive(MapActiveSearch active) {
    state = MapSearchState(active: active);
  }

  /// D9 — the bar's X with a search active: back to the idle map. The map-side
  /// effects (keyword, promoted pin) are undone by the executor; this only
  /// drops the chrome.
  void clearActive() {
    if (state.active == null &&
        !state.focused &&
        state.text.isEmpty &&
        state.domain == null) {
      return;
    }
    state = const MapSearchState();
  }
}

/// Per-visit search-mode state; autoDispose resets it when leaving `/map`,
/// matching the page's other providers (`mapQueryProvider` etc.). Kept alive
/// across overlay mount/unmount by the always-mounted bar watching it.
final mapSearchProvider =
    StateNotifierProvider.autoDispose<MapSearchNotifier, MapSearchState>((ref) {
      // Analytics is read INSIDE the callback, not here: the service depends
      // on a live Firebase app, so resolving it eagerly would make merely
      // constructing this provider throw in any test that hasn't overridden
      // it. Lazily, only a test that actually opens the search mode needs one.
      return MapSearchNotifier(
        onSearchOpened: () => unawaited(
          ref.read(unifiedAnalyticsProvider).trackMapSearchOpened(),
        ),
      );
    });
