import 'package:flutter_test/flutter_test.dart';
import 'package:soko_frontend_challenge/data/event_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'fixtures have unique identities and cover the interview weekend',
    () async {
      final events = await AssetEventRepository(delay: Duration.zero).load();
      expect(events, hasLength(8));
      expect(events.map((e) => e.id).toSet(), hasLength(events.length));
      expect(
        events.every(
          (e) =>
              e.startsAt.year == 2026 &&
              e.startsAt.month == 9 &&
              [26, 27].contains(e.startsAt.day),
        ),
        isTrue,
      );
      expect(events.any((e) => e.priceEuros == 0), isTrue);
      expect(events.any((e) => e.priceEuros == null), isTrue);
      expect(events.any((e) => (e.priceEuros ?? 0) > 0), isTrue);
    },
  );
}
