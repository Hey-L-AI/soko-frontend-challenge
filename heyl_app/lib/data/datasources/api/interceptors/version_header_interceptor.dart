import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:package_info_plus/package_info_plus.dart';

/// Adds an `X-App-Version` header to every outgoing Dio request, formatted as
/// `<version>+<build>` (e.g. `1.1.0+38`).
///
/// PROD-2131: backend `auth_diag` events were arriving with
/// `app_version: null` because the frontend never sent the header. Without
/// the app version on every request, cross-stack pairing (FE Sentry event ↔
/// BE refresh.* log) couldn't filter by build number — every event on every
/// build looked the same. The header populates the backend's `app_version`
/// tag on `auth_diag` and any other request-scoped log line so we can confirm
/// hardened-fix builds vs pre-Phase builds in post-ship monitoring.
///
/// The interceptor loads `PackageInfo.fromPlatform()` once on construction
/// and caches `version+build`. Until the load completes, the header is
/// omitted — `PackageInfo.fromPlatform()` returns in ~5-10ms, so cold-start
/// requests that fire before it resolves will simply not carry the header
/// rather than blocking. This matches the existing `_cachedAppVersion`
/// pattern in `BackendAnalyticsService._getAppVersion`.
class VersionHeaderInterceptor extends Interceptor {
  VersionHeaderInterceptor({
    @visibleForTesting Future<PackageInfo> Function()? packageInfoLoader,
  }) {
    final loader = packageInfoLoader ?? PackageInfo.fromPlatform;
    unawaited(_loadVersion(loader));
  }

  String? _cachedHeader;

  Future<void> _loadVersion(Future<PackageInfo> Function() loader) async {
    try {
      final info = await loader();
      final version = info.version.trim();
      final build = info.buildNumber.trim();
      if (version.isEmpty) return;
      _cachedHeader = build.isEmpty ? version : '$version+$build';
    } catch (_) {
      // PackageInfo can fail in test environments without the platform
      // plugin registered. Skip the header silently rather than spamming
      // logs — the header is diagnostic, not load-bearing.
    }
  }

  /// Test hook — synchronously seed the cached value so tests don't have
  /// to wait for the async load. Production code never calls this.
  @visibleForTesting
  void seedHeaderForTest(String? header) {
    _cachedHeader = header;
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final header = _cachedHeader;
    if (header != null && header.isNotEmpty) {
      options.headers['X-App-Version'] = header;
    }
    handler.next(options);
  }
}
