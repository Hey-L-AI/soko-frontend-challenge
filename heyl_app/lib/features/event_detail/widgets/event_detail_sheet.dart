import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bottom_sheet/ds_draggable_sheet.dart';
import '../../lists/utils/zine_item_color.dart';
import '../providers/event_detail_provider.dart';
import 'event_detail_body.dart';

/// Opens the event's **full detail** in the DS draggable sheet (mid-height,
/// snap to full), reusing [EventDetailBody] — so the `view_item` analytics and
/// every interactive action fire exactly as on the full-screen route. Used by
/// the map pin tap; the `/events/{id}` route stays for deep links/shares.
///
/// Pass **exactly one** of:
///  - [eventId] — the resolved event id. The sheet renders straight away.
///  - [occurrenceId] — a map pin's event-occurrence id, when the caller doesn't
///    already know the event id. The sheet resolves it itself
///    ([eventIdForOccurrenceProvider]) behind its loading state.
///
/// PROD-2981: [occurrenceId] exists so a pin tap never waits on the network
/// before a sheet appears. The Map page used to `await` that resolution and
/// only then open the sheet, so a tap on an event pin bought a dimmed map and
/// nothing else for a whole round-trip — and people tapped again. The sheet is
/// the right owner of that wait: it can show the surface first and fill it in.
Future<void> showEventDetailSheet(
  BuildContext context,
  WidgetRef ref, {
  String? eventId,
  String? occurrenceId,
  String? listId,
  // PROD-3219: override the save button's `list_item_add` source (the Map page
  // passes ListSource.map). Null → default ListSource.detail.
  String? listAddSource,
}) {
  assert(
    (eventId == null) != (occurrenceId == null),
    'Pass exactly one of eventId / occurrenceId.',
  );
  // Match the full-screen event detail page: the same image-derived pastel
  // (never the old fixed Soko/Green). Seeded with the sync fallback keyed on
  // whichever id we have (an occurrence tap keys on the occurrence id until the
  // event resolves — an on-brand pastel, not green); the content's
  // [DetailBgColorSync] refines it to the image palette once the event lands.
  final seedId = eventId ?? occurrenceId!;
  final backgroundColor = ValueNotifier<Color>(
    cachedZineItemColor(ref, seedId) ?? zineItemFallbackColor(seedId),
  );
  return showDsDraggableSheet<void>(
    context: context,
    ref: ref,
    backgroundColorListenable: backgroundColor,
    content: (_) => eventId != null
        ? _EventDetailSheetContent(
            eventId: eventId,
            listId: listId,
            listAddSource: listAddSource,
            backgroundColor: backgroundColor,
          )
        : _EventOccurrenceSheetContent(
            occurrenceId: occurrenceId!,
            listId: listId,
            listAddSource: listAddSource,
            backgroundColor: backgroundColor,
          ),
  ).whenComplete(backgroundColor.dispose);
}

/// Resolves an occurrence id → event id, then hands off to
/// [_EventDetailSheetContent]. The two waits (resolve, then load the detail)
/// share one loading state, so the sheet reads as a single fill-in rather than
/// a spinner that flashes twice.
class _EventOccurrenceSheetContent extends ConsumerWidget {
  const _EventOccurrenceSheetContent({
    required this.occurrenceId,
    required this.backgroundColor,
    this.listId,
    this.listAddSource,
  });

  final String occurrenceId;
  final String? listId;
  final String? listAddSource;
  final ValueNotifier<Color> backgroundColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final async = ref.watch(eventIdForOccurrenceProvider(occurrenceId));
    return async.when(
      // A null id means the occurrence no longer pairs to an event (a stale
      // pin) — same dead end as a failed load, so the same error state.
      data: (eventId) => (eventId == null || eventId.isEmpty)
          ? _SheetError(message: l10n.eventDetailErrorLoading)
          : _EventDetailSheetContent(
              eventId: eventId,
              listId: listId,
              listAddSource: listAddSource,
              backgroundColor: backgroundColor,
            ),
      loading: () => const _SheetLoading(),
      error: (err, _) => _SheetError(message: l10n.eventDetailErrorLoading),
    );
  }
}

/// Watches the event detail provider and renders the resolved body (or a
/// loading / error state). Mirrors the in-list `_DetailBody` wrapper.
class _EventDetailSheetContent extends ConsumerWidget {
  const _EventDetailSheetContent({
    required this.eventId,
    required this.backgroundColor,
    this.listId,
    this.listAddSource,
  });

  final String eventId;
  final String? listId;
  final String? listAddSource;
  final ValueNotifier<Color> backgroundColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final async = ref.watch(
      eventDetailProvider(EventDetailKey(eventId: eventId, listId: listId)),
    );
    final body = async.when(
      data: (snapshot) => EventDetailBody(
        snapshot: snapshot,
        embedded: true,
        listAddSource: listAddSource,
        // Map pin-tap sheet: compact side-by-side header (small thumbnail
        // beside the title/tags/blurb) so the map stays visible behind it.
        compactHeader: true,
      ),
      loading: () => const _SheetLoading(),
      error: (err, _) => _SheetError(message: l10n.eventDetailErrorLoading),
    );
    // Recolour the sheet surface to the event's image-derived pastel.
    return Stack(
      children: [
        body,
        DetailBgColorSync(
          isEvent: true,
          entityId: eventId,
          target: backgroundColor,
        ),
      ],
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

class _SheetError extends StatelessWidget {
  const _SheetError({required this.message});

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
