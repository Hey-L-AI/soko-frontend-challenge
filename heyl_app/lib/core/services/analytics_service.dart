import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The interview copy does not initialise Firebase or send Google Analytics.
/// Keep the original service interface so product code remains unchanged.
final analyticsServiceProvider = Provider<AnalyticsService>((ref) {
  return AnalyticsService();
});

class AnalyticsService {
  NavigatorObserver get observer => NavigatorObserver();
  Future<void> initialize() async {}
  Future<void> logScreenView({
    required String screenName,
    String? screenClass,
  }) async {}
  Future<void> logLogin({required String method}) async {}
  Future<void> logSignUp({required String method}) async {}
  Future<void> logLogout() async {}
  Future<void> logEvent({
    required String name,
    Map<String, Object>? parameters,
  }) async {}
  Future<void> logViewItem({
    required String itemId,
    required String itemType,
    String? itemName,
  }) async {}
  Future<void> logShare({
    required String contentType,
    required String itemId,
    String? method,
  }) async {}
  Future<void> logSearch({required String searchTerm}) async {}
  Future<void> logMessageSent({required String messageType}) async {}
  Future<void> setUserId(String? userId) async {}
  Future<void> setUserProperty({
    required String name,
    required String? value,
  }) async {}
}
