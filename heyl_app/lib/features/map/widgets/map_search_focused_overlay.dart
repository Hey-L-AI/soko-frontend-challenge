import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../../core/theme/app_colors.dart';
import '../providers/map_search_provider.dart';
import 'map_canvas_shield.dart';
import 'map_domain_tags.dart';
import 'map_drawer_metrics.dart';

/// What a back press on the Map page should do (PROD-3496).
///
/// Both back paths — the `PopScope` (Android system back, in-app pops; web
/// browser-back never reaches it, see `_handleBack`'s known-limitation note)
/// and the repurposed `SokoBackButton` — route through this one rule so they
/// can never disagree: while the focused search mode is up, back closes the
/// MODE; only otherwise does it start the page-leave flow (`_requestLeave`,
/// with its divergence prompt + `_allowRoutePop` latch, which focused-mode
/// exits must never touch).
enum MapBackAction { exitFocusedSearch, leavePage }

/// See [MapBackAction].
MapBackAction resolveMapBackAction({required bool searchFocused}) =>
    searchFocused ? MapBackAction.exitFocusedSearch : MapBackAction.leavePage;

/// PROD-3524 — the `/map` query param that mirrors the focused search mode.
/// `/map?search=1` IS the focused mode as far as browser history is concerned.
const String mapSearchFocusQueryParam = 'search';

/// The value [mapSearchFocusQueryParam] carries when the mode is open.
const String mapSearchFocusQueryValue = '1';

/// Whether [uri] represents the focused search mode.
bool mapUriHasFocus(Uri uri) =>
    uri.queryParameters[mapSearchFocusQueryParam] == mapSearchFocusQueryValue;

/// Add/remove the focused-mode marker on [uri], preserving every other query
/// parameter (PROD-3524).
///
/// Preservation is not cosmetic: `/map` is a deep-link target (PROD-3326) and
/// arrives carrying attribution like `?utm_source=push&ref=...`. Rebuilding the
/// location as a bare `'/map?search=1'` would drop those for as long as the
/// mode is open, and anything reading `GoRouterState.of(context).uri` would see
/// an unattributed visit.
String mapUriWithFocus(Uri uri, {required bool focused}) {
  // `queryParametersAll`, not `queryParameters`: the latter collapses repeated
  // keys, so `/map?tag=a&tag=b` would come back with a single `tag`. The
  // fragment is carried through for the same reason -- this function must be a
  // faithful rewrite of the location with one parameter changed.
  final params = Map<String, List<String>>.from(uri.queryParametersAll);
  if (focused) {
    params[mapSearchFocusQueryParam] = const [mapSearchFocusQueryValue];
  } else {
    params.remove(mapSearchFocusQueryParam);
  }
  return Uri(
    path: uri.path.isEmpty ? '/map' : uri.path,
    queryParameters: params.isEmpty ? null : params,
    fragment: uri.fragment.isEmpty ? null : uri.fragment,
  ).toString();
}

/// What to do to reconcile the focused-mode state with the URL (PROD-3524).
enum MapFocusSync {
  /// They agree, or there is nothing trustworthy to act on yet.
  none,

  /// The mode opened: give it its own history entry so the browser's back
  /// button has something to pop.
  pushEntry,

  /// The mode closed from inside the app (back arrow, Esc, outside tap, or an
  /// executed search via `setActive`/`clearActive`): pop the entry we pushed.
  ///
  /// Deliberately a history POP, not a `go('/map')` -- go_router pushes a new
  /// browser entry for *every* navigation including `pop`, so navigating to
  /// the clean URL would strand a dead back press per open/close cycle. See
  /// `core/utils/web_history.dart`.
  popEntry,

  /// Same intent as [popEntry], but for a marker this screen does NOT own --
  /// a cold load or deep link that arrived already carrying `?search=1`.
  /// There is no entry of ours behind it, so walking history back would leave
  /// the page (or the app) instead of closing the mode. Swap the marker out of
  /// the current entry in place instead.
  replaceEntry,

  /// The URL moved under us (browser back) -- follow it by closing the mode.
  /// Writes no history.
  exitFocus,

  /// The URL moved under us (browser **forward**, or a cold load of
  /// `/map?search=1`) -- follow it by opening the mode. Writes no history.
  enterFocus,
}

/// The single reconcile rule for focused-mode <-> URL.
///
/// Everything is decided from five inputs so the whole state machine is
/// assertable without pumping the map:
///
/// - [enabled] -- the web + flag gate. The mirror is **web-only** so the
///   Android back path (`PopScope` -> [resolveMapBackAction]) stays
///   byte-identical.
/// - [focused] / [urlFocused] -- the two things that must agree.
/// - [lastUrlFocused] -- the URL as of the previous build. `null` means "first
///   build", where the URL is authoritative and we must never write history: a
///   cold load of `/map?search=1` has to OPEN the mode, and misreading it as a
///   state change would `history.back()` the user straight out of the app.
/// - [pendingUrlFocused] -- a URL write we issued that has not landed yet.
///   Until it does the URL is stale by definition, and reading it as a
///   user-driven signal is what would let a fast open-then-close strand
///   `?search=1` with the mode shut (and then reopen it on the next reconcile).
/// - [ownsEntry] -- see [resolveMapFocusEntryOwnership]. Decides whether
///   closing the mode may POP history or must REPLACE the current entry.
/// Whether the `?search=1` currently in the URL is an entry this screen may
/// close with a history POP (PROD-3524).
///
/// "Owned" means there is a marker-less `/map` entry immediately behind it,
/// which is true in exactly two cases: we pushed it, or the browser stepped
/// FORWARD onto it from our own `/map`. Both show up here identically -- as the
/// marker being watched to APPEAR while this screen was mounted.
///
/// The case that must not be mistaken for those is a cold load or deep link
/// straight to `/map?search=1`: the marker was already there on first sight, so
/// whatever sits behind it belongs to another page or another document.
/// `history.back()` there would walk out of the map entirely.
bool resolveMapFocusEntryOwnership({
  required bool urlFocused,
  required bool? lastUrlFocused,
  required bool currentlyOwned,
}) {
  if (!urlFocused) return false; // no marker in the URL -- nothing to own
  if (lastUrlFocused == null) return false; // already there on first sight
  if (!lastUrlFocused) return true; // we watched it appear
  return currentlyOwned;
}

MapFocusSync resolveMapFocusSync({
  required bool enabled,
  required bool focused,
  required bool urlFocused,
  required bool? lastUrlFocused,
  required bool? pendingUrlFocused,
  required bool ownsEntry,
}) {
  if (!enabled) return MapFocusSync.none;

  // Our own write is still in flight. Ignore the URL until it lands; once it
  // does, any remaining disagreement is the STATE having moved on since, so we
  // correct the URL rather than dragging the state backwards.
  if (pendingUrlFocused != null) {
    if (urlFocused != pendingUrlFocused) return MapFocusSync.none;
    if (focused == urlFocused) return MapFocusSync.none;
    if (focused) return MapFocusSync.pushEntry;
    return ownsEntry ? MapFocusSync.popEntry : MapFocusSync.replaceEntry;
  }

  if (focused == urlFocused) return MapFocusSync.none;

  // First build -- adopt the URL, never write history.
  if (lastUrlFocused == null) {
    return urlFocused ? MapFocusSync.enterFocus : MapFocusSync.exitFocus;
  }

  // The URL changed under us -> the browser moved (back/forward). Follow it.
  if (lastUrlFocused != urlFocused) {
    return urlFocused ? MapFocusSync.enterFocus : MapFocusSync.exitFocus;
  }

  // The URL held still, so the STATE moved -> write the URL.
  if (focused) return MapFocusSync.pushEntry;
  return ownsEntry ? MapFocusSync.popEntry : MapFocusSync.replaceEntry;
}

/// Whether tapping outside the search bar exits the focused mode. **Now always
/// true, on every platform** (PROD-3627).
///
/// This used to be desktop-only. A3 argued that on mobile the map is mostly
/// unreachable behind the dropdown + keyboard, so the back arrow should be the
/// only exit and a scrim tap must NOT dismiss.
///
/// **The premise expired, so Zé reversed it** (2026-08-03) — recorded as
/// umbrella **Decision #51**. The 0-char past-searches state doesn't fill the
/// screen, so there is plenty of reachable map, and people try to tap it away.
/// A3 was not wrong when written; the UI it described no longer exists.
///
/// Kept as a function rather than deleted so the reversal is greppable from the
/// call sites and the decision has somewhere to live. The [platform] argument is
/// now deliberately unused — that it no longer matters IS the change.
bool scrimTapExitsSearch({required TargetPlatform platform}) => true;

/// The desktop/mobile split [scrimTapExitsSearch] used to carry.
///
/// Still needed, because that predicate gated **two unrelated things**: whether
/// an outside tap dismisses (now universal) and whether the dropdown is capped
/// to 60 % of the box so some map stays visible behind it (A5 — the
/// click-to-exit affordance on desktop). Flipping the old shared predicate to
/// true would silently have applied that desktop cap to phones, shrinking the
/// suggestion list. Two meanings, two functions.
///
/// `defaultTargetPlatform` is the house mobile signal (PROD-2240): Flutter web
/// reports the OS via user-agent, so iOS/Android covers native AND mobile-web
/// with no `kIsWeb` special-casing.
bool mapSearchIsDesktop({required TargetPlatform platform}) =>
    platform != TargetPlatform.iOS && platform != TargetPlatform.android;

/// Max height for the focused-mode dropdown container.
///
/// [boxHeight] is the overlay's live box (from its `LayoutBuilder`). `/map`
/// renders under DiscoveryShell's Scaffold with `resizeToAvoidBottomInset`
/// on, so the box already shrinks frame-by-frame as the keyboard rises —
/// which is also why the dropdown is NOT separately animated (double-
/// animating the keyboard lags on iOS; same reasoning as the chat screen's
/// non-animated inset). [keyboardInset] is the residual
/// `MediaQuery.viewInsets.bottom` — normally 0 under that Scaffold regime,
/// subtracted belt-and-braces for inset-forwarding edge cases.
///
/// [capToDesktopFraction] (desktop, from [mapSearchIsDesktop] — this used to
/// share a predicate with [scrimTapExitsSearch], until PROD-3627 made that one
/// universal) caps the dropdown at 60% of the box so part of the map stays
/// visible — it is the click-to-exit affordance there (A5).
double focusedDropdownMaxHeight({
  required double boxHeight,
  required double topOffset,
  required double keyboardInset,
  required bool capToDesktopFraction,
}) {
  final available = boxHeight - topOffset - keyboardInset - 12;
  final capped = capToDesktopFraction
      ? math.min(available, boxHeight * 0.6)
      : available;
  return math.max(capped, 0);
}

/// Identifies the focused-mode scrim in widget tests (the tree has other
/// [ColoredBox]es, e.g. the framework's transparent overlay one).
const Key mapSearchScrimKey = Key('map-search-focused-scrim');

/// PROD-3652 — vertical space the domain tag row takes above the dropdown
/// panel: the row itself plus the gap below it.
///
/// The gap is [kMapDrawerFullTopMargin] for the same reason the panel already
/// used it below the search bar — this row now sits between them, and reusing
/// the constant keeps the two gaps identical rather than merely similar.
const double _tagRowSlot = MapDomainTagRow.height + kMapDrawerFullTopMargin;

/// PROD-3496 — the focused search mode's full-attention layer: input shield
/// over the Mapbox platform view, scrim dimming the whole page (map, drawer,
/// chips — the search-bar row is a separate Stack layer ABOVE this one), and
/// the dropdown container that tracks the keyboard.
///
/// The container is content-sized up to [focusedDropdownMaxHeight] and
/// scrolls internally beyond it (A6; rows are fixed-height by contract —
/// Decision #33). [dropdownContent] is the FE-2 (PROD-3497) slot; while it's
/// null (this ticket) no panel renders — focused mode is scrim + bar +
/// keyboard only.
class MapSearchFocusedOverlay extends ConsumerWidget {
  const MapSearchFocusedOverlay({super.key, this.dropdownContent});

  /// Suggestion-dropdown content (FE-2). Null = no panel.
  final Widget? dropdownContent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused = ref.watch(mapSearchProvider.select((s) => s.focused));
    final desktop = mapSearchIsDesktop(platform: defaultTargetPlatform);
    final tapExits = scrimTapExitsSearch(platform: defaultTargetPlatform);
    void exit() => ref.read(mapSearchProvider.notifier).exitFocus();

    return Focus(
      // Esc from anywhere inside the overlay subtree (the bar has its own
      // handler on the field's node — this one catches focus that FE-2
      // moves into the dropdown).
      onKeyEvent: (node, event) {
        if (focused &&
            event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          exit();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final content = dropdownContent;
          // Panel parks where the drawer's `full` stop does: just below the
          // back/search row.
          final panelTop =
              mapDrawerFullTopInset(context) + kMapDrawerFullTopMargin;
          return Stack(
            children: [
              // Web: block the Mapbox HTML platform view (a Flutter-side
              // scrim can't — G3). Mounted even while inactive so its
              // deactivation linger (touch-browser compatibility clicks)
              // can run after an exit. No-op on native.
              Positioned.fill(child: MapCanvasShield(active: focused)),
              if (focused)
                Positioned.fill(
                  child: GestureDetector(
                    // Opaque: the scrim absorbs every pointer so the map,
                    // drawer and chips beneath are inert on all platforms
                    // (A7) — which is also what makes the dismissing tap
                    // **consumed** rather than passed through. PROD-3627
                    // requires that a tap which dismisses does ONLY that: a
                    // pin, filter button or drawer control under the scrim
                    // needs a second tap to act. That falls out of the
                    // opaque scrim for free; nothing extra absorbs it.
                    behavior: HitTestBehavior.opaque,
                    onTap: tapExits ? exit : null,
                    child: ColoredBox(
                      key: mapSearchScrimKey,
                      // Placeholder dim per design tokens; final treatment
                      // arrives with the designer pass (Decision #4).
                      color: AppColors.sokoInk.withValues(alpha: 0.3),
                    ),
                  ),
                ),
              // PROD-3652 — the domain tag row, in the slot the shortcut chips
              // occupy when unfocused (`map_screen.dart` hides those while
              // focused, so the two never stack). ABOVE the scrim, so it stays
              // lit and interactive while the page dims; full width, because
              // "edge-to-edge" is the point — the panel below is inset 15 and
              // rounded-clipped, so a row inside it could not bleed off screen.
              if (focused)
                Positioned(
                  top: panelTop,
                  left: 0,
                  right: 0,
                  child: PointerInterceptor(child: MapDomainTagRow()),
                ),
              if (focused && content != null)
                Positioned(
                  top: panelTop + _tagRowSlot,
                  left: 15,
                  right: 15,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: focusedDropdownMaxHeight(
                          boxHeight: constraints.maxHeight,
                          // The SHIFTED top, not `panelTop` — the height budget
                          // has to lose exactly what the tag row took, or the
                          // panel overflows the box by that much with the
                          // keyboard up.
                          topOffset: panelTop + _tagRowSlot,
                          keyboardInset: MediaQuery.viewInsetsOf(
                            context,
                          ).bottom,
                          capToDesktopFraction: desktop,
                        ),
                      ),
                      child: Material(
                        elevation: 4,
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: SingleChildScrollView(
                          // Keep the keyboard up while browsing suggestions;
                          // dismissal is a deliberate gesture/back (G2).
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.manual,
                          child: SizedBox(
                            width: double.infinity,
                            child: content,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The mutable half of the focused-mode <-> URL mirror, kept together so the
/// whole thing can be advanced (and tested) as a pure state machine.
@immutable
class MapFocusUrlState {
  const MapFocusUrlState({
    this.lastUrlFocused,
    this.pendingUrlFocused,
    this.ownsEntry = false,
  });

  /// The marker's presence as of the previous observation. Null = never
  /// observed, i.e. the next observation is the first build.
  final bool? lastUrlFocused;

  /// A URL write issued but not yet observed landing. See [resolveMapFocusSync].
  final bool? pendingUrlFocused;

  /// Whether the marker currently in the URL is one we may close with a POP.
  /// See [resolveMapFocusEntryOwnership].
  final bool ownsEntry;

  @override
  bool operator ==(Object other) =>
      other is MapFocusUrlState &&
      other.lastUrlFocused == lastUrlFocused &&
      other.pendingUrlFocused == pendingUrlFocused &&
      other.ownsEntry == ownsEntry;

  @override
  int get hashCode => Object.hash(lastUrlFocused, pendingUrlFocused, ownsEntry);

  @override
  String toString() =>
      'MapFocusUrlState(last: $lastUrlFocused, pending: $pendingUrlFocused, '
      'owns: $ownsEntry)';
}

/// One observation of (state, URL) -> the action to take and the state to keep.
@immutable
class MapFocusUrlStep {
  const MapFocusUrlStep({required this.action, required this.next});

  final MapFocusSync action;
  final MapFocusUrlState next;
}

/// Advance the mirror by one build.
///
/// This exists as a single pure step, rather than as a handful of calls the
/// widget makes in the right order, because **the order is the whole bug
/// surface**. Ownership has to be recomputed from THIS observation before the
/// action is chosen: computing it afterwards means a push that lands after the
/// user already closed the mode is judged with stale ownership, so the entry
/// the app itself pushed gets replaced instead of popped, stranding a
/// duplicate `/map`. A test that hands [resolveMapFocusSync] an `ownsEntry`
/// directly cannot catch that; driving [stepMapFocusUrl] in sequence can.
MapFocusUrlStep stepMapFocusUrl({
  required MapFocusUrlState state,
  required bool enabled,
  required bool focused,
  required bool urlFocused,
}) {
  // While the mirror is off, do not even remember what the URL looked like.
  // `enabled` folds in the `map-search-v2` PostHog flag, which resolves
  // ASYNCHRONOUSLY — so a deep-linked `/map?search=1` can be observed for a few
  // builds before the gate opens. Advancing `lastUrlFocused` through those
  // would make the first enabled build see the marker as "held still" rather
  // than as a first sighting, and it would strip the deep link's focused mode
  // (`replaceEntry`) instead of adopting it (`enterFocus`).
  if (!enabled) {
    return MapFocusUrlStep(action: MapFocusSync.none, next: state);
  }

  // FIRST: does this observation change who owns the marker?
  final owns = resolveMapFocusEntryOwnership(
    urlFocused: urlFocused,
    lastUrlFocused: state.lastUrlFocused,
    currentlyOwned: state.ownsEntry,
  );

  final action = resolveMapFocusSync(
    enabled: enabled,
    focused: focused,
    urlFocused: urlFocused,
    lastUrlFocused: state.lastUrlFocused,
    pendingUrlFocused: state.pendingUrlFocused,
    ownsEntry: owns,
  );

  // A write we were waiting on has landed once the URL matches its intent.
  bool? pending = state.pendingUrlFocused;
  if (pending != null && urlFocused == pending) pending = null;
  switch (action) {
    case MapFocusSync.pushEntry:
      pending = true;
    case MapFocusSync.popEntry:
    case MapFocusSync.replaceEntry:
      pending = false;
    case MapFocusSync.none:
    case MapFocusSync.exitFocus:
    case MapFocusSync.enterFocus:
      break;
  }

  return MapFocusUrlStep(
    action: action,
    next: MapFocusUrlState(
      lastUrlFocused: urlFocused,
      pendingUrlFocused: pending,
      ownsEntry: owns,
    ),
  );
}
