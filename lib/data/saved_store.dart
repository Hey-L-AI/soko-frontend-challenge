import 'package:shared_preferences/shared_preferences.dart';

class SavedStore {
  static const _key = 'soko_interview_saved_v1';

  Future<Set<String>> read() async {
    final preferences = await SharedPreferences.getInstance();
    return (preferences.getStringList(_key) ?? []).toSet();
  }

  Future<void> write(Set<String> ids) async {
    final preferences = await SharedPreferences.getInstance();
    final written = await preferences.setStringList(_key, ids.toList()..sort());
    if (!written) throw StateError('Could not persist saved events');
  }
}
