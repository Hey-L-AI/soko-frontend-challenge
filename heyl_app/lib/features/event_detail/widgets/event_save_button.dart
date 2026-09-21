import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/event_occurrence.dart';
import '../../../data/models/social_proof.dart';
import '../../../data/models/user_list.dart' show ListSource;
import '../../../l10n/generated/l10n.dart';
import '../../../providers/lists_provider.dart' show isItemSavedProvider;
import '../../../shared/widgets/detail_action_button.dart';
import '../../../shared/utils/single_flight.dart';
import '../../../shared/widgets/soko_toggle_glyph.dart';
import '../../lists/widgets/add_to_list_sheet.dart';
import '../utils/event_item_suggestion.dart';

/// Soko Save-to-list button — event variant. Two visual modes (see the venue
/// [SokoSaveButton]): the legacy 40 px circle chip (`bare: false`, default) and
/// the captioned bare cell for the new signals row (`bare: true`).
class EventSaveButton extends ConsumerStatefulWidget {
  final EventDetailResponse2 event;
  final List<EventOccurrence> occurrences;

  /// Outer size of the circle chip (ignored in [bare] mode). Defaults to 40.
  final double size;

  /// Render as a captioned bare cell for the signals row instead of a circle.
  final bool bare;

  /// Optional override for the analytics origin (`ListSource`). Defaults to
  /// `ListSource.detail`.
  final String? source;

  /// PROD-3116 — when set, this button saves a single occurrence of the event
  /// (the occurrence-row trailing chip). We don't yet track per-occurrence
  /// saved state, so the occurrence variant always renders the "add" affordance
  /// (outline bookmark) rather than binding to the event-level saved state,
  /// which would misleadingly show as saved.
  final String? eventOccurrenceId;

  const EventSaveButton({
    super.key,
    required this.event,
    this.occurrences = const [],
    this.size = 40,
    this.bare = false,
    this.source,
    this.eventOccurrenceId,
  });

  @override
  ConsumerState<EventSaveButton> createState() => _EventSaveButtonState();
}

class _EventSaveButtonState extends ConsumerState<EventSaveButton> {
  bool _hovered = false;

  /// One save flow at a time. The drawer opens on the tap now, so the old
  /// window is gone — but a guest tap still awaits the auth gate, and a latch
  /// here is what stops that window growing a second drawer back.
  final SingleFlight _saveFlight = SingleFlight();

  void _onTap() {
    // PROD-3873 — quicksave on tap, then open the full drawer (detail always
    // opens full).
    _saveFlight.run(
      () => showAddToListSheet(
        context,
        eventAsItemSuggestion(widget.event, occurrences: widget.occurrences),
        ref: ref,
        source: widget.source ?? ListSource.detail,
        eventOccurrenceId: widget.eventOccurrenceId,
        quickSaveIfUnsaved: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // PROD-2138: source of truth is "is the event in any owned list" rather
    // than the legacy `/me/saved` cache. `isItemSavedProvider` watches
    // `listsProvider`, so add/remove via `add_to_list_sheet` flips the icon
    // on the same frame the optimistic update lands.
    // Occurrence-scoped chips have no per-occurrence saved state yet, so they
    // never render as "saved" (PROD-3116) — only the whole-event button binds
    // to the event-level saved signal.
    final isSaved =
        widget.eventOccurrenceId == null &&
        ref.watch(isItemSavedProvider)(eventId: widget.event.id);

    if (widget.bare) {
      // Saved → solid Soko Ink bookmark; the ink outline at rest. Matches the
      // card-overlay saved language.
      return DetailActionButton(
        // Events use an RSVP framing instead of "Save" (PROD-3873 follow-up).
        // The label stays "Want to go" in both states — the filled icon signals
        // it's marked, without implying a commitment ("Going") the user might
        // feel bad about not keeping.
        label: Lt.of(context).eventDetailActionWantToGo,
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
