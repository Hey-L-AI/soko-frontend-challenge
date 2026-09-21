import 'analytics_destination.dart';

/// Mobile/native stub of [TikTokWebDestination].
///
/// Selected by conditional import when `dart:io` is available (iOS/Android/
/// desktop). All methods are no-ops — mobile routes TikTok pixel calls
/// through [TikTokDestination] instead (see `unified_analytics_service.dart`,
/// which picks the destination via `kIsWeb`).
///
/// Exists so the web-only `dart:js_interop` types in the real
/// implementation never get type-checked on native targets.
class TikTokWebDestination implements AnalyticsDestination {
  TikTokWebDestination();

  @override
  String get name => 'tiktok';

  @override
  Future<void> track(String event, Map<String, dynamic> properties) async {}

  @override
  Future<void> identify(String userId, Map<String, dynamic> traits) async {}

  @override
  Future<void> reset() async {}
}
