import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/backend_analytics_service.dart'
    show OriginSource;
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/calendar_utils.dart';
import '../../../core/utils/datetime_parsing.dart';
import '../../../data/models/moderation.dart';
import '../../../l10n/generated/l10n.dart';
import '../../moderation/widgets/report_sheet.dart';
import '../providers/event_detail_provider.dart';
import '../utils/event_maps_launcher.dart';

/// Action grid — event variant. Two rows of equal-width buttons; collapses
/// to a 2×2 grid on narrow viewports (< 360 px).
///
///   Row 1: Guardar · Reportar · Ver site (when url).
///   Row 2 (Figma `6181:5789`): Abrir no Maps · Marcar no calendário.
///
/// Share moved out of the grid into the trailing icon cluster next to the
/// Save button in [EventDetailBody]; Reportar took its slot.
///
/// Row 2 button visibility:
///   - Maps shown when coordinates are present.
///   - Calendar shown when `event.startDatetime` is non-null
///     (mirrors the `hasCalendar` check from the legacy item detail sheet).
///   - When only one of the two is present, Row 2 becomes a single
///     full-width button. When neither, Row 2 collapses entirely.
///
/// "Lembrar-me" moved to the chrome's top-right trailing slot
/// (`pinned_page_chrome.dart` → `_EventReminderTrailing`) — kept out of the
/// grid so the reminder action mirrors the back arrow geometrically.
class EventActionGrid extends ConsumerWidget {
  final EventDetailSnapshot snapshot;

  const EventActionGrid({super.key, required this.snapshot});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final event = snapshot.event;
    final hasWebsite = (event.url ?? '').isNotEmpty;
    final hasMap = event.latitude != null && event.longitude != null;
    final hasCalendar =
        (event.startDatetime ?? '').isNotEmpty ||
        snapshot.occurrences.isNotEmpty;

    final rowOne = <_ActionButton>[
      _ActionButton(
        iconWidget: const Icon(
          LucideIcons.flag,
          size: 14,
          color: AppColors.sokoInk,
        ),
        label: l10n.moderationMenuReport,
        onTap: () => _onReport(context),
      ),
      if (hasWebsite)
        _ActionButton(
          iconWidget: SvgPicture.asset(
            'assets/images/icons/detail/external-link.svg',
            width: 14,
            height: 14,
          ),
          label: l10n.venueDetailButtonVerSite,
          onTap: () => _onWebsite(ref, event.url!),
        ),
    ];

    final rowTwo = <_ActionButton>[
      if (hasMap)
        _ActionButton(
          iconWidget: SvgPicture.asset(
            'assets/images/icons/detail/map.svg',
            width: 14,
            height: 14,
          ),
          label: l10n.venueDetailButtonAbrirNoMaps,
          onTap: () => _onMaps(context, ref),
        ),
      if (hasCalendar)
        _ActionButton(
          iconWidget: SvgPicture.asset(
            'assets/images/icons/detail/calendar.svg',
            width: 14,
            height: 14,
          ),
          label: l10n.eventDetailButtonMarcarCalendario,
          onTap: () => _onCalendar(ref),
        ),
    ];

    final width = MediaQuery.of(context).size.width;
    final narrow = width < 360;
    if (narrow) {
      return _GridLayout(buttons: [...rowOne, ...rowTwo]);
    }
    return _StackedRowsLayout(rowOne: rowOne, rowTwo: rowTwo);
  }

  void _onReport(BuildContext context) {
    showReportSheet(
      context,
      targetType: ReportTargetType.event,
      targetId: snapshot.event.id,
    );
  }

  Future<void> _onWebsite(WidgetRef ref, String websiteUrl) async {
    ref
        .read(unifiedAnalyticsProvider)
        .trackWebsiteClick(
          url: websiteUrl,
          eventId: snapshot.event.id,
          originSource: OriginSource.detailView,
          originEntityId: snapshot.effectiveListId,
        );
    final uri = Uri.parse(websiteUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _onMaps(BuildContext context, WidgetRef ref) async {
    final event = snapshot.event;
    final mapsQuery = [
      if ((event.venueName ?? '').isNotEmpty) event.venueName!,
      if ((event.venueAddress ?? '').isNotEmpty) event.venueAddress!,
    ].join(', ');
    final url =
        'https://www.google.com/maps/search/?api=1&query='
        '${Uri.encodeComponent(mapsQuery.isEmpty ? event.title : mapsQuery)}';
    final provider = await openEventInMaps(context, event: event);
    if (provider == null) return;
    ref
        .read(unifiedAnalyticsProvider)
        .trackMapsClick(
          provider: provider,
          url: url,
          eventId: event.id,
          venueId: event.venueId,
          originSource: OriginSource.detailView,
          originEntityId: snapshot.effectiveListId,
        );
  }

  Future<void> _onCalendar(WidgetRef ref) async {
    final event = snapshot.event;
    final startRaw =
        event.startDatetime ??
        (snapshot.occurrences.isNotEmpty
            ? snapshot.occurrences.first.startAt.toIso8601String()
            : null);
    if (startRaw == null) return;

    final startDate = parseBackendDateTime(startRaw);
    if (startDate == null) return;

    DateTime? endDate;
    if ((event.endDatetime ?? '').isNotEmpty) {
      endDate = parseBackendDateTime(event.endDatetime);
    } else if (snapshot.occurrences.isNotEmpty &&
        snapshot.occurrences.first.endAt != null) {
      endDate = snapshot.occurrences.first.endAt;
    }

    final locationParts = <String>[
      if ((event.venueName ?? '').isNotEmpty) event.venueName!,
      if ((event.venueAddress ?? '').isNotEmpty &&
          event.venueAddress != event.venueName)
        event.venueAddress!,
      if ((event.venueCity ?? '').isNotEmpty &&
          (event.venueAddress?.contains(event.venueCity!) != true))
        event.venueCity!,
    ];

    final calendarUrl = generateGoogleCalendarUrl(
      title: event.title,
      startDate: startDate,
      endDate: endDate,
      description: event.descriptionLong,
      location: locationParts.isNotEmpty ? locationParts.join(', ') : null,
    );
    if (calendarUrl == null) return;

    ref
        .read(unifiedAnalyticsProvider)
        .trackEventAddToCalendar(
          eventId: event.id,
          calendarProvider: 'google',
          originSource: OriginSource.detailView,
          originEntityId: snapshot.effectiveListId,
        );

    final uri = Uri.parse(calendarUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

class _ActionButton {
  final Widget iconWidget;
  final String label;
  final VoidCallback onTap;

  _ActionButton({
    required this.iconWidget,
    required this.label,
    required this.onTap,
  });
}

class _ActionButtonView extends StatelessWidget {
  final _ActionButton spec;

  const _ActionButtonView({required this.spec});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.sokoInk.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: spec.onTap,
        child: SizedBox(
          height: 40,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              spec.iconWidget,
              const SizedBox(width: 5),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    spec.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'ZalandoSans',
                      fontWeight: FontWeight.w300,
                      fontSize: 14,
                      height: 1.2,
                      letterSpacing: -0.14,
                      color: AppColors.sokoInk,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wide-viewport layout: Row 1 = up-to-3 equal Expanded buttons, Row 2 =
/// 1 or 2 equal Expanded buttons. Empty rows collapse cleanly.
class _StackedRowsLayout extends StatelessWidget {
  final List<_ActionButton> rowOne;
  final List<_ActionButton> rowTwo;

  const _StackedRowsLayout({required this.rowOne, required this.rowTwo});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (rowOne.isNotEmpty) _Row(buttons: rowOne),
        if (rowOne.isNotEmpty && rowTwo.isNotEmpty) const SizedBox(height: 6),
        if (rowTwo.isNotEmpty) _Row(buttons: rowTwo),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final List<_ActionButton> buttons;

  const _Row({required this.buttons});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(child: _ActionButtonView(spec: buttons[i])),
        ],
      ],
    );
  }
}

/// Narrow-viewport layout (< 360 px): 2×2 grid. Same chrome, smaller cells.
class _GridLayout extends StatelessWidget {
  final List<_ActionButton> buttons;

  const _GridLayout({required this.buttons});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      childAspectRatio: 5,
      children: buttons.map((b) => _ActionButtonView(spec: b)).toList(),
    );
  }
}
