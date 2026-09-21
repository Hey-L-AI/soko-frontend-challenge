import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../lists/providers/unified_list_provider.dart';
import '../../moderation/content_blocked_handler.dart';
import 'discovery_shell.dart';

/// Pinned, route-aware page chrome (back arrow + optional list-name title)
/// rendered as a Stack overlay above the [DiscoveryShell] scrollable. It
/// stays mounted across in-shell navigation so the back arrow never
/// scrolls and there's no flicker when the user opens an in-list detail
/// from a list page (the chrome's render is identical for both routes
/// because they share a `listId`).
///
/// Routes:
///
/// - `/lists/<id>` (zine + list view) — back + list-name H1
/// - `/lists/<id>/venues/<vid>` and `/lists/<id>/events/<eid>` — back +
///   list-name H1 (same chrome content as the parent list)
/// - `/venues/<id>` and `/events/<id>` (standalone) — back arrow only
/// - everything else — no chrome (returns `SizedBox.shrink`)
///
/// The chrome wraps in [PageContent] so the centred 480 px column on
/// desktop applies — the back arrow lines up with the body content
/// instead of floating at the very left of the viewport.
///
/// **Route source: [DiscoveryShell]'s `_effectiveTopRoute`** — observer-first
/// with a `matchedLocation` fallback (PROD-2258), passed in via [routeName] /
/// [arguments] rather than read from `discoveryNavObserver` here. The observer
/// is authoritative for imperative `context.push` (which leaves
/// `matchedLocation` stale: `/lists/<id>` → `/lists/<id>/venues/<vid>` would
/// otherwise look like the parent list), but it can report `null` on cold-load
/// and during warm same-shell deep-link nav (a nameless transient route lands
/// on top) — cases where `matchedLocation` is correct. Resolving in the shell
/// keeps the chrome, nav-visibility, and page-bg in agreement.
class PinnedPageChrome extends ConsumerWidget {
  /// Effective top-route name + arguments resolved by [DiscoveryShell].
  final String? routeName;
  final Object? arguments;

  /// PROD-4160-followup — per-entity background override for standalone
  /// event/venue detail pages (the image-derived pastel from
  /// [standaloneDetailBgProvider]). Null on every other route, where the chrome
  /// keeps its route-derived colour ([_bgForChrome]). Resolved by the shell so
  /// the chrome and the full-bleed Scaffold bg can never diverge.
  final Color? backgroundOverride;

  const PinnedPageChrome({
    super.key,
    required this.routeName,
    required this.arguments,
    this.backgroundOverride,
  });

  /// Total reserved height of the chrome for the current top route,
  /// including the top safe-area inset. [DiscoveryShell] uses this to
  /// add an equivalent top padding on the scrollable content so body
  /// widgets don't disappear under the chrome.
  static double reservedHeight({
    required String? routeName,
    required double topInset,
  }) {
    final spec = _resolveSpec(routeName, null);
    if (spec == null) return 0;
    return topInset + spec.contentHeight;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _resolveSpec(routeName, arguments);
    if (spec == null) return const SizedBox.shrink();

    final bg = backgroundOverride ?? _bgForChrome(spec);
    final topInset = MediaQuery.of(context).padding.top;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: topInset + spec.contentHeight,
      child: Container(
        color: bg,
        padding: EdgeInsets.only(top: topInset),
        child: PageContent(
          child: SizedBox(
            width: double.infinity,
            height: spec.contentHeight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                15,
                0,
                15,
                spec.kind == _ChromeKind.standaloneVenue ||
                        spec.kind == _ChromeKind.standaloneEvent
                    ? 0
                    : _titleBottomGap,
              ),
              child: _ChromeRow(spec: spec),
            ),
          ),
        ),
      ),
    );
  }
}

/// Background color for the chrome — mirrors the body bg of the route
/// it's above so the chrome visually blends with the page (the same
/// effect we had pre-PROD-1738 when the title lived inside the
/// scrolling body and inherited the body's bg).
///
/// Mapping matches `_pageBgForRoute` in `discovery_shell.dart`:
///   - list page + in-list detail + add-items → Soko/Paper
///   - standalone venue → Soko/Blue (sokoVenue)
///   - standalone event → Soko/Lilac (sokoEvent)
Color _bgForChrome(_ChromeSpec spec) {
  switch (spec.kind) {
    case _ChromeKind.listPage:
    case _ChromeKind.inListDetail:
      return AppColors.sokoPaper;
    case _ChromeKind.standaloneVenue:
      // PROD-1852: add-items page uses standaloneVenue kind for back-only
      // chrome but carries a listId for the fallback → Paper bg to match
      // the page body (regular standalone venues have listId == null).
      return spec.listId != null ? AppColors.sokoPaper : AppColors.sokoVenue;
    case _ChromeKind.standaloneEvent:
      return AppColors.sokoEvent;
  }
}

class _ChromeRow extends ConsumerStatefulWidget {
  final _ChromeSpec spec;

  const _ChromeRow({required this.spec});

  @override
  ConsumerState<_ChromeRow> createState() => _ChromeRowState();
}

class _ChromeRowState extends ConsumerState<_ChromeRow> {
  /// Last list-name we successfully read from `unifiedListProvider`.
  /// Used to bridge the brief gap when the chrome's `spec.listId` flips to
  /// a different encoding for the same list (e.g. slug → UUID on Vê mais —
  /// the in-list detail route URL uses `list.id` while the parent list page
  /// URL uses `list.urlIdentifier`). `unifiedListProvider` is keyed by
  /// argument string, so the new key subscribes to a fresh provider that
  /// has to load before `.list?.name` is non-null. Without this cache the
  /// title flickers to empty for one frame on every Vê mais.
  String? _cachedTitle;

  /// Inline title editor wiring (PROD-1783) — created lazily when the
  /// list page enters edit mode and torn down on exit.
  TextEditingController? _titleController;
  FocusNode? _titleFocusNode;
  String? _lastCommittedTitle;

  static const TextStyle _titleStyle = TextStyle(
    fontFamily: 'SeasonMix',
    fontSize: 32,
    fontWeight: FontWeight.w300,
    height: 1.0,
    letterSpacing: -0.9,
    color: AppColors.sokoInk,
  );

  /// Same `_titleStyle` plus an underline — used in edit mode so the
  /// title reads as an editable affordance. PROD-1783.
  static const TextStyle _editableTitleStyle = TextStyle(
    fontFamily: 'SeasonMix',
    fontSize: 32,
    fontWeight: FontWeight.w300,
    height: 1.0,
    letterSpacing: -0.9,
    color: AppColors.sokoInk,
    decoration: TextDecoration.underline,
    decorationColor: AppColors.sokoInk,
    decorationThickness: 1.0,
  );

  @override
  void dispose() {
    _teardownEditor();
    super.dispose();
  }

  void _teardownEditor() {
    _titleFocusNode?.removeListener(_onTitleFocusChanged);
    _titleFocusNode?.dispose();
    _titleFocusNode = null;
    _titleController?.dispose();
    _titleController = null;
    _lastCommittedTitle = null;
  }

  void _setupEditor(String initialTitle) {
    _titleController = TextEditingController(text: initialTitle);
    _lastCommittedTitle = initialTitle.trim();
    _titleFocusNode = FocusNode()..addListener(_onTitleFocusChanged);
  }

  void _onTitleFocusChanged() {
    if (_titleFocusNode?.hasFocus ?? false) return;
    // ignore: discarded_futures
    _maybeCommitTitle();
  }

  Future<void> _maybeCommitTitle() async {
    final spec = widget.spec;
    final listId = spec.listId;
    if (listId == null) return;
    final text = _titleController?.text.trim() ?? '';
    if (text.isEmpty || text == _lastCommittedTitle) return;
    _lastCommittedTitle = text;
    try {
      final ok = await ref
          .read(unifiedListProvider(listId).notifier)
          .commitListUpdate(name: text);
      if (!ok && mounted) {
        showSoko(
          ref,
          message: Lt.of(context).errorUnknown,
          variant: SokoVariant.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      // PROD-2264 — wordlist filter rejection. Reset
      // [_lastCommittedTitle] so re-typing the same offending text
      // re-fires the save (otherwise the dedup above would swallow
      // the retry).
      _lastCommittedTitle = null;
      if (!handleContentBlocked(
        ref,
        context,
        e,
        field: ContentBlockedField.listName,
      )) {
        showSoko(
          ref,
          message: Lt.of(context).errorUnknown,
          variant: SokoVariant.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final freshTitle = spec.listId == null
        ? null
        : ref.watch(
            unifiedListProvider(spec.listId!).select((s) => s.list?.name),
          );
    final editMode = spec.kind == _ChromeKind.listPage && spec.listId != null
        ? ref.watch(unifiedListProvider(spec.listId!).select((s) => s.editMode))
        : false;
    if (freshTitle != null) {
      _cachedTitle = freshTitle;
    }
    final title = spec.listId == null ? null : (freshTitle ?? _cachedTitle);

    // Sync the editor controller with the live edit-mode state. Set up
    // on entry, tear down on exit, and reseed when the persisted title
    // changes (e.g. after a server-side update completes).
    if (editMode && _titleController == null) {
      _setupEditor(title ?? '');
    } else if (!editMode && _titleController != null) {
      // ignore: discarded_futures
      _maybeCommitTitle();
      _teardownEditor();
    } else if (editMode &&
        _titleController != null &&
        title != null &&
        title != _titleController!.text &&
        !(_titleFocusNode?.hasFocus ?? false)) {
      // External update (refresh from server) — replace the controller
      // text without clobbering an in-flight user edit.
      _titleController!.text = title;
      _lastCommittedTitle = title.trim();
    }

    // Row layout: back arrow on the left, optional title centred in
    // the middle, 32 px trailing spacer so the title centres visually
    // against the symmetric back-arrow width. Plain Row instead of
    // Stack+Align — much more predictable when the parent provides
    // bounded width + height (which the wrapping SizedBox does).
    //
    // `crossAxisAlignment.center` aligns the title's vertical midline
    // with the back arrow's so the two read as a single horizontal
    // line. Earlier iterations used `.end` to bottom-anchor the title
    // against the body's stats line, but the visual mismatch between
    // the 17 px arrow glyph and the ~32 px title made the title appear
    // to float above the arrow.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // PROD-1783: hide the back arrow on the list page while edit
        // mode is active. The only way out of edit mode is the Done
        // button in the trailing slot. The leading spacer matches the
        // trailing Done button's 40-px width so the centred title
        // stays geometrically symmetric.
        if (editMode)
          const SizedBox(width: 40, height: 40)
        else
          // PROD-4086 — the design-system back button, not a hand-rolled copy
          // of it. `bare` at its default 48 is exactly what this used to
          // inline: the same `kSokoArrowGlyph` at 22×17 in `sokoInk`, centred
          // in a 48×48 Material hit target (the glyph reads compact while the
          // invisible tap area fills the cell, so a fingertip landing beside
          // the arrow still counts). Sharing it means the arrow art and the
          // tap chrome have one definition across both pinned headers.
          //
          // `onTap` is passed because this chrome's fallback is richer than
          // `SokoBackButton`'s pop-or-go-`/`: an in-list detail falls back to
          // its parent list. That is exactly what the parameter is for.
          SokoBackButton(
            variant: SokoBackButtonVariant.bare,
            onTap: () => _back(context, spec),
          ),
        // Title slot. Always Expanded (so the trailing spacer balances
        // the back-arrow width); empty when the list isn't list-aware
        // or the list name hasn't loaded yet — `unifiedListProvider`'s
        // `s.list?.name` is null while loading.
        //
        // `Align(center)` so the title centres inside the Expanded
        // slot both horizontally and vertically. The Row's
        // `crossAxisAlignment.center` alone wouldn't do it — `Expanded`
        // always fills the row's cross-axis height, so the alignment of
        // the *inner* widget is what positions the text vertically.
        Expanded(
          child: Align(
            alignment: Alignment.center,
            child: editMode && _titleController != null
                ? TextField(
                    controller: _titleController,
                    focusNode: _titleFocusNode,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    // PROD-1805: match the create flow's 72-char cap so
                    // edits can't push titles longer than what's allowed
                    // at creation. 72 = length of the worst-case sample
                    // that still reads cleanly across the chrome's 2-line
                    // slot. `counterText: ''` hides the default "n/72"
                    // counter — the chrome has no room for it.
                    maxLength: 72,
                    maxLengthEnforcement: MaxLengthEnforcement.enforced,
                    style: _editableTitleStyle,
                    // `filled: false` + transparent fillColor explicitly
                    // override the global InputDecorationTheme's white
                    // fill — without these the chrome bg leaks behind a
                    // light surface rectangle that breaks the page tint.
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: false,
                      fillColor: Colors.transparent,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      counterText: '',
                    ),
                    onSubmitted: (_) => _maybeCommitTitle(),
                  )
                : (title == null
                      ? const SizedBox.shrink()
                      // PROD-1805: AutoSizeText scales the title from the
                      // 32 px default down to a 18 px floor. On the Zine
                      // detail page (`listPage`) we allow wrapping to 2
                      // lines so long titles read more comfortably — short
                      // titles still stay 1 line at 32 px, and wrapping
                      // only kicks in when the text can't fit at the max
                      // size. 2 lines × 32 px = 64 px fits inside the row's
                      // 71 px slot (`_withTitleContentHeight` 81 −
                      // `_titleBottomGap` 10). In-list detail headers keep
                      // `maxLines: 1` so the parent-list breadcrumb stays
                      // compact. `stepGranularity: 1` because AutoSizeText
                      // asserts on fractional sizes (same constraint as
                      // `list_zine_cover.dart`).
                      : AutoSizeText(
                          title,
                          textAlign: TextAlign.center,
                          maxLines: spec.kind == _ChromeKind.listPage ? 2 : 1,
                          minFontSize: 18,
                          maxFontSize: 32,
                          stepGranularity: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _titleStyle,
                        )),
          ),
        ),
        // Trailing slot. In edit mode (PROD-1783) hosts the Done
        // button so it stays pinned at the top of the viewport even
        // while the user scrolls through the editable list body.
        // Outside edit mode it's just a 48 × 48 symmetry spacer that
        // matches the back-arrow's hit target so the centred title
        // stays geometrically aligned. The reminder bell moved to the
        // event body's inline-action cluster (see
        // `_ReminderBellButton` in `event_detail_body.dart`) so it
        // surfaces on both standalone and in-list event detail.
        if (editMode && spec.listId != null)
          _DoneButton(listId: spec.listId!)
        else
          const SizedBox(width: 48, height: 48),
      ],
    );
  }

  void _back(BuildContext context, _ChromeSpec spec) {
    // Shared with [DiscoveryShell._onLeftEdgeSwipe] via [popOrFallback]
    // so the chrome's back-button and the edge-swipe-back gesture apply
    // the same fallback policy on cold-load deep-links. In-list detail
    // and add-items fall back to the parent list page; the list page
    // itself and standalone detail pages fall back to `/`. See
    // [popOrFallback] in `discovery_shell.dart`.
    popOrFallback(
      context,
      parentListId: spec.kind != _ChromeKind.listPage ? spec.listId : null,
    );
  }
}

enum _ChromeKind { listPage, inListDetail, standaloneVenue, standaloneEvent }

class _ChromeSpec {
  final _ChromeKind kind;
  final String? listId;
  final double contentHeight;

  const _ChromeSpec({
    required this.kind,
    this.listId,
    required this.contentHeight,
  });
}

/// Total content height (excludes top safe-area inset) for each chrome
/// variant.
///   - back-only: ~60 px — the 32 px back-arrow hit target sits roughly
///     centered, with a small breathing strip below before the body's
///     own 20 px gap and first content. Visually matches the legacy
///     71 px topPad of the standalone detail body.
///   - with title: ~81 px — sized so the 32 px title sits at the
///     bottom of the chrome with a fixed 10 px gap below (the rest
///     above the title), giving the body's stats line a 10 px
///     distance to the title.
const double _backOnlyContentHeight = 60;
const double _withTitleContentHeight = 81;

/// Vertical inset between the title baseline and the chrome's bottom
/// edge. Drives the visual gap between the H1 list name and the
/// body's stats / "by [user]" line.
const double _titleBottomGap = 10;

/// Map the topmost-route name + arguments (from `discoveryNavObserver`)
/// to a chrome spec. Returns `null` when the route shouldn't render
/// chrome (Discovery, hub, auth flows, etc.).
_ChromeSpec? _resolveSpec(String? routeName, Object? arguments) {
  if (routeName == null) return null;
  switch (routeName) {
    case listDetailPageName:
      return _ChromeSpec(
        kind: _ChromeKind.listPage,
        listId: arguments is String ? arguments : null,
        contentHeight: _withTitleContentHeight,
      );
    case inListVenueDetailPageName:
    case inListEventDetailPageName:
      return _ChromeSpec(
        kind: _ChromeKind.inListDetail,
        listId: arguments is String ? arguments : null,
        contentHeight: _withTitleContentHeight,
      );
    case standaloneVenueDetailPageName:
      return const _ChromeSpec(
        kind: _ChromeKind.standaloneVenue,
        contentHeight: _backOnlyContentHeight,
      );
    // PROD-2908 — daily-drop detail reuses the standalone detail chrome:
    // back-only arrow over the entity surface. PROD-3950 — which surface is
    // no longer fixed: every ready drop now opens this page, so an event drop
    // must get sokoEvent (green) chrome, not the venue blue this used to
    // hardcode. The route stashes the drop's `item_type` in `Page.arguments`
    // precisely so this (and `_pageBgForRoute`, the OTHER hardcoded site)
    // can resolve it without `matchedLocation` — see `daily_drop_detail_screen`
    // for why the two must agree.
    case dailyDropDetailPageName:
      return _ChromeSpec(
        kind: dailyDropChromeIsEvent(arguments)
            ? _ChromeKind.standaloneEvent
            : _ChromeKind.standaloneVenue,
        contentHeight: _backOnlyContentHeight,
      );
    case standaloneEventDetailPageName:
      return const _ChromeSpec(
        kind: _ChromeKind.standaloneEvent,
        contentHeight: _backOnlyContentHeight,
      );
    default:
      return null;
  }
}

/// Done button rendered in the chrome's trailing slot while the list
/// page is in PROD-1783 edit mode. 40×40 circular Soko/Ink @ 6 % to
/// match the action-row chrome buttons. Tapping it unfocuses the
/// currently-focused TextField first — that triggers the
/// auto-save-on-blur handlers in the title / description / note
/// editors so any in-flight draft commits via `commitListUpdate` /
/// `updateItemTip` — and then exits edit mode on the notifier.
///
/// While any mutation is still in flight (`state.pendingMutations > 0`)
/// the check icon is replaced by a 14-px spinner and taps are no-ops,
/// so the user can't exit edit mode and miss a save failure.
class _DoneButton extends ConsumerWidget {
  final String listId;

  const _DoneButton({required this.listId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPending = ref.watch(
      unifiedListProvider(listId).select((s) => s.pendingMutations > 0),
    );
    return GestureDetector(
      onTap: isPending
          ? null
          : () {
              // Flush any focused TextField's pending draft first.
              FocusManager.instance.primaryFocus?.unfocus();
              ref.read(unifiedListProvider(listId).notifier).exitEditMode();
            },
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: isPending ? SystemMouseCursors.wait : SystemMouseCursors.click,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.sokoInk.withValues(alpha: 0.06),
          ),
          child: Center(
            child: isPending
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.sokoInk,
                    ),
                  )
                : const Icon(
                    LucideIcons.check,
                    size: 14,
                    color: AppColors.sokoInk,
                  ),
          ),
        ),
      ),
    );
  }
}
