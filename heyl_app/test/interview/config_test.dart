import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heyl_app/core/config/environment.dart';
import 'package:heyl_app/core/constants/api_constants.dart';
import 'package:heyl_app/core/services/analytics_service.dart';

void main() {
  test('both app environments point to backend-staging', () {
    expect(ApiConstants.devBaseUrl, ApiConstants.stagingBaseUrl);
    expect(ApiConstants.prodBaseUrl, ApiConstants.stagingBaseUrl);
    expect(EnvironmentConfig.baseUrl, ApiConstants.stagingBaseUrl);
    expect(ApiConstants.webappUrl, 'http://localhost:3001');
  });

  test('production marketing and PostHog are disabled by default', () {
    expect(EnvironmentConfig.posthogApiKey, isEmpty);
    expect(EnvironmentConfig.klaviyoPublicApiKey, isEmpty);
    expect(EnvironmentConfig.metaEnabled, isFalse);
    expect(EnvironmentConfig.tiktokEnabled, isFalse);
    expect(EnvironmentConfig.appsflyerEnabled, isFalse);
  });

  test('analytics facade works without creating a Firebase app', () async {
    final service = AnalyticsService();
    expect(service.observer, isNotNull);
    await service.initialize();
    await service.logScreenView(screenName: 'interview');
    await service.setUserId('interview-test');
    await service.logEvent(name: 'interview_test');
  });

  test('web shell has no production tracking bootstrap', () {
    final html = File('web/index.html').readAsStringSync();
    expect(html, isNot(contains('posthog.init(')));
    expect(html, isNot(contains('ttq.load(')));
    expect(html, isNot(contains('phc_')));
    expect(File('lib/firebase_options.dart').existsSync(), isFalse);
  });
}
