/// PROD-3979 — refetch the strings the **backend** resolved, when the app
/// locale changes.
///
/// ARB strings re-render on their own: `MaterialApp.router` is keyed on the
/// locale, so the whole subtree rebuilds and `Lt` hands out the new copy. Every
/// string the *server* resolved is a different matter — it is payload the app
/// is holding, not something it can re-derive, so without a refetch it stays in
/// the previous language until a pull-to-refresh or an app restart. The visible
/// symptom is a page in two languages at once: chrome and buttons in the new
/// locale, card subtitles and type labels still in the old one.
///
/// **ADR-048 is what makes this matter.** Under backend-owned taxonomy labels
/// the localized string *is* the payload — the app can no longer re-render a
/// venue type or an event category from data it already holds — so the stale
/// set grew from a handful of fields to every taxonomy label on screen, and
/// grows again with each surface the PROD-3959 sweep converts. PROD-3978 put
/// one of those labels on the venue page's tag row, right beside the hardcoded
/// "Sítio" chip that *does* re-render: two adjacent chips, two languages.
///
/// Mount [LocaleRefreshListener] **above** the locale-keyed `MaterialApp` so it
/// survives the rebuild that a locale change triggers — below it, the listener
/// would be torn down by the very event it exists to observe.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/daily_drop/providers/daily_drop_entity_detail_provider.dart';
import '../features/discovery/providers/discovery_feed_refresh.dart';
import '../features/event_detail/providers/event_detail_provider.dart';
import '../features/venue_detail/providers/venue_detail_provider.dart';
import 'locale_provider.dart';

/// Re-fetch everything whose text the backend resolved for a specific locale.
///
/// Deliberately delegates to [refreshDiscoveryFeed] rather than hand-rolling a
/// second refresh path: that function already encodes the per-provider strategy,
/// including the trap that cost PROD-2065 — a `StateNotifierProvider` shelf must
/// be refreshed through `notifier.refresh()`, because invalidating it discards
/// the notifier and strands the section on a skeleton forever. A parallel
/// implementation here would have to re-learn that, and would drift.
///
/// One consequence worth knowing: `refreshDiscoveryFeed` also invalidates the
/// IP-detection chain (`detectedCountryCodeProvider` / `cityAutoScopeProvider`,
/// added by PROD-2065 so a pull-to-refresh can recover a cached-null country).
/// A locale switch therefore re-runs that chain too. It is cheap (the service
/// holds a 24 h cache) and it cannot flip the locale back — `setLocale` marks
/// the choice explicit, and `setLocaleFromDetectedCountry` skips explicit
/// preferences (PROD-2037).
///
/// The four detail providers are all `FutureProvider.autoDispose.family`, so
/// `invalidate` is the correct verb for them and is a no-op for any family
/// member nobody is watching — invalidating the whole family costs nothing when
/// no detail route is open.
///
/// **The detail invalidation is load-bearing, not belt-and-braces**, and the
/// reason is counter-intuitive enough to be worth stating. The locale-keyed
/// `MaterialApp` unmounts and remounts the whole subtree, so it is tempting to
/// assume an `autoDispose` provider dies with the old tree and refetches on the
/// new one. Measured: it does **not**. Riverpod keeps the provider alive across
/// a same-frame unmount → remount, so the rebuilt detail page reads the cached
/// previous-locale payload straight back. That same behaviour is why this
/// causes no duplicate round-trip: the remount reuses the provider we just
/// invalidated, so the change costs exactly one fetch, not two.
Future<void> refreshBackendOwnedStrings(WidgetRef ref) async {
  ref.invalidate(venueDetailProvider);
  ref.invalidate(eventDetailProvider);
  ref.invalidate(dailyDropVenueDetailProvider);
  ref.invalidate(dailyDropEventDetailProvider);

  // `holdSpinner: false` — there is no pull-to-refresh spinner to keep up here.
  // It skips the five `.future` reads that exist only for that spinner, which
  // would otherwise construct autoDispose shelves nobody is watching (a guest
  // toggling language on an auth screen, or first-launch IP detection flipping
  // the locale before Discovery has mounted) and fetch them a second time when
  // the section actually appears. The invalidations still land, so a shelf that
  // IS on screen refetches exactly as before.
  await refreshDiscoveryFeed(ref, holdSpinner: false);
}

/// Watches the request locale and drives [refreshBackendOwnedStrings] when it
/// changes. Renders [child] untouched.
///
/// Listens to [apiLocaleCodeProvider], not [localeProvider], on purpose: it is
/// the code actually sent to the backend, so it changes exactly when the
/// server's answer would change and it collapses spellings the API does not
/// distinguish. It also carries a platform-locale fallback, which means a guest
/// who has never picked a language still has a defined value rather than null.
class LocaleRefreshListener extends ConsumerWidget {
  final Widget child;

  const LocaleRefreshListener({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<String?>(apiLocaleCodeProvider, (previous, next) {
      // No same-value guard here, deliberately: `apiLocaleCodeProvider` is a
      // plain `Provider`, so riverpod suppresses the notification when the
      // recomputed code is unchanged and this callback simply never runs. An
      // explicit `previous == next` check would be unreachable code that reads
      // as though it were load-bearing.
      //
      // That suppression is also the reason this listens to the API code rather
      // than to `localeProvider` directly: `Locale('pt')` → `Locale('pt','PT')`
      // is a real state change that both normalize to `pt-PT`, so the backend's
      // answer would be identical. Listening one level down turns that into a
      // no-op instead of a pointless refetch of every open surface.
      //
      // Fire-and-forget, and deliberately non-fatal. This is a background
      // best-effort refresh triggered by a UI gesture — a shelf that fails to
      // refetch should render its own error state (which is exactly what
      // `refreshDiscoveryFeed`'s `_holdSpinner` already assumes: it swallows
      // per-task errors for the same reason). Letting it escape here would
      // surface an unhandled async error from an action the user experiences
      // as "I changed the language".
      unawaited(
        refreshBackendOwnedStrings(ref).catchError((
          Object error,
          StackTrace _,
        ) {
          debugPrint('[LocaleRefreshListener] refresh failed: $error');
        }),
      );
    });

    return child;
  }
}
