import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/chat_message.dart' show ItemSuggestion;
import '../../../data/models/entity_ref.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/detail_seed_provider.dart';
import '../../../shared/navigation/detail_siblings.dart';
import '../../../shared/widgets/bottom_sheet/ds_draggable_sheet.dart';
import '../../../shared/widgets/measure_size.dart';
import '../../event_detail/providers/event_detail_provider.dart';
import '../../event_detail/widgets/event_detail_body.dart';
import '../../lists/utils/zine_item_color.dart';
import '../../venue_detail/providers/venue_detail_provider.dart';
import '../../venue_detail/widgets/venue_detail_body.dart';

/// Cross-fade between two siblings' bodies when the user swipes the sheet.
/// This is the sheet's ONLY content animation (PROD-4438).
const Duration _kSiblingFade = Duration(milliseconds: 260);
const Curve _kSiblingFadeCurve = Curves.easeOutCubic;

/// Opens an item's **full detail** in the DS draggable sheet — the same sheet
/// the map pin-tap uses (`showVenueDetailSheet`/`showEventDetailSheet`) — but
/// keyed off a [DetailSiblings] collection so the user can **swipe left/right
/// between siblings inside the sheet** (chat: the message's card array; map: the
/// current results). Reuses [VenueDetailBody]/[EventDetailBody] with
/// `embedded: true, compactHeader: true`, so `view_item` analytics and every
/// interactive action fire exactly as on the full-screen route, once per item
/// as each body mounts.
///
/// Swipe is re-implemented here rather than via [SiblingSwipeNav]: that widget
/// navigates with `context.replace(route)`, which cannot work inside a modal
/// sheet — here we swap the rendered body by index instead (no route change).
///
/// The sheet surface recolours per item to the same **image-derived pastel**
/// the routed venue/event detail pages use (via [detailBgForEntity]), so an
/// item wears one consistent colour whether it's opened as a sheet here or as a
/// full page — replacing the old fixed `sokoVenue` blue ↔ `sokoEvent` green
/// split. A [DetailBgColorSync] inside the content drives the swap on each
/// swipe and as the async palette lands.
///
/// [onIndexChanged] fires with the new index on each swipe (not the initial
/// open) — the map uses it to mark each landed result "viewed". Chat passes
/// null. [listAddSource] overrides the save button's `list_item_add` source
/// (`ListSource.chat` / `ListSource.map`); null → default `ListSource.detail`.
Future<void> showItemDetailSheet(
  BuildContext context,
  WidgetRef ref, {
  required DetailSiblings siblings,
  String? listAddSource,
  ValueChanged<int>? onIndexChanged,
}) async {
  // Seed with the sync fallback (colour cache → id-keyed pastel) for the item
  // tapped open; the content's [DetailBgColorSync] refines it to the image
  // palette once resolved. Pure reads — safe outside a build.
  final current = siblings.current;
  final backgroundColor = ValueNotifier<Color>(
    cachedZineItemColor(ref, current.id) ?? zineItemFallbackColor(current.id),
  );
  // Sizes the sheet to hug its measured content (see `_fitToContent`).
  final sheetController = DraggableScrollableController();
  try {
    await showDsDraggableSheet<void>(
      context: context,
      ref: ref,
      controller: sheetController,
      // Open modest and let the content-fit grow it to hug the preview (a short
      // item shouldn't open with a tall empty band). No snap: the resting extent
      // is the measured fit, not a fixed stop.
      //
      // PROD-4438 — `maxSize` is back to the DS default. It was raised to 1.0
      // so the "See full detail" CTA could grow the sheet to full screen before
      // handing off to the route; that grow is gone (the sheet now closes and
      // the page replaces it), so the only thing 1.0 still did was let a drag
      // pull the sheet flush to the top edge with no inset.
      initialSize: 0.45,
      maxSize: 0.95,
      snap: false,
      backgroundColorListenable: backgroundColor,
      content: (_) => _SiblingDetailSheetContent(
        siblings: siblings,
        listAddSource: listAddSource,
        onIndexChanged: onIndexChanged,
        backgroundColor: backgroundColor,
        sheetController: sheetController,
      ),
    );
  } finally {
    backgroundColor.dispose();
    sheetController.dispose();
  }
}

/// Builds a [DetailSiblings] from a list of map/search [ItemSuggestion]s at the
/// tapped [index], **1:1** with the source list (no filtering) so the caller's
/// own index-aligned bookkeeping — the map's `markerIds` — stays aligned for
/// [showItemDetailSheet]'s `onIndexChanged`. Chat builds its own filtered
/// siblings in `PlaceCardsRow._siblingsForTap` and does not use this.
DetailSiblings detailSiblingsFromSuggestions(
  List<ItemSuggestion> items,
  int index,
) {
  final list = items.map((it) {
    final isEvent = it.type == 'event';
    // Mirror the map's own fallback to `id` when the typed id is absent
    // (map_results_grid.openMapResultDetail uses `eventId ?? id` / `venueId ?? id`).
    final id = (isEvent ? it.eventId : it.venueId) ?? it.id;
    return DetailSibling(
      type: isEvent ? DetailSiblingType.event : DetailSiblingType.place,
      id: id,
    );
  }).toList();
  return DetailSiblings(items: list, currentIndex: index);
}

/// Holds the current sibling index and swaps the rendered detail body on a
/// horizontal swipe. Lives inside the sheet's scroll view.
class _SiblingDetailSheetContent extends StatefulWidget {
  const _SiblingDetailSheetContent({
    required this.siblings,
    required this.backgroundColor,
    required this.sheetController,
    this.listAddSource,
    this.onIndexChanged,
  });

  final DetailSiblings siblings;
  final ValueNotifier<Color> backgroundColor;
  final DraggableScrollableController sheetController;
  final String? listAddSource;
  final ValueChanged<int>? onIndexChanged;

  @override
  State<_SiblingDetailSheetContent> createState() =>
      _SiblingDetailSheetContentState();
}

class _SiblingDetailSheetContentState
    extends State<_SiblingDetailSheetContent> {
  /// Minimum horizontal velocity (logical px / s) for a deliberate swipe —
  /// matches [SiblingSwipeNav] so the full-page and sheet gestures feel the same.
  static const double _velocityThreshold = 250;

  late int _index = widget.siblings.currentIndex;

  /// The last measured preview height we sized the sheet to — dedupes the
  /// [MeasureSize] callback so a fit fires once per distinct content height
  /// (initial open + each swipe), not on every post-frame.
  double? _lastFitHeight;

  void _go(int newIndex) {
    if (newIndex < 0 || newIndex >= widget.siblings.items.length) return;
    setState(() => _index = newIndex);
    _lastFitHeight = null; // re-fit the sheet to the new sibling's height
    // The surface recolour is driven reactively by [DetailBgColorSync] in
    // build (keyed on the new `_index`'s sibling) — no manual set here.
    widget.onIndexChanged?.call(_index);
  }

  /// Size the sheet to hug the preview content, so a short item doesn't open
  /// with a tall band of empty surface below it.
  void _fitToContent(double contentHeight) {
    if (!mounted) return;
    if (_lastFitHeight != null && (_lastFitHeight! - contentHeight).abs() < 1) {
      return;
    }
    _lastFitHeight = contentHeight;
    final controller = widget.sheetController;
    if (!controller.isAttached) return;
    final mq = MediaQuery.of(context);
    // Chrome the sheet adds around this content: 24 px drag handle + 24 px
    // bottom gap (both in DSDraggableSheet) + the bottom safe-area inset.
    final chrome = 24.0 + 24.0 + mq.padding.bottom;
    final target = ((contentHeight + chrome) / mq.size.height).clamp(
      0.25,
      0.95,
    );
    // Skip tiny corrections so we don't fight an in-progress drag.
    if ((controller.size - target).abs() < 0.02) return;
    controller.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// Close the sheet and let the routed detail page take its place
  /// (PROD-4438).
  ///
  /// **What this used to do, and why it doesn't any more.** The CTA grew the
  /// sheet to full height while the body cross-faded from the compact preview
  /// into the full detail, then pushed the real route underneath and popped the
  /// sheet — the idea being one continuous motion with no visible page swap. It
  /// did not read that way. Four animations ran on the same content (260 ms
  /// cross-fade, 300 ms grow, the route's own 350-460 ms push transition, and
  /// the Material sheet's 200 ms exit), and the last one fought the rest: the
  /// grown sheet was pixel-identical to the page beneath it, so popping slid
  /// the detail downward off the screen while a duplicate arrived underneath —
  /// on iOS in a perpendicular direction.
  ///
  /// So: no grow, no morph. Push the page, drop the sheet in the same frame.
  /// The sheet is a preview and the page is the full detail, so there is no
  /// duplicated content to give the swap away, and removing the route (rather
  /// than popping it) animates nothing — no 200 ms slide-down, and no flash of
  /// the chat or map behind, since the page is already mounted underneath.
  ///
  /// On iOS the router builds this route as a `CupertinoPage` (`_detailPage` in
  /// `app_router.dart`), so the page slides in right-to-left over the surface
  /// the sheet just left — the platform's own "opened a page" motion.
  /// Everywhere else `_detailPage` paints it opaque and in place, so the
  /// replacement is a clean cut, the same as every other detail push in the app.
  void _openFullPage() {
    final sibling = widget.siblings.items[_index];
    final path = sibling.type == DetailSiblingType.event
        ? '/events/${sibling.id}'
        : '/venues/${sibling.id}';

    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    final sheetRoute = ModalRoute.of(context);

    // Order matters: push FIRST so the page is mounted before the sheet goes,
    // otherwise removing the sheet uncovers the chat/map for a frame.
    router.push(path);
    if (sheetRoute != null && sheetRoute.isActive) {
      navigator.removeRoute(sheetRoute);
    } else {
      // The route already left the history (`removeRoute` would throw).
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.siblings.items;
    final sibling = items[_index];
    final body = _ItemDetailBody(
      // Keyed on the sibling id so a swipe drives the AnimatedSwitcher
      // cross-fade and re-watches the provider fresh.
      key: ValueKey('item_detail_${sibling.type}_${sibling.id}'),
      sibling: sibling,
      listAddSource: widget.listAddSource,
      onSeeFullDetail: _openFullPage,
      onContentHeight: _fitToContent,
    );

    // Cross-fade between siblings on a swipe. The
    // zero-size [DetailBgColorSync] rides alongside so the sheet surface tracks
    // the current sibling's image-derived pastel (recolouring on each swipe and
    // when the async palette resolves).
    final content = Stack(
      children: [
        AnimatedSwitcher(
          duration: _kSiblingFade,
          switchInCurve: _kSiblingFadeCurve,
          switchOutCurve: _kSiblingFadeCurve,
          // Top-aligned, not the default `Stack(alignment: center)`
          // (PROD-4438). Two siblings rarely measure the same height, and
          // centring them slid the outgoing hero, title and buttons vertically
          // against the incoming ones for the whole fade. Pinning the top edges
          // keeps the shared elements where they are.
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          ),
          child: body,
        ),
        DetailBgColorSync(
          isEvent: sibling.type == DetailSiblingType.event,
          entityId: sibling.id,
          target: widget.backgroundColor,
        ),
      ],
    );

    // Nothing to swipe between with a single item.
    if (items.length <= 1) return content;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Horizontal only — the sheet's vertical drag-resize/scroll wins the
      // vertical axis in the gesture arena, same as SiblingSwipeNav.
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v.abs() < _velocityThreshold) return;
        // Swipe left (negative) → next; swipe right (positive) → previous.
        _go(v < 0 ? _index + 1 : _index - 1);
      },
      child: content,
    );
  }
}

/// Watches the right detail provider for [sibling] and renders the embedded
/// body (or loading / error). Mirrors the private wrappers in
/// `venue_detail_sheet.dart` / `event_detail_sheet.dart`.
class _ItemDetailBody extends ConsumerWidget {
  const _ItemDetailBody({
    super.key,
    required this.sibling,
    this.listAddSource,
    this.onSeeFullDetail,
    this.onContentHeight,
  });

  final DetailSibling sibling;
  final String? listAddSource;

  /// Opens the routed full-detail page in place of the sheet. This body is
  /// ALWAYS the compact preview now (PROD-4438) — the sheet never morphs into
  /// the full detail, so `compactHeader` is unconditionally true below.
  final VoidCallback? onSeeFullDetail;

  /// Reports the laid-out height of the loaded body, so the host can size the
  /// sheet to hug it. Null → not measured (the map single sheet).
  final ValueChanged<double>? onContentHeight;

  /// Wrap the loaded body so its height is reported to [onContentHeight].
  Widget _measured(Widget child) {
    final cb = onContentHeight;
    if (cb == null) return child;
    return MeasureSize(onChange: (size) => cb(size.height), child: child);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    if (sibling.id.isEmpty) {
      return _SheetMessage(
        message: sibling.type == DetailSiblingType.event
            ? l10n.eventDetailErrorLoading
            : l10n.venueDetailErrorLoading,
      );
    }

    if (sibling.type == DetailSiblingType.event) {
      final async = ref.watch(
        eventDetailProvider(EventDetailKey(eventId: sibling.id)),
      );
      return async.when(
        data: (snapshot) => _measured(
          EventDetailBody(
            snapshot: snapshot,
            embedded: true,
            listAddSource: listAddSource,
            compactHeader: true,
            onSeeFullDetail: onSeeFullDetail,
          ),
        ),
        // PROD-4160-followup — paint the shell from the tapped-card seed while
        // the full event hydrates, instead of a spinner.
        loading: () {
          final seed = ref.detailSeed(EntityKind.event, sibling.id);
          if (seed == null) return const _SheetLoading();
          return _measured(
            EventDetailBody(
              snapshot: EventDetailSnapshot(
                event: seed.toEventDetail(),
                effectiveListId: null,
                isHydrating: true,
              ),
              embedded: true,
              listAddSource: listAddSource,
              compactHeader: true,
              onSeeFullDetail: onSeeFullDetail,
            ),
          );
        },
        error: (err, _) => _SheetMessage(message: l10n.eventDetailErrorLoading),
      );
    }

    final async = ref.watch(
      venueDetailProvider(VenueDetailKey(venueId: sibling.id)),
    );
    return async.when(
      data: (snapshot) => _measured(
        VenueDetailBody(
          snapshot: snapshot,
          embedded: true,
          listAddSource: listAddSource,
          compactHeader: true,
          onSeeFullDetail: onSeeFullDetail,
        ),
      ),
      // PROD-4160-followup — paint the shell from the tapped-card seed while
      // the full venue hydrates, instead of a spinner.
      loading: () {
        final seed = ref.detailSeed(EntityKind.venue, sibling.id);
        if (seed == null) return const _SheetLoading();
        return _measured(
          VenueDetailBody(
            snapshot: VenueDetailSnapshot(
              venue: seed.toVenueDetail(),
              effectiveListId: null,
            ),
            embedded: true,
            listAddSource: listAddSource,
            compactHeader: true,
            onSeeFullDetail: onSeeFullDetail,
          ),
        );
      },
      error: (err, _) => _SheetMessage(message: l10n.venueDetailErrorLoading),
    );
  }
}

class _SheetLoading extends StatelessWidget {
  const _SheetLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 80),
      child: Center(child: CircularProgressIndicator(color: AppColors.sokoInk)),
    );
  }
}

class _SheetMessage extends StatelessWidget {
  const _SheetMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 60),
      child: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.sokoInk, fontSize: 16),
        ),
      ),
    );
  }
}
