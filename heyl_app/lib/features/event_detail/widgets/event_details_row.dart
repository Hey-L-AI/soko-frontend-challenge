import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/social_proof.dart';

/// Single details row for the event page: map pin + venue chip (name +
/// address + city) with a trailing chevron that navigates to the standalone
/// venue page. Replaces the venue page's 3-row phone/address/hours grid:
/// `EventDetailOut` only carries `venue_name`/`venue_address`/`venue_city`,
/// so phone + hours rows are skipped.
///
/// **Recursion (§ 7.5):** the chevron-tap pushes the **standalone** venue
/// route `/venues/<id>` — sub-navigation sheds the event's list-context per
/// the design doc.
///
/// Hidden when neither venue name nor address nor city is available.
class EventDetailsRow extends StatelessWidget {
  final EventDetailResponse2 event;

  const EventDetailsRow({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    final venueName = event.venueName;
    final city = event.venueCity;

    final hasVenueLink = (event.venueId ?? '').isNotEmpty;

    // Show the venue name + its city/area — never the full street address
    // (the detail page reads as a place, not a mailing label). A
    // neighbourhood/zone would be preferable but the detail DTO doesn't carry
    // one yet (see docs/openapi-gaps.md), so `city` is the finest area today.
    final textParts = <String>[];
    if ((venueName ?? '').isNotEmpty) textParts.add(venueName!);
    if ((city ?? '').isNotEmpty) textParts.add(city!);
    if (textParts.isEmpty) return const SizedBox.shrink();

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 14,
          height: 17,
          child: Center(
            child: SvgPicture.asset(
              'assets/images/icons/detail/pin.svg',
              width: 14,
              height: 14,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            textParts.join(' · '),
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
        if (hasVenueLink) ...[
          const SizedBox(width: 6),
          Icon(
            Icons.chevron_right,
            size: 18,
            color: AppColors.sokoInk.withValues(alpha: 0.6),
          ),
        ],
      ],
    );

    if (!hasVenueLink) return row;
    // Button-style surface matching the action grid below it
    // (`event_action_grid.dart` `_ActionButtonView`: sokoInk @ 6 %,
    // radius 6, `InkWell` for tap feedback). Inner padding gives the
    // text room to breathe inside the tinted rectangle.
    return Material(
      color: AppColors.sokoInk.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/venues/${event.venueId}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: row,
        ),
      ),
    );
  }
}
