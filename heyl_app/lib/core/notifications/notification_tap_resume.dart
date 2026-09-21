import 'package:shared_preferences/shared_preferences.dart';

const _kStashedRoutePathKey = 'soko.notification.stashed_route_path_v1';
const _kStashedAtKey = 'soko.notification.stashed_at_ms_v1';

/// Stashes expire after this window. Covers two cases:
/// (a) tap-while-logged-out → login → resume
/// (b) tap-with-cached-token that 401s a few seconds later →
///     forceLogout → login → resume
/// Five minutes leaves headroom for a slow phone-OTP re-login while
/// preventing a much-older stash from firing on a later intentional
/// re-login. `FcmHandlerService` also clears the stash explicitly after
/// the race window passes when the app stays foregrounded; the TTL is
/// the backstop for app-killed-before-clear cases.
const _kStashTtl = Duration(minutes: 5);

/// Helper for the FCM-tap → logged-out → resume-after-login flow.
///
/// PROD-2523: every tap entry point (`onMessage` toast, `onMessageOpenedApp`,
/// cold-start `getInitialMessage`) stashes through here. The
/// `authStateProvider` listener in `app.dart` consumes the stash on the
/// next transition to authenticated. Stashes older than [_kStashTtl] are
/// discarded on read so an intentional re-login days later doesn't replay
/// a stale tap.
class NotificationTapResume {
  const NotificationTapResume._();

  /// Persist a route the user tapped. The most recent tap wins — older
  /// stashes are intentionally discarded so the user always lands on
  /// what they last asked for. The write timestamp is recorded so the
  /// consumer can drop stale stashes.
  static Future<void> stash(String routePath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kStashedRoutePathKey, routePath);
    await prefs.setInt(_kStashedAtKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// Read and clear the stashed route. Returns null when nothing is
  /// stashed or when the stash is older than [_kStashTtl].
  static Future<String?> consume() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_kStashedRoutePathKey);
    if (value == null) return null;
    await prefs.remove(_kStashedRoutePathKey);
    final stashedAtMs = prefs.getInt(_kStashedAtKey);
    await prefs.remove(_kStashedAtKey);
    if (stashedAtMs == null) return value;
    final age = DateTime.now().millisecondsSinceEpoch - stashedAtMs;
    if (age < 0 || age > _kStashTtl.inMilliseconds) return null;
    return value;
  }

  /// Non-destructive peek (tests + diagnostics).
  static Future<bool> hasStashed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_kStashedRoutePathKey);
  }
}
