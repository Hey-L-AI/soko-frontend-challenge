import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/event.dart';

abstract interface class EventRepository {
  Future<List<Event>> load();
}

class AssetEventRepository implements EventRepository {
  AssetEventRepository({
    this.scenario = const String.fromEnvironment('DEMO_SCENARIO'),
    this.delay = const Duration(milliseconds: 450),
  });

  final String scenario;
  final Duration delay;
  bool _hasFailed = false;

  @override
  Future<List<Event>> load() async {
    await Future<void>.delayed(delay);
    // Fail once so Retry can demonstrate recovery.
    if (scenario == 'error' && !_hasFailed) {
      _hasFailed = true;
      throw StateError('Simulated event loading failure');
    }
    if (scenario == 'empty') return [];
    final source = await rootBundle.loadString('assets/data/events.json');
    final data = jsonDecode(source) as List<dynamic>;
    return data
        .map((item) => Event.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }
}
