import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../data/models/daily_drop.dart';

/// Which **local entity**, if any, a ready Daily Drop resolves to.
///
/// PROD-2908 — extracted so the entry points that open a drop could no longer
/// drift; they had each inlined the same `itemType`/`venueId`/`eventId`
/// branching and had already diverged.
///
/// PROD-3951 — this used to be a *routing* classifier: a venue-backed drop
/// opened `/venues/{id}`, an event-backed one `/events/{id}`, and only a drop
/// with no local entity got a page of its own. Every ready drop now opens the
/// Daily Drop detail page, so the classification no longer decides **where** a
/// drop opens — it decides what the drop page can *do* once it's there: which
/// detail to fetch, which save button and thumbs to build, which URL to share,
/// and whether the CTA walks onto the entity or opens an external link.
///
/// That is why it survived the routing collapse instead of being deleted with
/// it, and why the third case is now named for what it is (no entity) rather
/// than for the screen it used to select.
sealed class DailyDropEntity {
  const DailyDropEntity();
}

/// A place pick backed by a local venue.
final class DailyDropVenue extends DailyDropEntity {
  final String venueId;
  const DailyDropVenue(this.venueId);
}

/// A pick backed by a local event.
final class DailyDropEvent extends DailyDropEntity {
  final String eventId;
  const DailyDropEvent(this.eventId);
}

/// A ready pick with **no** local venue or event — a raw editorial /
/// Google-Places / web-search pick, carrying only a `google_place_id` or an
/// `external_url`. 0.05 % of drops (87 of 180,657 measured over 60 days), but
/// it is a real path: the drop still renders a card on the feed, so the page
/// must render it rather than fall through to an empty state.
final class DailyDropNoEntity extends DailyDropEntity {
  const DailyDropNoEntity();
}

/// Classify a ready [drop] by the local entity it resolves to.
DailyDropEntity resolveDailyDropEntity(DailyDrop drop) {
  final isVenue =
      (drop.itemType == 'place') ||
      (drop.itemType == null && drop.eventId == null);
  if (isVenue && drop.venueId != null) return DailyDropVenue(drop.venueId!);
  if (drop.eventId != null) return DailyDropEvent(drop.eventId!);
  return const DailyDropNoEntity();
}

/// Push the Daily Drop detail page for a ready [drop] — the single navigation
/// path for every entry point, so they cannot drift.
void pushDailyDropDestination(BuildContext context, DailyDrop drop) {
  final (path, extra) = dailyDropDestinationRoute(drop);
  context.push(path, extra: extra);
}

/// The route a ready [drop] opens at, as a `(path, extra)` pair.
///
/// PROD-3951 — **always** the Daily Drop detail page, for every ready drop.
/// This one function is the chokepoint for all three entry points — the
/// Discovery card tap (`daily_drop_section.dart`), the `/drop` deep link
/// resolved through `discovery_screen.dart`, and the `/recommendations/:id`
/// push resolver — so they change together rather than one at a time.
///
/// The drop travels as GoRouter `extra`, which is what makes the page free of
/// a fetch: the resolver already holds the model. It is also why the route is
/// push-only — a cold web load or browser refresh carries no `extra` and the
/// route redirects to `/drop`, which re-resolves today's drop and re-pushes
/// the page. Accepted for v1 (browsing historic drops is deliberately not a
/// product goal yet); see PROD-3951.
///
/// PROD-3730 — split out of [pushDailyDropDestination] so a caller holding a
/// [GoRouter] rather than a live [BuildContext] can navigate the same way. The
/// `/recommendations/:id` resolver needs that: it navigates *after* replacing
/// itself with Discovery, at which point its own context is gone.
///
/// The `?from=daily-drop&dropId=&dropDate=` attribution params are gone with
/// the venue/event branches (PROD-2785 / PROD-3439). They existed to tell the
/// *entity* page it was being viewed as a drop — so it could wear the branded
/// header and attribute its share to the recommendation. The drop page is that
/// surface now: it reads the drop straight off `extra`, so there is nothing
/// left to thread through a URL. PROD-3952 removes the plumbing that read them.
(String, Object?) dailyDropDestinationRoute(DailyDrop drop) {
  final id = Uri.encodeComponent(drop.recommendationId ?? 'unknown');
  return ('/drop/detail/$id', drop);
}
