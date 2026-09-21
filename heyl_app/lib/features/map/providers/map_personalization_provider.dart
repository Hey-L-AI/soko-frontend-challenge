import 'package:flutter_riverpod/flutter_riverpod.dart';

/// PROD-2948 (FE-2) — the **admin-only** map personalization strength.
///
/// Pairs with BE-5 (PROD-2945): the selected level is sent to `/map/pins` as
/// `personalization_level`, where an `axis_shadow` weight shifts each venue's
/// relevance `score` toward the caller's taste twin.
///
/// **The admin gate lives on the backend, not here.** BE-5 clamps any non-admin's
/// `personalization_level` to `off` server-side, so the FE never has to check the
/// caller's role — sending a level from a non-admin is a harmless no-op. The
/// control that mutates this provider is exposed only through the local,
/// `kDebugMode`-gated `MapDebugTab` (compiled out of every release build), so in
/// staging/prod builds this provider always stays [off] and nothing is sent.
///
/// The effect is only *visible* when the backend flags
/// `MAP_PINS_AXIS_SCORE_ENABLED` + `MAP_PINS_RELEVANCE_SCORING` are on (staging);
/// otherwise the param is accepted but inert.
///
/// Deliberately NOT part of [MapQuery]: this is an admin diagnostic knob, not a
/// user filter, so it must not affect `MapQuery.isDefaultFilters` or the filter
/// UI seam. The fetch layer ([MapPinsNotifier]) reads it directly and refetches
/// on change, mirroring how it already listens to the v2-selection flag.
enum MapPersonalizationLevel {
  off,
  low,
  medium,
  high;

  /// The `personalization_level` wire value — matches the API enum
  /// (`off`/`low`/`medium`/`high`), so `name` is exact.
  String get wire => name;

  /// Display label for the admin control (hardcoded EN — internal admin tooling,
  /// consistent with the sibling `MapDebugTab` strings; never shown to regular
  /// users, so not localized).
  String get label => switch (this) {
    MapPersonalizationLevel.off => 'Off',
    MapPersonalizationLevel.low => 'Low',
    MapPersonalizationLevel.medium => 'Medium',
    MapPersonalizationLevel.high => 'High',
  };
}

/// Currently-selected admin personalization level. Defaults to [off] so the
/// default request body stays byte-identical (nothing sent) for everyone until
/// an admin deliberately changes it.
final mapPersonalizationLevelProvider = StateProvider<MapPersonalizationLevel>(
  (ref) => MapPersonalizationLevel.off,
);
