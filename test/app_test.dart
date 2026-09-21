import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soko_frontend_challenge/app.dart';
import 'package:soko_frontend_challenge/data/event_repository.dart';
import 'package:soko_frontend_challenge/data/saved_store.dart';
import 'package:soko_frontend_challenge/domain/event.dart';

late List<Event> fixtureEvents;

Future<void> startApp(
  WidgetTester tester, {
  String scenario = '',
  SavedStore? store,
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    SokoApp(
      repository: FixtureRepository(scenario: scenario, delay: Duration.zero),
      savedStore: store ?? SavedStore(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openFirstEvent(WidgetTester tester) async {
  await tester.tap(find.text('Saturday garden sessions'));
  await tester.pumpAndSettle();
  expect(find.text('Jardim do Bairro\nEstrela, Lisbon'), findsOneWidget);
}

Future<void> tapSave(WidgetTester tester, String label) async {
  await tester.scrollUntilVisible(
    find.text(label),
    300,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    fixtureEvents = await AssetEventRepository(delay: Duration.zero).load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('discover, inspect, save, reopen app, find saved, remove', (
    tester,
  ) async {
    await startApp(tester);
    await openFirstEvent(tester);
    expect(find.text('Free'), findsOneWidget);
    await tapSave(tester, 'Save event');
    expect(await SavedStore().read(), {'garden-sessions'});
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saved'));
    await tester.pumpAndSettle();
    expect(find.text('Saturday garden sessions'), findsOneWidget);

    // Recreate the app to verify the saved state is read from storage.
    await tester.pumpWidget(const SizedBox.shrink());
    await startApp(tester);
    await tester.tap(find.text('Saved'));
    await tester.pumpAndSettle();
    await openFirstEvent(tester);
    await tapSave(tester, 'Remove from saved');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('No saved events yet.'), findsOneWidget);
    expect(await SavedStore().read(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search matches neighbourhood and has an empty result state', (
    tester,
  ) async {
    await startApp(tester);
    await tester.enterText(find.byType(TextField), '  ARROIOS  ');
    await tester.pumpAndSettle();
    expect(find.text('Clay club: make something imperfect'), findsOneWidget);
    expect(find.text('Saturday garden sessions'), findsNothing);
    await tester.enterText(find.byType(TextField), 'does-not-exist');
    await tester.pumpAndSettle();
    expect(find.text('No events found.'), findsOneWidget);
  });

  testWidgets('loading is shown before events resolve', (tester) async {
    await tester.pumpWidget(
      SokoApp(
        repository: FixtureRepository(delay: const Duration(seconds: 1)),
        savedStore: SavedStore(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Saturday garden sessions'), findsOneWidget);
  });

  testWidgets('failed load can be retried successfully', (tester) async {
    await startApp(tester, scenario: 'error');
    expect(
      find.text('We could not load your plans. Please try again.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Saturday garden sessions'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('empty repository does not show a loading or error state', (
    tester,
  ) async {
    await startApp(tester, scenario: 'empty');
    expect(find.text('No events available.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('save failure keeps previous state and offers retry', (
    tester,
  ) async {
    await startApp(tester, store: FailingSavedStore());
    await openFirstEvent(tester);
    await tapSave(tester, 'Save event');
    expect(
      find.text('Your change could not be saved. Please try again.'),
      findsOneWidget,
    );
    expect(find.text('Save event'), findsOneWidget);
    expect(await SavedStore().read(), isEmpty);
  });

  for (final width in [320.0, 768.0, 1280.0]) {
    testWidgets('long event content has no layout exceptions at width $width', (
      tester,
    ) async {
      await startApp(tester, width: width);
      await tester.enterText(find.byType(TextField), 'long table');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.text(
          'At the long table: a neighbourhood supper with stories from every kitchen',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(
          'At the long table: a neighbourhood supper with stories from every kitchen',
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Save event'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

class FailingSavedStore extends SavedStore {
  @override
  Future<void> write(Set<String> ids) async =>
      throw StateError('Storage unavailable');
}

// Preload the real asset once outside testWidgets' fake clock. Cached asynchronous
// asset futures must not cross individual widget tests' fake-async zones.
class FixtureRepository implements EventRepository {
  FixtureRepository({this.scenario = '', this.delay = Duration.zero});
  final String scenario;
  final Duration delay;
  bool failed = false;

  @override
  Future<List<Event>> load() async {
    await Future<void>.delayed(delay);
    if (scenario == 'error' && !failed) {
      failed = true;
      throw StateError('Unavailable');
    }
    return scenario == 'empty' ? [] : fixtureEvents;
  }
}
