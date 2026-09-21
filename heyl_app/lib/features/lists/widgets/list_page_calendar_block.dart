import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/list_item_routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../providers/providers.dart';
import 'list_calendar_view.dart';
import 'list_view_mode/list_view_section.dart' show guestVisibleItemCount;

/// PROD-1979 — shared cover-calendar block used by both the zine cover
/// and the list view body. Owns the guest-gate wiring so the two view
/// modes stay in sync: chips for events that fall beyond the
/// [guestVisibleItemCount] cap render blurred and non-interactive,
/// mirroring the [GuestListGateOverlay] treatment applied to the hidden
/// row block in the list view's events section.
///
/// [tinted] toggles the Soko/Ink @ 6 % container surface used by the
/// zine cover (the list view body renders the calendar against the
/// page background, no inner surface).
class ListPageCalendarBlock extends ConsumerWidget {
  final List<UserListItem> items;
  final DateTime currentMonth;
  final bool tinted;

  const ListPageCalendarBlock({
    super.key,
    required this.items,
    required this.currentMonth,
    this.tinted = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isGuest = !ref.watch(isAuthenticatedProvider);
    final hiddenEventIds = isGuest ? _hiddenEventIds(items) : null;

    final calendar = ListCalendarView(
      items: items,
      currentMonth: currentMonth,
      // PROD-2018 follow-up — tapping a row in the per-day agenda
      // opens the event/venue detail page, scoped to the parent list
      // when present. Shared with the hub calendar + map pin tooltip.
      onItemTap: (item) => openItemDetail(context, ref, item),
      hiddenItemIds: hiddenEventIds,
    );

    if (!tinted) return calendar;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.sokoInk.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(16),
      child: calendar,
    );
  }
}

/// IDs of event items whose calendar chip should render blurred for
/// guests — the events that fall beyond the per-section guest cap in
/// [ListViewSection]. Place items are skipped because the calendar
/// only renders event chips.
Set<String> _hiddenEventIds(List<UserListItem> items) {
  final events = items.where((i) => i.itemType == SavedItemType.event).toList();
  return events
      .skip(guestVisibleItemCount(events.length))
      .map((e) => e.id)
      .toSet();
}
