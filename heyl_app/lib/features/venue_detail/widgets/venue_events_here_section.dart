import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/event_when_formatter.dart';
import '../../../data/models/social_proof.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../providers/venue_detail_provider.dart';

/// "Eventos aqui" section: list of upcoming events at this venue. Hidden
/// when `venue.upcomingEvents` is empty. Each row is a tinted button
/// surface matching the venue-link button on the event detail page
/// (`event_details_row.dart`) — sokoInk @ 6 %, radius 6, `InkWell` ripple
/// — so the clickable affordance is obvious. Tapping a row pushes the
/// standalone event detail page (`/events/<id>`); sub-nav sheds the
/// venue's list-context per design doc § 7.5.
///
/// Up to `_initialEventsToShow` events render initially. A "show more"
/// footer reveals the remainder of the events already in the venue
/// detail payload (capped server-side at 10 per `VenueDetailOut`).
/// Pagination beyond the embedded 10 — via `listVenueEvents`
/// (`GET /api/v1/app/places/{venue_id}/events`) — is still deferred;
/// most venues fit under the cap.
class VenueEventsHereSection extends StatefulWidget {
  final VenueDetailSnapshot snapshot;

  const VenueEventsHereSection({super.key, required this.snapshot});

  static const int _initialEventsToShow = 3;

  @override
  State<VenueEventsHereSection> createState() => _VenueEventsHereSectionState();
}

class _VenueEventsHereSectionState extends State<VenueEventsHereSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final events = widget.snapshot.venue.upcomingEvents;
    if (events.isEmpty) return const SizedBox.shrink();

    final l10n = Lt.of(context);
    final initial = VenueEventsHereSection._initialEventsToShow;
    final visible = _expanded ? events : events.take(initial).toList();
    final hiddenCount = events.length - visible.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.venueDetailEventsHereTitle,
          style: const TextStyle(
            fontFamily: 'ZalandoSans',
            fontWeight: FontWeight.w500,
            fontSize: 18,
            height: 1.0,
            letterSpacing: -0.36,
            color: AppColors.sokoInk,
          ),
        ),
        // Title is its own top-level section in Figma `6181:5531`
        // (sibling of the events list under a `flex-col gap-[30px]`
        // container), so the title→list gap is a section-level 30 px.
        const SizedBox(height: 30),
        ...visible.map(
          (event) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _EventRow(
              event: event,
              parentVenueName: widget.snapshot.venue.name,
              onTap: () => context.push('/events/${event.eventId}'),
            ),
          ),
        ),
        if (hiddenCount > 0)
          _ShowMoreButton(
            label: l10n.detailShowMoreEvents(hiddenCount),
            onTap: () => setState(() => _expanded = true),
          ),
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  final UpcomingEvent event;
  final String parentVenueName;
  final VoidCallback onTap;

  const _EventRow({
    required this.event,
    required this.parentVenueName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Button surface matches `event_details_row.dart` (venue chip on the
    // event detail page) and the action grid: sokoInk @ 6 %, radius 6,
    // `InkWell` for tap feedback. Inner padding gives the row some breathing
    // room inside the tinted rectangle without inflating the 63 px row
    // height.
    return Material(
      color: AppColors.sokoInk.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: SizedBox(
            height: 63,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Thumbnail (50 × 63, radius 2).
                SokoCardImage(
                  imageUrl: event.imageUrl,
                  seed: event.eventId,
                  kind: SokoEntityKind.event,
                  width: 50,
                  height: 63,
                  borderRadius: BorderRadius.circular(2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        event.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'ZalandoSans',
                          fontWeight: FontWeight.w300,
                          fontSize: 18,
                          height: 1.0,
                          letterSpacing: -0.36,
                          color: AppColors.sokoInk,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _metaLine(context, parentVenueName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'ZalandoSans',
                          fontWeight: FontWeight.w300,
                          fontSize: 14,
                          height: 1.2,
                          letterSpacing: -0.14,
                          color: AppColors.sokoInk.withValues(alpha: 0.3),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AppColors.sokoInk.withValues(alpha: 0.6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "Qua., 29 Abr. • 19h • Casa Capitão" for a single-day event; for an
  /// ongoing one "A decorrer até 2 mai. • Casa Capitão", and for a future
  /// multi-day span "29 abr. – 2 mai. • Casa Capitão" (PROD-4398). The date
  /// portion is built by [formatVenueEventWhen], which reads `end_at` so a
  /// long-running event no longer reads as already-past. Falls back gracefully
  /// when any piece of data is missing; the time component is hidden when the
  /// BE reports `time_known=false`.
  String _metaLine(BuildContext context, String parentVenueName) {
    final parts = <String>[];
    final start = _parse(event.startAt);
    if (start != null) {
      parts.add(
        formatVenueEventWhen(
          context: context,
          startsAt: start,
          endsAt: _parse(event.endAt),
          timeKnown: event.timeKnown,
        ),
      );
    }
    parts.add(parentVenueName);
    return parts.join(' • ');
  }

  DateTime? _parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}

/// Footer "+N mais eventos" button. Same tinted surface as event rows so
/// the affordance stays consistent inside the section.
class _ShowMoreButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ShowMoreButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.sokoInk.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontWeight: FontWeight.w500,
                fontSize: 14,
                height: 1.2,
                letterSpacing: -0.14,
                color: AppColors.sokoInk,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
