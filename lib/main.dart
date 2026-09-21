import 'package:flutter/material.dart';

import 'app.dart';
import 'data/event_repository.dart';
import 'data/saved_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(SokoApp(repository: AssetEventRepository(), savedStore: SavedStore()));
}
