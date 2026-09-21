import 'package:sentry_flutter/sentry_flutter.dart';

import 'analytics_destination.dart';

/// Sentry destination adapter.
///
/// Lightweight — adds breadcrumbs for tracked events,
/// and manages SentryUser for identify/reset.
class SentryDestination implements AnalyticsDestination {
  SentryDestination();

  @override
  String get name => 'sentry';

  @override
  Future<void> track(String event, Map<String, dynamic> properties) async {
    // Add breadcrumb for event tracing in Sentry error reports
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: event,
        category: 'analytics',
        data: properties.isNotEmpty ? _sanitize(properties) : null,
      ),
    );
  }

  @override
  Future<void> identify(String userId, Map<String, dynamic> traits) async {
    // PROD-2095 Phase 3.2 — split test traffic from real users during the
    // auth diagnostic window. Matches backend's `is_test_user` tagging
    // rule (handoff §8): emails containing `teste` (test accounts like
    // dianateste57@gmail.com) OR ending with `@heyl.ai` (internal users).
    final email = traits['email'] as String?;
    final isTestUser =
        email != null &&
        (email.toLowerCase().contains('teste') ||
            email.toLowerCase().endsWith('@heyl.ai'));
    Sentry.configureScope((scope) {
      scope.setUser(SentryUser(id: userId));
      scope.setTag('test_user', isTestUser ? 'true' : 'false');
    });
  }

  @override
  Future<void> reset() async {
    Sentry.configureScope((scope) {
      scope.setUser(null);
      scope.removeTag('test_user');
    });
  }

  /// Sentry breadcrumb data must be Map<String, dynamic> with simple values.
  Map<String, dynamic> _sanitize(Map<String, dynamic> props) {
    return Map.fromEntries(
      props.entries.where((e) => e.value != null).map((e) {
        final value = e.value;
        // Convert lists to comma-separated strings for Sentry compatibility
        if (value is List) return MapEntry(e.key, value.join(','));
        return MapEntry(e.key, value);
      }),
    );
  }
}
