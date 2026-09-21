import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/venue_hours.dart';
import '../../../data/models/social_proof.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/clickable.dart';

/// 2-col grid (icon | text) for phone / address / opening hours. Each row
/// hides itself when its data is missing, and the whole grid collapses
/// when none of the three rows have data. Ports the inline phone row,
/// location info, and collapsible opening-hours block from the legacy item
/// detail sheet (retired in PROD-1672).
class VenueDetailsGrid extends ConsumerStatefulWidget {
  final VenueDetailResponse venue;

  const VenueDetailsGrid({super.key, required this.venue});

  @override
  ConsumerState<VenueDetailsGrid> createState() => _VenueDetailsGridState();
}

class _VenueDetailsGridState extends ConsumerState<VenueDetailsGrid> {
  bool _hoursExpanded = false;

  @override
  Widget build(BuildContext context) {
    final venue = widget.venue;
    final phone = venue.phone;
    final city = venue.city;
    final hours = venue.openingHours;

    final hasPhone = phone != null && phone.isNotEmpty;
    // Show the city/area only — never the full street address (the page reads
    // as a place, not a mailing label). A neighbourhood/zone would be better
    // but the venue-detail DTO doesn't carry one yet (docs/openapi-gaps.md).
    final hasArea = city != null && city.isNotEmpty;
    final hasHours = hours != null && hours.isNotEmpty;

    if (!hasPhone && !hasArea && !hasHours) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasPhone) _PhoneRow(phone: phone),
        if (hasPhone && (hasArea || hasHours)) const SizedBox(height: 5),
        if (hasArea) _AddressRow(city: city),
        if (hasArea && hasHours) const SizedBox(height: 5),
        if (hasHours)
          _OpeningHoursRow(
            hours: hours,
            expanded: _hoursExpanded,
            onToggle: () {
              final wasCollapsed = !_hoursExpanded;
              setState(() => _hoursExpanded = !_hoursExpanded);
              if (wasCollapsed) {
                ref
                    .read(unifiedAnalyticsProvider)
                    .trackOpeningHoursExpand(venueId: venue.id);
              }
            },
          ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final Widget icon;
  final Widget child;
  final VoidCallback? onTap;

  const _DetailRow({required this.icon, required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 14, height: 17, child: Center(child: icon)),
        const SizedBox(width: 10),
        Expanded(child: child),
      ],
    );
    if (onTap == null) return row;
    return Clickable(onTap: onTap!, child: row);
  }
}

class _PhoneRow extends ConsumerWidget {
  final String phone;
  const _PhoneRow({required this.phone});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _DetailRow(
      icon: SvgPicture.asset(
        'assets/images/icons/detail/phone.svg',
        width: 14,
        height: 14,
      ),
      onTap: () {
        launchUrl(Uri.parse('tel:$phone'));
        ref.read(unifiedAnalyticsProvider).trackPhoneClick(phoneNumber: phone);
      },
      child: Text(phone, style: _detailTextStyle),
    );
  }
}

class _AddressRow extends StatelessWidget {
  final String? city;
  const _AddressRow({this.city});

  @override
  Widget build(BuildContext context) {
    // City/area only — the street address is intentionally not shown.
    return _DetailRow(
      icon: SvgPicture.asset(
        'assets/images/icons/detail/pin.svg',
        width: 14,
        height: 14,
      ),
      child: SelectableText(city ?? '', style: _detailTextStyle),
    );
  }
}

class _OpeningHoursRow extends StatelessWidget {
  final Map<String, dynamic> hours;
  final bool expanded;
  final VoidCallback onToggle;

  const _OpeningHoursRow({
    required this.hours,
    required this.expanded,
    required this.onToggle,
  });

  static const _dayKeys = [
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday',
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final locale = Localizations.localeOf(context).toString();
    final strings = VenueHoursStrings(
      closed: l10n.venueHoursClosed,
      open24h: l10n.venueHoursOpen24h,
    );
    final todayIndex = DateTime.now().weekday - 1;
    final todayKey = _dayKeys[todayIndex];
    final todaySummary = formatVenueHours(hours[todayKey], locale, strings);
    final hoursWord = l10n.venueDetailHoursLabel;
    final todayLabel = todaySummary != null
        ? '$hoursWord · $todaySummary'
        : hoursWord;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DetailRow(
          icon: SvgPicture.asset(
            'assets/images/icons/detail/clock.svg',
            width: 14,
            height: 14,
          ),
          onTap: onToggle,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  todayLabel,
                  style: _detailTextStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(
                  Icons.expand_more,
                  size: 18,
                  color: AppColors.sokoInk,
                ),
              ),
            ],
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.only(left: 24, top: 6),
            child: Column(
              children: _dayKeys.map((day) {
                final text = formatVenueHours(hours[day], locale, strings);
                if (text == null) return const SizedBox.shrink();
                final isToday = day == todayKey;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _localizedDayName(day, l10n),
                        style: _detailTextStyle.copyWith(
                          fontWeight: isToday
                              ? FontWeight.w500
                              : FontWeight.w300,
                        ),
                      ),
                      Flexible(
                        child: Text(
                          text,
                          style: _detailTextStyle.copyWith(
                            fontWeight: isToday
                                ? FontWeight.w500
                                : FontWeight.w300,
                          ),
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          crossFadeState: expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
        ),
      ],
    );
  }
}

const TextStyle _detailTextStyle = TextStyle(
  fontFamily: 'ZalandoSans',
  fontWeight: FontWeight.w300,
  fontSize: 14,
  height: 1.2,
  letterSpacing: -0.14,
  color: AppColors.sokoInk,
);

String _localizedDayName(String day, Lt l10n) {
  switch (day) {
    case 'monday':
      return l10n.dayMonday;
    case 'tuesday':
      return l10n.dayTuesday;
    case 'wednesday':
      return l10n.dayWednesday;
    case 'thursday':
      return l10n.dayThursday;
    case 'friday':
      return l10n.dayFriday;
    case 'saturday':
      return l10n.daySaturday;
    case 'sunday':
      return l10n.daySunday;
    default:
      return day;
  }
}
