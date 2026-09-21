import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/event_when_formatter.dart';
import '../../../core/utils/reminder_offset_label.dart';
import '../../../data/models/event_reminder.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/notifications/notifications_provider.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../event_detail/providers/event_reminders_provider.dart';
import '../providers/my_events_with_reminders_provider.dart';

/// Modal "My reminders" bottom sheet — one row per distinct event the
/// current user has pending reminders on. Tapping a row pushes the
/// event detail screen **above** the sheet so the user can manage
/// reminders from there and return to their reading position on the
/// list with a single back tap. The sheet stays mounted under the push
/// for the round-trip; on return, the row's `próximo` / count is
/// refreshed via `ref.invalidate(myEventsWithRemindersProvider)` so any
/// reminders the user added or removed are reflected without closing
/// and reopening.
///
/// Use [showMyRemindersSheet] from any chrome that wants to expose
/// the inbox (Discovery `DiscoveryEndActions`, Yours `CityActionBar`,
/// chat bar via `MyRemindersButton`).
Future<void> showMyRemindersSheet(BuildContext context, {String? surface}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // Sit on the shell navigator (same as `/events/:eventId`) so a
    // `context.push('/events/<id>')` from inside the sheet stacks the
    // event detail **above** the modal — back-tap pops back to the
    // sheet at the prior scroll position. Using the root navigator
    // here would land the shell-nested destination *underneath* the
    // modal (sheet covers the event detail). See
    // `docs/learnings/modal-survives-route-push-only-on-same-navigator.md`.
    useRootNavigator: false,
    builder: (sheetContext) => MyRemindersSheet(surface: surface),
  );
}

class MyRemindersSheet extends ConsumerStatefulWidget {
  final String? surface;
  const MyRemindersSheet({super.key, this.surface});

  @override
  ConsumerState<MyRemindersSheet> createState() => _MyRemindersSheetState();
}

class _MyRemindersSheetState extends ConsumerState<MyRemindersSheet> {
  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return DSSheetShell(
      header: _Header(title: l10n.myRemindersSheetTitle),
      body: MyRemindersListBody(surface: widget.surface),
    );
  }
}

/// The reminders list itself — loading / error / empty / one card per event.
/// Hosted by [MyRemindersSheet] (modal) and embedded directly as the
/// "Reminders" tab of the notifications inbox.
class MyRemindersListBody extends ConsumerStatefulWidget {
  final String? surface;

  /// True when hosted in the modal sheet: tapping an event pops the sheet
  /// before pushing the event page. False when embedded full-screen (the
  /// notifications inbox) — there's no modal to dismiss, just push.
  final bool popOnOpenEvent;

  /// Sheet hosting needs `shrinkWrap` (see comment at the ListView);
  /// full-screen hosting wants a normal expanding list.
  final bool shrinkWrap;

  const MyRemindersListBody({
    super.key,
    this.surface,
    this.popOnOpenEvent = true,
    this.shrinkWrap = true,
  });

  @override
  ConsumerState<MyRemindersListBody> createState() =>
      _MyRemindersListBodyState();
}

class _MyRemindersListBodyState extends ConsumerState<MyRemindersListBody> {
  // Fires `my_reminders_open` once per mount, gated on first
  // successful data load so the event carries the real `reminder_count`.
  bool _didTrackOpen = false;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final asyncEvents = ref.watch(myEventsWithRemindersProvider);

    return asyncEvents.when(
      loading: () => const _LoadingBody(),
      error: (_, __) => _ErrorBody(
        onRetry: () => ref.invalidate(myEventsWithRemindersProvider),
      ),
      data: (events) {
        if (!_didTrackOpen) {
          _didTrackOpen = true;
          ref
              .read(unifiedAnalyticsProvider)
              .trackMyRemindersOpen(
                reminderCount: events.items.length,
                surface: widget.surface,
              );
        }
        if (events.items.isEmpty) {
          return _EmptyBody(text: l10n.myRemindersSheetEmpty);
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          // `shrinkWrap: true` is load-bearing when this sits in the sheet
          // on the shell navigator (per the sheet-survives-event-push
          // contract on `useRootNavigator: false`). The shell's body
          // doesn't apply the same bottom-nav inset the root overlay
          // would, so an unbounded list would expand to ~100 % of the
          // visible body. Sizing to content keeps the sheet at the
          // natural bottom-anchored height for small lists; long
          // lists still scroll inside `DSSheetShell`'s 92 %-viewport
          // `ConstrainedBox` cap.
          shrinkWrap: widget.shrinkWrap,
          itemCount: events.items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final event = events.items[index];
            return _RemindersEventRow(
              event: event,
              popOnOpen: widget.popOnOpenEvent,
            );
          },
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  const _Header({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 12, 12),
      child: Row(
        children: [
          const Icon(LucideIcons.bell, color: AppColors.sokoInk, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.x, color: AppColors.sokoInk, size: 20),
            // Pop the closest navigator (the shell that hosts this
            // sheet, per `useRootNavigator: false`). Using
            // `rootNavigator: true` would try to pop the root and
            // navigate away from the app surface.
            onPressed: () => Navigator.of(context).pop(),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          ),
        ],
      ),
    );
  }
}

class _LoadingBody extends StatelessWidget {
  const _LoadingBody();

  @override
  Widget build(BuildContext context) {
    // Must be content-sized like `_ErrorBody` / `_EmptyBody`. A `Center`
    // here would expand to fill `DSSheetShell`'s `Flexible(fit: loose)`
    // slot under loose constraints, blowing the loading-frame sheet up
    // to ~92 % of viewport and flashing on entry before the data state
    // shrinks it to its natural content height.
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(AppColors.sokoInk),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorBody({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.myRemindersSheetError,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.sokoShade3,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onRetry,
            child: Text(l10n.myRemindersSheetRetry),
          ),
        ],
      ),
    );
  }
}

class _EmptyBody extends StatelessWidget {
  final String text;
  const _EmptyBody({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.bell, color: AppColors.sokoShade3, size: 32),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.sokoShade3,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _RemindersEventRow extends ConsumerStatefulWidget {
  final EventReminderEventCard event;

  /// Whether opening the event must first pop the hosting modal sheet.
  final bool popOnOpen;
  const _RemindersEventRow({required this.event, this.popOnOpen = true});

  @override
  ConsumerState<_RemindersEventRow> createState() => _RemindersEventRowState();
}

class _RemindersEventRowState extends ConsumerState<_RemindersEventRow> {
  bool _expanded = false;
  // Local mutable copy so removals apply optimistically (instant row
  // update) without invalidating `myEventsWithRemindersProvider`, which
  // would flash the sheet's loading state. The provider re-fetches fresh
  // on next open (it's autoDispose).
  late final List<EventReminderCard> _reminders = List.of(
    widget.event.reminders,
  );

  /// Close the sheet, then open the event detail. Capture the router
  /// before the pop (the sheet's `context` is defunct afterwards). Popping
  /// the closest navigator dismisses the sheet whether it was hosted on the
  /// shell navigator (opened from chrome) or the root overlay (opened from
  /// the reminder-picker link) — so the pushed event page is never left
  /// underneath the sheet.
  void _openEvent() {
    final router = GoRouter.of(context);
    ref
        .read(unifiedAnalyticsProvider)
        .trackMyRemindersEventClick(
          eventId: widget.event.eventId,
          remindersForEvent: _reminders.length,
        );
    // Embedded (notifications inbox) hosting has no modal to dismiss.
    if (widget.popOnOpen) Navigator.of(context).pop();
    router.push('/events/${widget.event.eventId}');
  }

  Future<void> _remove(EventReminderCard reminder) async {
    final l10n = Lt.of(context);
    final index = _reminders.indexWhere((r) => r.id == reminder.id);
    if (index < 0) return;
    setState(() => _reminders.removeAt(index));
    ref
        .read(notificationsProvider.notifier)
        .show(
          message: l10n.reminderPickerRemovedToast,
          variant: SokoVariant.success,
        );
    // Keep the event-detail bell in sync. This family provider isn't
    // watched by this sheet, so invalidating it doesn't rebuild us.
    ref.invalidate(eventReminderListProvider(widget.event.eventId));
    try {
      await ref.read(eventRemindersApiProvider).cancel(reminder.id);
    } catch (_) {
      if (!mounted) return;
      // Roll back on failure and re-sort by fire time (server contract:
      // reminders ordered by `fire_at` ASC).
      setState(() {
        _reminders.add(reminder);
        _reminders.sort((a, b) => a.fireAt.compareTo(b.fireAt));
      });
      ref
          .read(notificationsProvider.notifier)
          .show(
            message: l10n.reminderPickerSaveError,
            variant: SokoVariant.error,
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    // All reminders removed → the card disappears immediately.
    if (_reminders.isEmpty) return const SizedBox.shrink();

    final count = _reminders.length;
    // Server contract orders `reminders` by `fire_at` ASC → first row
    // is the soonest. Build the subtitle off it. `formatEventWhen`
    // reuses the same date format as the rest of the app (Hoje, 18h /
    // Amanhã, 18h / Sáb, 18h / 22 mai, 18h).
    final nextLabel = formatEventWhen(
      context: context,
      startsAt: _reminders.first.fireAt,
      timeKnown: true,
    );
    final summary =
        '${l10n.myRemindersSheetCountSummary(count)} · ${l10n.myRemindersSheetNextLine(nextLabel)}';

    // Event-card surface: full sokoGreen fill, 6 px radius, no border.
    // Tapping anywhere on the header row toggles the inline list of the
    // event's individual reminders (each removable); the chevron is just a
    // state indicator. The thumbnail is a separate tap target that opens
    // the event detail.
    return Material(
      color: AppColors.sokoGreen,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: SizedBox(
              height: 60,
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Thumbnail is its own tap target — opens the event
                    // detail. Its InkWell absorbs the tap so it doesn't also
                    // toggle the row's expansion.
                    InkWell(
                      onTap: _openEvent,
                      borderRadius: BorderRadius.circular(8),
                      child: _Thumbnail(imageUrl: widget.event.imageUrl),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.event.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.sokoInk,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.sokoInk.withValues(alpha: 0.70),
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Chevron is a state indicator only — the whole row
                    // toggles expansion.
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Icon(
                        _expanded
                            ? LucideIcons.chevron_up
                            : LucideIcons.chevron_down,
                        color: AppColors.sokoInk,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 6, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final r in _reminders)
                    _ReminderRow(
                      label:
                          '${formatEventWhen(context: context, startsAt: r.occurrenceStartAt, timeKnown: true)} · ${reminderOffsetLabel(l10n, r.offsetMinutes)}',
                      onRemove: () => _remove(r),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One removable reminder inside an expanded event row: date + offset
/// label with a trailing trash button (mirrors the list-editor
/// `_DeleteButton`). Removal is immediate — no confirm.
class _ReminderRow extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;
  const _ReminderRow({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.sokoInk.withValues(alpha: 0.85),
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            label: Lt.of(context).myRemindersRemoveReminder,
            button: true,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onRemove,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.sokoInk.withValues(alpha: 0.06),
                  ),
                  child: const Center(
                    child: Icon(
                      LucideIcons.trash_2,
                      size: 14,
                      color: AppColors.error,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final String? imageUrl;
  const _Thumbnail({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.sokoInk8,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null || url.isEmpty
          ? const Center(
              child: Icon(
                LucideIcons.bell,
                color: AppColors.sokoShade3,
                size: 18,
              ),
            )
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Center(
                child: Icon(
                  LucideIcons.bell,
                  color: AppColors.sokoShade3,
                  size: 18,
                ),
              ),
            ),
    );
  }
}
