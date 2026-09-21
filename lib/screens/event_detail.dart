import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/event.dart';
import '../l10n/app_localizations.dart';
import '../widgets/event_artwork.dart';
import '../widgets/soko_button.dart';

class EventDetail extends StatefulWidget {
  const EventDetail({
    super.key,
    required this.event,
    required this.isSaved,
    required this.onToggleSave,
  });

  final Event event;
  final bool isSaved;
  final Future<bool> Function() onToggleSave;

  @override
  State<EventDetail> createState() => _EventDetailState();
}

class _EventDetailState extends State<EventDetail> {
  late bool _saved = widget.isSaved;
  bool _saving = false;

  Future<void> _toggle() async {
    setState(() => _saving = true);
    try {
      final saved = await widget.onToggleSave();
      if (mounted) setState(() => _saved = saved);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).saveError)),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final event = widget.event;
    final price = event.priceEuros;
    return Scaffold(
      appBar: AppBar(title: Text(strings.eventDetails)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: EventArtwork(seed: event.artwork, height: 230),
              ),
              const SizedBox(height: 24),
              Text(
                event.category,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              Text(
                event.title,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 24),
              _Fact(
                label: strings.when,
                value:
                    '${DateFormat('EEEE d MMMM · HH:mm', 'en').format(event.startsAt)}\n${strings.lisbonTime}',
              ),
              _Fact(
                label: strings.where,
                value:
                    '${event.venue}\n${event.neighbourhood}, ${strings.city}',
              ),
              _Fact(
                label: strings.price,
                value: price == null
                    ? strings.priceUnknown
                    : price == 0
                    ? strings.free
                    : NumberFormat.simpleCurrency(
                        locale: 'en_IE',
                        name: 'EUR',
                      ).format(price),
              ),
              _Fact(
                label: strings.booking,
                value: event.bookingRequired
                    ? strings.bookingRequired
                    : strings.dropIn,
              ),
              const SizedBox(height: 8),
              Text(
                event.description,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              _Fact(label: strings.accessibility, value: event.accessibility),
              const SizedBox(height: 16),
              SokoButton(
                label: _saving
                    ? strings.saving
                    : _saved
                    ? strings.removeSaved
                    : strings.saveEvent,
                icon: _saved ? Icons.bookmark : Icons.bookmark_border,
                onPressed: _saving ? null : _toggle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.bodyLarge),
      ],
    ),
  );
}
