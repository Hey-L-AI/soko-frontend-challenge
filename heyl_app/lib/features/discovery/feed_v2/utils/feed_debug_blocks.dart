// PROD-4288 — a synthetic `unknown_area` block for the admin debug panel.
//
// **Why this exists.** The real block is emitted by PROD-4290, which is not
// built. Without this, PROD-4288 ships code nobody can look at — and it is
// being delivered on a release branch whose whole purpose is that Zé tests it
// before it reaches develop.
//
// ⚠️ **It goes through `FeedBlock.fromJson`, not a hand-built object.** A
// toggle that constructs `FeedBlockUnknownArea` directly would prove the widget
// draws, and nothing about the thing that actually ships: the parser is half
// the contract, and it is the half with the tolerant paths (a suggestion
// missing `name`, a malformed entry being dropped). Rendering a different tree
// from the production one is how a debug affordance passes while the real
// feature is broken.
//
// **Remove this when PROD-4290 is on staging.** It is a scaffold, not a
// feature.

import '../../../../data/models/feed_home.dart';

/// The four launch-coverage cities, with the real coordinates the onboarding
/// step uses.
///
/// ⚠️ **The `city_id`s are deliberately fake.** The app has no source of seeded
/// city UUIDs — that is the whole reason `suggestions[]` carries them from the
/// backend. So a tap here sets a scope whose `city_id` will not resolve
/// server-side, the backend ignores an unresolvable id and falls through to the
/// coordinates, and those ARE real: the feed genuinely moves to that city. The
/// flow is exercised end to end; only the id is a stand-in.
const List<Map<String, Object>> _kDebugSuggestions = [
  {
    'city_id': '00000000-0000-4000-8000-000000000001',
    'label': 'Lisboa, PT',
    'name': 'Lisboa',
    'latitude': 38.7223,
    'longitude': -9.1393,
    'country_code': 'PT',
    'country_name': 'Portugal',
  },
  {
    'city_id': '00000000-0000-4000-8000-000000000002',
    'label': 'Porto, PT',
    'name': 'Porto',
    'latitude': 41.1579,
    'longitude': -8.6291,
    'country_code': 'PT',
    'country_name': 'Portugal',
  },
  {
    'city_id': '00000000-0000-4000-8000-000000000003',
    'label': 'Rio de Janeiro, BR',
    'name': 'Rio de Janeiro',
    'latitude': -22.9068,
    'longitude': -43.1729,
    'country_code': 'BR',
    'country_name': 'Brasil',
  },
  {
    'city_id': '00000000-0000-4000-8000-000000000004',
    'label': 'CDMX, MX',
    'name': 'Ciudad de México',
    'latitude': 19.4326,
    'longitude': -99.1332,
    'country_code': 'MX',
    'country_name': 'México',
  },
];

/// The block the debug toggle injects, parsed from the wire shape agreed with
/// the backend.
///
/// Copy is hardcoded English like every other admin debug surface: the real
/// block's copy is backend-localized (D7) and ships no ARB key, so there is
/// nothing to translate here and inventing keys for a dev tool would put an
/// entry in `intl_es.arb` — generated, not hand-editable — behind a control no
/// user can reach.
FeedBlock debugUnknownAreaBlock() => FeedBlock.fromJson(const {
  'id': 'debug-unknown-area',
  'type': 'unknown_area',
  'title': "I don't know this area",
  'subtitle': 'Choose another area to see more results',
  'suggestions': _kDebugSuggestions,
});

/// The `sign_in_gate` block the debug toggle injects (PROD-4520).
///
/// ⚠️ **This is the real wire shape, copied from staging**, not an invention:
///
/// ```
/// GET /feed/home?filter=people   (guest)
/// -> {"blocks": [{"id": "sign-in-gate-people", "type": "sign_in_gate",
///                 "eyebrow": null, "title": null, "subtitle": null,
///                 "blurred": false, "run_id": null}], "next_cursor": null}
/// ```
///
/// Through `FeedBlock.fromJson` for the reason the file header gives: the
/// parser is half the contract, and a hand-built `FeedBlockSignInGate` would
/// prove the widget draws while telling us nothing about the parse.
///
/// Unlike [debugUnknownAreaBlock] there is no copy to hardcode — the app owns
/// every word of this block already, so the payload really is just `{id, type}`.
///
/// ⚠️ **Nothing in `lib/` calls this since PROD-4501.** The forced `guestGate`
/// state that injected it went with the debug tab; this stayed because it
/// belongs to PROD-4520 rather than to that tab, and because
/// `feed_guest_sign_in_gate_test.dart` uses it as the one place the gate's wire
/// shape is written down. Kept in `lib/` so the fixture and the parser it feeds
/// live on the same side of the test boundary — a copy pasted into the test
/// would drift from the real payload without anything noticing.
FeedBlock debugSignInGateBlock() => FeedBlock.fromJson(const {
  'id': 'sign-in-gate-people',
  'type': 'sign_in_gate',
});
