// PROD-4005 — the active content filter for the server-driven feed.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/models/feed_home.dart';

/// The filter the feed is currently composed for.
///
/// **Deliberately in-memory only.** D17 wants the selection to persist across
/// navigation but reset to Eventos on a new session, which is exactly what a
/// plain `StateProvider` on a root container already does — reaching for
/// `shared_preferences` here would make it survive an app restart, which is the
/// opposite of the requirement.
///
/// v0 only ever holds [FeedFilter.events]; the other three render disabled
/// (D29). The provider is still typed over the full enum so PROD-4006+ can flip
/// one to enabled without touching this file.
final feedFilterProvider = StateProvider<FeedFilter>(
  (ref) => FeedFilter.events,
);
