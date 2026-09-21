import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/social_proof.dart';
import '../../../data/models/user_list.dart' show ListSource;
import '../../../l10n/generated/l10n.dart';
import '../../../providers/lists_provider.dart' show isItemSavedProvider;
import '../../../shared/widgets/detail_action_button.dart';
import '../../../shared/utils/single_flight.dart';
import '../../../shared/widgets/soko_toggle_glyph.dart';
import '../../lists/widgets/add_to_list_sheet.dart';
import '../utils/venue_item_suggestion.dart';

/// Soko Save-to-list button. Two visual modes (auto-derived saved state from
/// `isItemSavedProvider` — fills whenever the venue is in any owned list). Both
/// use the Soko dark saved language: an ink outline bookmark at rest, and a
/// solid Soko Ink fill when saved/hovered — never a pink fill (a deliberate
/// divergence from design-system `4032:4009`; see design-decisions).
///   - **Circle** (`bare: false`, default) — the legacy 40 px chip on a neutral
///     Soko/Ink @ 6 % background in every state. This is the pre-signals row
///     (PROD-2939 flag off).
///   - **Bare cell** (`bare: true`) — a captioned 24 px glyph for the new
///     signals action row (Guarda).
///
/// Tap opens the existing `add_to_list_sheet` flow.
class SokoSaveButton extends ConsumerStatefulWidget {
  final VenueDetailResponse venue;

  /// Outer size of the circle chip (ignored in [bare] mode). Defaults to 40.
  final double size;

  /// Render as a captioned bare cell for the signals row instead of a circle.
  final bool bare;

  /// Optional override for the analytics origin (`ListSource`). Defaults to
  /// `ListSource.detail` (the venue detail page).
  final String? source;

  const SokoSaveButton({
    super.key,
    required this.venue,
    this.size = 40,
    this.bare = false,
    this.source,
  });

  @override
  ConsumerState<SokoSaveButton> createState() => _SokoSaveButtonState();
}

class _SokoSaveButtonState extends ConsumerState<SokoSaveButton> {
  bool _hovered = false;

  /// One save flow at a time. The drawer opens on the tap now, so the old
  /// window is gone — but a guest tap still awaits the auth gate, and a latch
  /// here is what stops that window growing a second drawer back.
  final SingleFlight _saveFlight = SingleFlight();

  void _onTap() {
    // PROD-3873 — quicksave on tap, then open the full drawer (detail always
    // opens full so the user can file into a zine or remove).
    _saveFlight.run(
      () => showAddToListSheet(
        context,
        venueAsItemSuggestion(widget.venue),
        ref: ref,
        source: widget.source ?? ListSource.detail,
        quickSaveIfUnsaved: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // PROD-2138: source of truth is "is the venue in any owned list".
    final isSaved = ref.watch(isItemSavedProvider)(
      venueId: widget.venue.id,
      googlePlaceId: widget.venue.googlePlaceId,
    );

    if (widget.bare) {
      // Saved → solid Soko Ink bookmark; the ink outline at rest. Matches the
      // card-overlay saved language.
      return DetailActionButton(
        label: isSaved
            ? Lt.of(context).detailActionSaved
            : Lt.of(context).detailActionSave,
        icon: SokoToggleGlyph.bookmarkAction(active: isSaved, height: 24),
        onTap: _onTap,
        // Same tap pop as the like/dislike thumbs beside it.
        popOnTap: true,
      );
    }

    // Neutral chip background in every state — the saved/hovered signal is the
    // reversed (ink-filled, paper-outlined) bookmark, not a pink fill. Diverges
    // from design-system 4032:4009 (pink Selected) for one dark saved language.
    final active = isSaved || _hovered;
    final button = Material(
      color: AppColors.sokoInk.withValues(alpha: 0.06),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _onTap,
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Center(
            child: SokoToggleGlyph.bookmarkChip(active: active, height: 14),
          ),
        ),
      ),
    );
    if (!kIsWeb) return button;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: button,
    );
  }
}
