import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/event.dart';
import '../theme.dart';
import 'event_artwork.dart';

class EventCard extends StatelessWidget {
  const EventCard({
    super.key,
    required this.event,
    required this.onTap,
    required this.isSaved,
  });

  final Event event;
  final VoidCallback onTap;
  final bool isSaved;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    color: Colors.white.withValues(alpha: 0.5),
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: SokoColors.ink.withValues(alpha: 0.14)),
    ),
    child: InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EventArtwork(seed: event.artwork),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        event.category,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    if (isSaved) const Icon(Icons.bookmark, size: 18),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  event.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  '${DateFormat('EEE d MMM · HH:mm', 'en').format(event.startsAt)}\n${event.neighbourhood}',
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
