import 'package:app_links/app_links.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'app.dart';
import 'core/router/app_router.dart';
import 'core/services/posthog_service.dart';
import 'core/services/storage_service.dart';
import 'core/utils/app_loading_stub.dart'
    if (dart.library.js_interop) 'core/utils/app_loading_web.dart';
import 'providers/api_provider.dart';

/// Interview bootstrap for the real Soko app. Screens, routes, state and API
/// clients are the released app's code. Only production service startup is omitted.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) usePathUrlStrategy();
  VisibilityDetectorController.instance.updateInterval = const Duration(
    milliseconds: 150,
  );
  final preferences = await SharedPreferences.getInstance();
  final initialLink = await AppLinks().getInitialLink();
  // No key is bundled. A candidate may configure a separate interview project.
  await PostHogService().initialize();
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        initialDeepLinkProvider.overrideWithValue(initialLink),
        cookieJarProvider.overrideWith((ref) => CookieJar()),
      ],
      child: const SokoApp(),
    ),
  );
  if (kIsWeb) hideAppLoading();
}
