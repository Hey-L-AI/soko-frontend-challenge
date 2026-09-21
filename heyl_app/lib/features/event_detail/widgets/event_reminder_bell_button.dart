import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/entity_signal.dart';
import '../../../data/models/event_reminder.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/notifications/notifications_provider.dart';
import '../../../shared/widgets/detail_action_button.dart';
import '../../../shared/widgets/press_pop.dart';
import '../../entity_signals/providers/signal_controller.dart';
import '../../feature_spotlight/widgets/spotlight_trigger.dart';
import '../providers/event_detail_provider.dart';
import '../providers/event_reminders_provider.dart';
import 'reminder_picker_sheet.dart';
import 'save_reminder_hint.dart';

/// PROD-3950 — lifted out of `event_detail_body.dart`, where it was private,
/// so the Daily Drop detail page can mount the *same* bell rather than a second
/// implementation of reminder state. Its behaviour is unchanged; the only edit
/// was making it public.
/// PROD-2511 reminder bell — the notifications affordance. Always shown; in the
/// reworked signals model reminders stay on this bell (the signal buttons sit
/// beside it in the same action row).
class EventReminderBellButton extends ConsumerStatefulWidget {
  final EventDetailSnapshot snapshot;

  /// When false the bell renders in a dimmed, inert state — used while the
  /// event detail is still hydrating (occurrences unknown), so the button holds
  /// its slot in the action row without being tappable or firing the
  /// reminder-hint / spotlight nudges. Defaults to true.
  final bool enabled;

  const EventReminderBellButton({
    super.key,
    required this.snapshot,
    this.enabled = true,
  });

  @override
  ConsumerState<EventReminderBellButton> createState() =>
      _EventReminderBellButtonState();
}

class _EventReminderBellButtonState
    extends ConsumerState<EventReminderBellButton> {
  @override
  void initState() {
    super.initState();
    if (widget.enabled) _hydrate();
  }

  @override
  void didUpdateWidget(EventReminderBellButton old) {
    super.didUpdateWidget(old);
    // Sibling swipe navigates with `context.replace`, which reuses this element
    // — so `initState` does NOT run again when the user swipes from event A to
    // event B. Without this, B keeps its taste-only seed, `hasGoing` stays at
    // its default, and the bell renders unlit for someone who does have a
    // reminder on B. Also (re)hydrate when the button flips from the disabled
    // hydrating state to enabled once the network detail resolves.
    final becameEnabled = widget.enabled && !old.enabled;
    if (widget.enabled &&
        (becameEnabled || old.snapshot.event.id != widget.snapshot.event.id)) {
      _hydrate();
    }
  }

  void _hydrate() {
    // PROD-4027 — this is the ONLY surface that reads an axis the feed's
    // `signals` map does not carry (`hasGoing`). An event arriving from the
    // Discovery feed has a controller seeded with sentiment only and no GET
    // was fired for it, so `marked_going_at` is at its default and the bell
    // would render unlit for someone who does have a reminder set.
    //
    // Hydration lives here, next to the read it protects, rather than on the
    // detail screen: the screen would instantiate the controller for every
    // visitor — including signed-out ones, whose thumbs are auth-gated out in
    // `signalThumbCells` precisely so no request fires for them.
    //
    // Post-frame because hydrating flips `loading`, and this widget already
    // watches the controller — writing to it during build would mark a
    // building widget dirty.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(
            signalControllerProvider((
              type: SignalEntityType.event,
              id: widget.snapshot.event.id,
            )).notifier,
          )
          .ensureHydrated();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final event = widget.snapshot.event;
    final now = DateTime.now();
    final upcoming =
        widget.snapshot.occurrences
            .where((o) => o.startAt.isAfter(now))
            .toList()
          ..sort((a, b) => a.startAt.compareTo(b.startAt));
    final upcomingIds = upcoming.map((o) => o.id).toSet();
    final list = ref.watch(eventReminderListProvider(event.id)).valueOrNull;
    final hasReminder =
        list?.items.any(
          (r) => r.isPending && upcomingIds.contains(r.eventOccurrenceId),
        ) ??
        false;

    // Reworked model (PROD-2929): reminders are the going driver — the backend
    // stamps `marked_going_at` on the first reminder and clears it when the last
    // pending one is deleted (reminders API, moving-tower spec). So the bell just
    // opens the picker and reflects `marked_going_at`; there is no separate
    // `going` chip action.
    final signalKey = (type: SignalEntityType.event, id: event.id);
    final lit = ref.watch(signalControllerProvider(signalKey)).signal.hasGoing;

    Future<void> openReminderPicker() async {
      // `upcoming` is guaranteed non-empty — the bell is not rendered on
      // past-only events (gated by `hasReminderSlot` at both call sites).
      if (!hasReminder) {
        final smallestPreset = ReminderOffset.presets.first.minutes;
        final hasHostable = upcoming.any(
          (o) => o.startAt.difference(now).inMinutes >= smallestPreset,
        );
        if (!hasHostable) {
          ref
              .read(notificationsProvider.notifier)
              .show(
                message: l10n.reminderPickerTooCloseToast,
                variant: SokoVariant.info,
              );
          return;
        }
      }
      final saved = await showReminderPickerSheet(
        context: context,
        eventId: event.id,
        upcomingOccurrences: upcoming,
      );
      if (saved == true) {
        ref.invalidate(eventReminderListProvider(event.id));
        // On the signals path the picker PUT `/events/{id}/reminders` (the
        // going writer) and seeded the controller from the response, so the
        // bell's `marked_going_at` is already fresh — no refetch needed here.
      }
    }

    // The picker is the single going writer. Its per-reminder writes drive
    // `marked_going_at`; the bell just reflects it.
    Future<void> onBellTap() => openReminderPicker();

    // Signals-row cell: pink fill + brown outline when lit (same filled
    // treatment as Save; colours baked into bell-filled.svg), thin brown
    // outline otherwise. Caption below.
    // Cross-fade the filled bell over the outline on `lit` change, so the going
    // colour washes in rather than snapping (matches the thumb fill).
    final Widget glyph = SizedBox(
      width: 30,
      height: 30,
      child: Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SvgPicture.asset(
                'assets/images/icons/detail/bell.svg',
                width: 26,
                height: 26,
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
                  width: 26,
                  height: 26,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // Hydrating shell: hold the slot but render dimmed + inert — no tap, no
    // reminder-hint / spotlight nudges on a button that can't act yet.
    if (!widget.enabled) {
      final caption = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          glyph,
          const SizedBox(height: 8),
          Text(
            l10n.detailActionRemind,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: DetailActionButton.captionStyle,
          ),
        ],
      );
      return Semantics(
        label: l10n.eventDetailReminderLabel,
        button: true,
        enabled: false,
        child: IgnorePointer(child: Opacity(opacity: 0.4, child: caption)),
      );
    }

    return Semantics(
      label: l10n.eventDetailReminderLabel,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        // A tap only opens the picker — no tap-pop (pop: false). The pop fires
        // on confirmation instead: PopOnActivate pops when `lit` (going) flips
        // on, together with the bell's fill cross-fade.
        child: PressPop(
          onTap: onBellTap,
          pop: false,
          child: PopOnActivate(
            active: lit,
            child: SaveReminderHint(
              eventId: event.id,
              // Only nudge when the reminder isn't already set.
              enabled: true,
              alreadyReminded: lit,
              onTap: onBellTap,
              child: SpotlightTrigger(
                featureId: 'reminders_v1',
                targetCornerRadius: 20,
                targetPadding: const EdgeInsets.all(4),
                gate: () => !lit,
                onCtaAction: onBellTap,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    glyph,
                    const SizedBox(height: 8),
                    Text(
                      l10n.detailActionRemind,
                      // Match DetailActionButton — wrap to 2 lines before
                      // truncating so long captions don't clip.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: DetailActionButton.captionStyle,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
