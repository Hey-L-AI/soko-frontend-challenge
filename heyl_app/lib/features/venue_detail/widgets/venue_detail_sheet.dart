import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bottom_sheet/ds_draggable_sheet.dart';
import '../../lists/utils/zine_item_color.dart';
import '../providers/venue_detail_provider.dart';
import 'venue_detail_body.dart';

/// Opens the venue's **full detail** in the DS draggable sheet (mid-height,
/// snap to full), reusing [VenueDetailBody] — so the `view_item` analytics and
/// every interactive action fire exactly as on the full-screen route. Used by
/// the map pin tap; the `/venues/{id}` route stays for deep links/shares.
Future<void> showVenueDetailSheet(
  BuildContext context,
  WidgetRef ref, {
  required String venueId,
  String? listId,
  // PROD-3219: override the save button's `list_item_add` source (the Map page
  // passes ListSource.map). Null → default ListSource.detail.
  String? listAddSource,
}) {
  // Match the full-screen venue detail page: the same image-derived pastel
  // (never the old fixed Soko/Blue). Seeded with the sync fallback (colour
  // cache → id-keyed pastel); the content's [DetailBgColorSync] refines it to
  // the image palette once resolved.
  final backgroundColor = ValueNotifier<Color>(
    cachedZineItemColor(ref, venueId) ?? zineItemFallbackColor(venueId),
  );
  return showDsDraggableSheet<void>(
    context: context,
    ref: ref,
    backgroundColorListenable: backgroundColor,
    content: (_) => _VenueDetailSheetContent(
      venueId: venueId,
      listId: listId,
      listAddSource: listAddSource,
      backgroundColor: backgroundColor,
    ),
  ).whenComplete(backgroundColor.dispose);
}

/// Watches the venue detail provider and renders the resolved body (or a
/// loading / error state). Mirrors the in-list `_DetailBody` wrapper.
class _VenueDetailSheetContent extends ConsumerWidget {
  const _VenueDetailSheetContent({
    required this.venueId,
    required this.backgroundColor,
    this.listId,
    this.listAddSource,
  });

  final String venueId;
  final String? listId;
  final String? listAddSource;
  final ValueNotifier<Color> backgroundColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final async = ref.watch(
      venueDetailProvider(VenueDetailKey(venueId: venueId, listId: listId)),
    );
    final body = async.when(
      data: (snapshot) => VenueDetailBody(
        snapshot: snapshot,
        embedded: true,
        listAddSource: listAddSource,
        // Map pin-tap sheet: compact side-by-side header (small thumbnail
        // beside the name/tags/blurb) so the map stays visible behind it.
        compactHeader: true,
      ),
      loading: () => const _SheetLoading(),
      error: (err, _) => _SheetError(message: l10n.venueDetailErrorLoading),
    );
    // Recolour the sheet surface to the venue's image-derived pastel.
    return Stack(
      children: [
        body,
        DetailBgColorSync(
          isEvent: false,
          entityId: venueId,
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
