import 'package:shared_preferences/shared_preferences.dart';

/// Persists whether a given user has seen the post-login product tour.
///
/// Key: `product_tour_v1_seen_<userId>`. Versioned (`v1`) so bumping the
/// version naturally re-triggers everyone.
class TourPersistence {
  TourPersistence(this._prefs);

  static const _prefix = 'product_tour_v1_seen_';

  final SharedPreferences _prefs;

  String _key(String userId) => '$_prefix$userId';

  Future<bool> hasSeen(String userId) async {
    return _prefs.getBool(_key(userId)) ?? false;
  }

  Future<void> markSeen(String userId) async {
    await _prefs.setBool(_key(userId), true);
  }

  Future<void> clear(String userId) async {
    await _prefs.remove(_key(userId));
  }
}
