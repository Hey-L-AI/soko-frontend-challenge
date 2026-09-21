import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../posthog_service.dart';
import '../unified_analytics_service.dart';
import 'app_entry.dart';

/// Process-lifetime latch: which list a deep link pointed at, for 60 s.
final deepLinkTargetLatchProvider = Provider<DeepLinkTargetLatch>(
  (ref) => DeepLinkTargetLatch(),
);

/// Process-lifetime entry tracker. Emission = register `entry_id` as a super
/// property (so every later event joins back to this entry), then the event.
final appEntryTrackerProvider = Provider<AppEntryTracker>((ref) {
  const uuid = Uuid();
  return AppEntryTracker(
    newId: uuid.v4,
    bareRootIsIcon: kIsWeb,
    emit: (entry) {
      ref.read(postHogServiceProvider).registerEntryId(entry.entryId);
      ref
          .read(unifiedAnalyticsProvider)
          .trackAppEntry(
            entryId: entry.entryId,
            entryType: entry.entryType.wire,
            isColdStart: entry.isColdStart,
            backgroundSeconds: entry.backgroundSeconds,
            linkHost: entry.linkHost,
            linkPath: entry.linkPath,
            pushRoute: entry.pushRoute,
            utm: entry.utm,
          );
    },
  );
});
