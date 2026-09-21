// PROD-4005 — the allowlist of destinations a server-supplied feed CTA may
// send the user to.
//
// **This is deliberately NOT `AppRoutes._isAllowedDeepLinkPath`.** That set
// mirrors the AASA / Android intent-filter claims — "paths the OS hands us" —
// which is a different question from "places a banner may send someone". It
// admits `/auth/callback`, `/activate`, `/reset-password` and
// `/integrations/instagram`, and it is prefix-matched, so `/chat/<anything>`
// and `/venues/<anything>` pass. Correct for deep links; wrong here.

import '../../../../core/router/app_router.dart';

/// Routes a feed `action.route` may name.
///
/// Exact strings only — no prefixes, no patterns, no parameterised entries.
/// One consequence both sides of the contract hold explicitly: a **new
/// destination** is a backend change *plus* an entry here *plus* an app
/// release. Only new *instances* of a route already in this set are
/// backend-only.
///
/// (A campaign deep link parameterised by key does not need a pattern entry:
/// the backend splits it into an exact `route` plus a data-only `params` map
/// that is never matched against, so one entry covers every campaign forever.
/// That field lands with PROD-4001 and is a no-op for this set.)
const Set<String> kFeedActionRoutes = {
  AppRoutes.chat, // '/chat'
  AppRoutes.mapa, // '/map'
  // '/shelves/near-you' — the `venue_grid`'s "ver mais" (PROD-4108, D137).
  //
  // Spelled through `SeeMoreShelf.nearYouPlaces.routePath` so this entry and the
  // page's own route cannot drift; the backend emits the same literal from a
  // single constant on its side, confirmed against what its composer actually
  // produces rather than what it intends: no trailing slash, all lowercase, no
  // query string, and `params: null`.
  //
  // ⚠️ That exactness is the contract. Any of `/shelves/near-you/`,
  // `/Shelves/near-you` or `/shelves/near-you?scope=city` would **silently hide
  // the CTA** rather than erroring — which is rule 2 working correctly, and is
  // the first thing to check if the grid ever renders its title with no chevron.
  _nearYouShelfRoute,
  // '/shelves/editor-picks' and '/shelves/recommended' — the two `zine_grid`
  // "ver mais" destinations (PROD-4118).
  //
  // Both are **pages that already exist**, which is the whole reason the Zines
  // page needed no new CTA plumbing: the backend can point a grid at either
  // without an app release, because this set already admits them. The third
  // grid, `grid-featured`, sends `button: null` — it replaces the Highlighted
  // shelf, which has no see-all page at all.
  //
  // Verified against what the backend actually emits, not what it intends: a
  // live staging page returns `route: "/shelves/recommended"`, `params: null` —
  // no trailing slash, all lowercase, no query string.
  _editorPicksShelfRoute,
  _recommendedShelfRoute,
  // PROD-4447 — the three destinations a *Pessoas* banner may name.
  //
  // ⚠️ **They qualify only because all three screens already ship and already
  // do what a banner would promise** (D19): a route joins this set in the
  // release that makes its destination worth linking to, never in the release
  // where someone first imagines a banner for it. The set matches a **path**,
  // not a capability — it cannot tell "this route exists" from "this route does
  // what the banner says" — so an early entry is a standing promise that every
  // future banner aimed at that path is safe on this build, and it cannot be
  // withdrawn without a release. Do not add speculative entries.
  //
  // ⚠️ And since PROD-4446 a route this set does not contain makes the whole
  // banner **vanish silently**, so the backend keeps a checked-in mirror of this
  // list with a CI test. Two obligations follow: tell them when entries land,
  // and never remove one as routine cleanup — that direction is silent for them
  // and kills a live banner for everyone on the new build.
  _findPeopleRoute,
  _findPeopleContactsRoute,
  _editProfileRoute,
};

/// `/shelves/near-you`, via the enum that owns the path.
///
/// A `const` indirection because [kFeedActionRoutes] is `const` and
/// `SeeMoreShelf.nearYouPlaces.routePath` is a getter — but the value is
/// asserted against that getter in `feed_action_routes_test.dart`, so the two
/// cannot diverge without a test failing.
const String _nearYouShelfRoute = '/shelves/near-you';

/// `/shelves/editor-picks`, via the enum that owns the path (PROD-4118).
///
/// Same `const` indirection and the same guarantee as [_nearYouShelfRoute]: the
/// literal is asserted against `SeeMoreShelf.editorPicks.routePath` in
/// `feed_action_routes_test.dart`, so renaming the slug on the page breaks the
/// test rather than silently hiding the chevron.
const String _editorPicksShelfRoute = '/shelves/editor-picks';

/// `/find-people`, via the constant that owns the path (PROD-4447).
///
/// Same `const` indirection and the same guarantee as [_nearYouShelfRoute]: the
/// literal is asserted against `AppRoutes.findPeople` in
/// `feed_action_routes_test.dart`, so renaming the route breaks a test rather
/// than silently deleting every banner that points at it.
const String _findPeopleRoute = '/find-people';

/// `/find-people/contacts` — the contact-match screen (PROD-4447).
const String _findPeopleContactsRoute = '/find-people/contacts';

/// `/profile/edit` (PROD-4447).
const String _editProfileRoute = '/profile/edit';

/// `/shelves/recommended`, via the enum that owns the path (PROD-4118).
const String _recommendedShelfRoute = '/shelves/recommended';

/// Whether [route] may be navigated to from a feed CTA.
///
/// Compares the **raw string**, byte for byte. It deliberately does not parse
/// to a `Uri` and compare `uri.path`, because that would accept every one of
/// these as "the route `/chat`":
///
///   `/chat?search=<q>` · `https://evil.example/chat` · `/chat#x`
///
/// The first is not hypothetical. `/chat?search=<q>` **auto-sends `<q>` as the
/// user's own message** (`app_router.dart`, PROD-2315: the route reads
/// `state.uri.queryParameters['search']` into `autoSendMessage`). A `uri.path`
/// comparison would therefore turn a backend-controlled CTA into arbitrary
/// message injection — navigation becoming behaviour.
///
/// Trailing slashes, case differences and percent-encoding are rejected for
/// the same reason: each is a near-miss that looks like an allowed route to a
/// normaliser but is a different string, and the safe direction on a
/// server-supplied value is to hide the CTA (rule 2) rather than guess.
bool isAllowedFeedActionRoute(String? route) =>
    route != null && kFeedActionRoutes.contains(route);
