import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/entity_signal.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/notifications/notifications_provider.dart';
import '../../../shared/widgets/press_pop.dart';
import '../../entity_signals/providers/signal_controller.dart';
import '../../event_detail/providers/event_detail_provider.dart';
import '../../event_detail/providers/event_reminders_provider.dart';
import '../../event_detail/widgets/reminder_picker_sheet.dart';

/// Contextual reminder bell shown in the non-owner zine header action row,
/// but only while the foregrounded pager page is an **upcoming event**
/// (see `currentZinePageItemProvider` + the visibility gate in
/// `list_page_header.dart`). Tapping it opens the shared event
/// [showReminderPickerSheet] so the viewer can set a reminder for that event —
/// reusing the same reminder stack as the event-detail bell rather than
/// re-implementing it.
///
/// Visual matches the sibling 40 px Soko/Shade5 header chrome
/// (`_HeaderActionButton`), with the bell glyph filling in when the viewer is
/// "going" (has a pending reminder), mirroring the event-detail bell's
/// outline→filled cross-fade.
class ZineReminderBellButton extends ConsumerStatefulWidget {
  /// The current zine page's event item. Caller guarantees this is an event
  /// with an [UserListItem.eventId] and an upcoming [UserListItem.eventDate].
  final UserListItem item;

  const ZineReminderBellButton({super.key, required this.item});

  @override
  ConsumerState<ZineReminderBellButton> createState() =>
      _ZineReminderBellButtonState();
}

class _ZineReminderBellButtonState
    extends ConsumerState<ZineReminderBellButton> {
  @override
  void initState() {
    super.initState();
    _hydrate();
  }

  @override
  void didUpdateWidget(ZineReminderBellButton old) {
    super.didUpdateWidget(old);
    // Paging from event A to event B reuses this element, so `initState` does
    // not run again — re-hydrate on id change so the lit state tracks the new
    // event (mirrors EventReminderBellButton.didUpdateWidget).
    if (old.item.eventId != widget.item.eventId) _hydrate();
  }

  void _hydrate() {
    final eventId = widget.item.eventId;
    if (eventId == null) return;
    // Post-frame: hydrating flips loading state on a provider this widget
    // watches; writing during build would mark a building widget dirty.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(
            signalControllerProvider((
              type: SignalEntityType.event,
              id: eventId,
            )).notifier,
          )
          .ensureHydrated();
    });
  }

  Future<void> _onTap() async {
    final eventId = widget.item.eventId;
    if (eventId == null) return;
    final l10n = Lt.of(context);

    // The zine item carries only a single `eventDate`, but the picker needs
    // the full upcoming-occurrence set. Fetch the event detail on demand (only
    // on tap — no per-page network fan-out) to resolve occurrences.
    List<EventOccurrence> upcoming;
    try {
      final snapshot = await ref.read(
        eventDetailProvider(EventDetailKey(eventId: eventId)).future,
      );
      final now = DateTime.now();
      upcoming =
          snapshot.occurrences.where((o) => o.startAt.isAfter(now)).toList()
            ..sort((a, b) => a.startAt.compareTo(b.startAt));
    } catch (_) {
      upcoming = const [];
    }
    if (!mounted) return;

    if (upcoming.isEmpty) {
      ref
          .read(notificationsProvider.notifier)
          .show(
            message: l10n.reminderPickerTooCloseToast,
            variant: SokoVariant.info,
          );
      return;
    }

    final saved = await showReminderPickerSheet(
      context: context,
      eventId: eventId,
      upcomingOccurrences: upcoming,
    );
    if (saved == true) {
      ref.invalidate(eventReminderListProvider(eventId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final eventId = widget.item.eventId;
    final lit = eventId == null
        ? false
        : ref
              .watch(
                signalControllerProvider((
                  type: SignalEntityType.event,
                  id: eventId,
                )),
              )
              .signal
              .hasGoing;

    return Semantics(
      label: l10n.eventDetailReminderLabel,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: PressPop(
          onTap: _onTap,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.sokoShade5,
            ),
            child: SizedBox(
              width: 16,
              height: 16,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SvgPicture.asset(
                    'assets/images/icons/detail/bell.svg',
                    width: 16,
                    height: 16,
                    colorFilter: const ColorFilter.mode(
                      AppColors.sokoInk,
                      BlendMode.srcIn,
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: lit ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    child: SvgPicture.asset(
                      'assets/images/icons/detail/bell-filled.svg',
                      width: 16,
                      height: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
