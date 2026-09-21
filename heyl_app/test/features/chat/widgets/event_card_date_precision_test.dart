import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heyl_app/data/models/chat_message.dart';
import 'package:heyl_app/features/chat/widgets/event_card.dart';
import 'package:heyl_app/l10n/generated/l10n.dart';

/// Wraps an [EventCard] in the minimum scaffolding the widget needs
/// (Riverpod scope + Material localizations). Pump and find the subtitle
/// text via the rendered card content.
Widget _harness(ItemSuggestion event) {
  return ProviderScope(
    child: MaterialApp(
      localizationsDelegates: Lt.localizationsDelegates,
      supportedLocales: Lt.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: EventCard(event: event),
        ),
      ),
    ),
  );
}

ItemSuggestion _event({String? datePrecision}) {
  // Date-only ISO string the backend sends when precision == "date".
  // DateTime.parse turns this into local-midnight, which used to render
  // "00:00" in the subtitle (PROD-1560).
  return ItemSuggestion(
    id: 'e1',
    name: 'Concerto Sinfónico',
    type: 'event',
    date: '2026-04-30',
    datePrecision: datePrecision,
  );
}

void main() {
  group('EventCard subtitle date_precision rendering (PROD-1560)', () {
    testWidgets('precision="date" renders weekday + month + day, no time',
        (tester) async {
      await tester.pumpWidget(_harness(_event(datePrecision: 'date')));

      expect(find.text('Thu, Apr 30'), findsOneWidget);
      expect(find.textContaining('00:00'), findsNothing);
      expect(find.textContaining('12:00'), findsNothing);
    });

    testWidgets('precision="datetime" keeps existing time tail',
        (tester) async {
      await tester.pumpWidget(
        _harness(
          ItemSuggestion(
            id: 'e1',
            name: 'Concerto Sinfónico',
            type: 'event',
            date: '2026-04-30T20:30:00',
            datePrecision: 'datetime',
          ),
        ),
      );

      // Bullet between day and time — same character used in EventCard.
      expect(find.text('Thu, Apr 30 • 20:30'), findsOneWidget);
    });

    testWidgets('precision="unknown" renders the localized "Date TBD" string',
        (tester) async {
      await tester.pumpWidget(_harness(_event(datePrecision: 'unknown')));

      // English locale is the default — match the en ARB value.
      expect(find.text('Date TBD'), findsOneWidget);
      expect(find.textContaining('00:00'), findsNothing);
    });

    testWidgets(
        'precision=null (legacy payload, no field) preserves pre-PROD-1560 behaviour',
        (tester) async {
      // Legacy date-only payload without the new field → still shows "00:00",
      // documenting the existing behaviour rather than masking it. The
      // server-side strip handles the user-visible bug for fresh payloads.
      await tester.pumpWidget(_harness(_event()));

      expect(find.text('Thu, Apr 30 • 00:00'), findsOneWidget);
    });
  });
}
