// PROD-4005 (umbrella PROD-3998) — models for the server-driven Discovery
// feed, `GET /api/v1/app/feed/home`.
//
// The backend composes the home page as a typed block list: it decides which
// elements appear, how many items each carries, and in what order. The app is
// a renderer for that list, so changing the home page becomes a backend change
// instead of an app release.
//
// **Hand-written on purpose — do NOT run these through `json_serializable`.**
// The spec formally closes the `type` / `kind` enums whose descriptions tell
// clients to tolerate unknown values, so a generated model would reject exactly
// the payloads the three forward-compatibility rules exist to survive. The
// dev-dependency exists for other things; there are no `.g.dart` files under
// `data/models/` and this file must not add the first one.
//
// The three rules, all load-bearing (spec: `FeedBlock`, `FeedAction`,
// `FeedImage`):
//   1. An unknown block `type` is skipped silently.
//   2. An unknown `action.route` hides that CTA.
//   3. An unknown `FeedImage` asset key renders the banner without its
//      illustration.
// Each lets the backend ship a new element, destination or asset *before* the
// matching app release lands.

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;

import '../../core/utils/hex_color.dart';

/// Content type the feed is composed for. The feed is computed **per filter**
/// and refetched on a filter change (design-doc D4).
///
/// [events] (Eventos) and [venues] (Sítios) are implemented. The app renders
/// [zines] and [people] as disabled buttons (D29) and the backend answers them
/// with a 422, so "not built yet" stays distinguishable from "no data".
enum FeedFilter {
  events('events'),
  venues('venues'),
  zines('zines'),
  people('people');

  const FeedFilter(this.wire);

  /// Value sent as the `filter` query param and echoed back on the response.
  final String wire;

  /// Parses the backend's echo. Falls back to [events] — the response echo is
  /// informational, and an unrecognised value must not fail the page.
  static FeedFilter fromWire(String? value) => FeedFilter.values.firstWhere(
    (f) => f.wire == value,
    orElse: () => FeedFilter.events,
  );

  /// Whether the app can actually render this filter's feed (D15/D29).
  ///
  /// **The whole tile gate, in one place.**
  ///
  /// ⚠️ This must not run ahead of the backend. It is one half of a two-sided
  /// switch — the other is `V0_SUPPORTED_FILTERS` server-side — and the FE-first
  /// order is the bad one: the tile becomes tappable while the request still
  /// 422s. Each filter was added only once the backend was **verified live on
  /// staging, not merely merged** — the deploy lags the merge by minutes.
  /// `venues` waited for PROD-4107, `zines` for PROD-4117, and `people` for
  /// PROD-4449, checked on 2026-09-16: `filter=people` answered **200** with
  /// `run_id: null` / `slate_kind: null`, and a bogus filter's 422 listed
  /// `'events', 'venues', 'zines' or 'people'`.
  /// Every filter is live today. Written as an **exhaustive switch with no
  /// wildcard** rather than `=> true`, so that adding a fifth `FeedFilter` is a
  /// COMPILE ERROR here instead of silently shipping a tappable tile for a feed
  /// the backend may not serve yet. That is the whole job of this getter, and
  /// `=> true` would quietly give it up.
  bool get isEnabledInV0 => switch (this) {
    FeedFilter.events ||
    FeedFilter.venues ||
    FeedFilter.zines ||
    FeedFilter.people => true,
  };
}

/// A typed CTA.
///
/// Two kinds today (v1.129.0):
///
///   * **`route`** — a destination. Reuses the app's existing `go_router`
///     vocabulary, so pointing a banner somewhere new is a backend change —
///     *provided* the destination is already in the app's feed-CTA allowlist.
///     See `feed_action_routes.dart`: validation is a raw-string exact match,
///     never a parsed `Uri.path` compare.
///   * **`next_slate`** (PROD-4237) — pages the feed's next slate. Carries a
///     [cursor], names **no route**, and so never touches the allowlist: there
///     is no destination to allow.
///
/// [type] is deliberately not an enum on either side of the wire. The contract
/// asks clients to tolerate a kind they do not know, and a closed enum forbids
/// exactly that — an unrecognised kind must parse and then be rejected by
/// [FeedButton]'s predicates, which is what renders the button disabled rather
/// than tearing the block away.
@immutable
class FeedAction {
  /// Action kind. Known values: `route`, `next_slate`. Treat an unrecognised
  /// kind exactly like an unrecognised route — hide or disable the CTA.
  final String type;

  /// Raw route string **as received**, or null.
  ///
  /// Deliberately not parsed or normalised here: the allowlist compares this
  /// literal value, and normalising would destroy the very differences that
  /// make a near-miss dangerous.
  ///
  /// ⚠️ **Nullable since PROD-4237**, and that is load-bearing rather than
  /// incidental: a `next_slate` action carries no route, so every call site
  /// that navigates has to say what it does when there is nothing to navigate
  /// to. Making this `String?` is what turned each of those into a compile
  /// error instead of a live button pushing an empty path.
  final String? route;

  /// Opaque cursor for a `next_slate` action — pass it back as the feed's
  /// `cursor` to receive the next slate's first page. **Never parse it.**
  final String? cursor;

  const FeedAction({required this.type, this.route, this.cursor});

  /// Parses an action, never throwing.
  ///
  /// Only [type] is required. A `route` action with no route, or a
  /// `next_slate` with no cursor, parses into a well-formed object that
  /// [FeedButton]'s predicates then refuse — malformed-ness is judged where
  /// "may this be tapped?" is answered, not here. Before PROD-4237 this
  /// returned null for anything without a route string, which silently
  /// discarded every non-route kind.
  static FeedAction? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final type = json['type'];
    if (type is! String) return null;
    final route = json['route'];
    final cursor = json['cursor'];
    return FeedAction(
      type: type,
      route: route is String ? route : null,
      cursor: cursor is String ? cursor : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FeedAction &&
      other.type == type &&
      other.route == route &&
      other.cursor == cursor;

  @override
  int get hashCode => Object.hash(type, route, cursor);
}

/// A block's call to action.
///
/// `enabled: false` renders a **visibly disabled** button and carries no
/// action — it shows the finished design without shipping behaviour that does
/// not exist yet (D24), which beats a live control that does nothing.
///
/// Since PROD-4237 the `feed_end` button is live when a next slate exists:
/// `enabled: true` with a `next_slate` action. A button whose action this app
/// version does not recognise falls back to the disabled rendering — the
/// pre-slate behaviour, reached by construction rather than by a version check.
@immutable
class FeedButton {
  final String label;

  /// Defaults to `true` per the schema. Note this means an *absent* `enabled`
  /// with an absent `action` is a schema-valid "enabled button that goes
  /// nowhere" — see [isLive], which is the only thing callers should use to
  /// decide whether to render a live CTA.
  final bool enabled;

  final FeedAction? action;

  const FeedButton({required this.label, this.enabled = true, this.action});

  /// Whether the button is enabled and carries a well-formed route action.
  ///
  /// **Not sufficient on its own** — the route must also be allowlisted. Use
  /// [routeTarget] at every navigating call site instead; this is exposed only
  /// for tests and diagnostics that want to tell "malformed" apart from "not
  /// allowed".
  bool get hasRouteAction =>
      enabled && action?.type == 'route' && action?.route != null;

  /// The cursor of a well-formed, enabled `next_slate` action — otherwise null.
  ///
  /// PROD-4237. An empty-string cursor is treated as absent: the backend
  /// validates that a `next_slate` action carries one, so an empty value is
  /// malformed, and a request with `cursor: ""` restarts the feed at page 1
  /// rather than advancing it.
  String? get nextSlateCursor {
    final action = this.action;
    if (!enabled || action == null || action.type != 'next_slate') return null;
    final cursor = action.cursor;
    return (cursor != null && cursor.isNotEmpty) ? cursor : null;
  }

  /// Whether this button should render as a live, tappable CTA.
  ///
  /// **Two branches, one predicate.** A route action is live only when the
  /// route is *allowlisted*; a `next_slate` action is live on its own terms
  /// because it names no route, so there is nothing for the allowlist to
  /// answer about — the bypass is structural, not an exception carved out for
  /// one block.
  ///
  /// Keeping both branches here rather than at the call site is the point.
  /// Leaving the allowlist check to each caller is how a CTA eventually
  /// navigates to an un-allowlisted, server-supplied route — and
  /// `/chat?search=<q>` auto-sends that text as the user's message, so
  /// "eventually" is not an acceptable risk. [routeAllowed] is injected rather
  /// than imported to keep this model free of a feature-layer dependency;
  /// callers pass `isAllowedFeedActionRoute`.
  ///
  /// ⚠️ This answers "**render** live?", never "navigate where?". A block that
  /// pushes a route must ask [routeTarget] — `isLive` is true for a paging
  /// action, which has no route to push.
  bool isLive(bool Function(String?) routeAllowed) =>
      (hasRouteAction && routeAllowed(action!.route)) ||
      nextSlateCursor != null;

  /// The route this button navigates to, or **null when it does not navigate**.
  ///
  /// The single accessor every pushing call site uses, and the reason widening
  /// [isLive] for PROD-4237 did not turn three other blocks into live buttons
  /// that push nothing: a banner or grid handed a `next_slate` action gets
  /// null here and renders its CTA dead, exactly as it does for an
  /// un-allowlisted route. One question, one answer, no boolean logic
  /// reassembled per widget.
  String? routeTarget(bool Function(String?) routeAllowed) =>
      hasRouteAction && routeAllowed(action!.route) ? action!.route : null;

  static FeedButton? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final label = json['label'];
    if (label is! String) return null;
    return FeedButton(
      label: label,
      enabled: json['enabled'] as bool? ?? true,
      action: FeedAction.fromJson(json['action'] as Map<String, dynamic>?),
    );
  }
}

/// A banner illustration: an app-bundled asset key, or a remote URL.
///
/// `asset` means the bytes ship *with the app* — no network fetch during the
/// feed's first paint, correct at any DPI, works offline. `url` is the escape
/// hatch that keeps a one-off banner shippable backend-side.
@immutable
class FeedImage {
  /// `asset` or `url`. Kept as a raw string rather than an enum so an unknown
  /// third kind parses instead of throwing — see [isRenderable].
  final String kind;
  final String value;

  const FeedImage({required this.kind, required this.value});

  static const String kindAsset = 'asset';
  static const String kindUrl = 'url';

  /// Bundled asset paths this app version ships, keyed by the backend's asset
  /// key.
  ///
  /// **This is forward-compatibility rule 3.** The backend may name an asset a
  /// given app version has never heard of, and that must cost the illustration
  /// and nothing else. Resolving through an explicit registry — rather than
  /// handing `value` to `Image.asset` — is what makes that true: an unknown key
  /// returns null here instead of throwing a missing-asset error at paint time.
  ///
  /// Populated in PROD-4006. Keys are the backend's, shipped at spec v1.105.0
  /// (`BannerContent.image_key`) — a key that drifts from theirs degrades to
  /// "no illustration", which is invisible in testing and looks exactly like
  /// art that was never shipped, so both sides pin them with tests.
  ///
  /// Both drawings were **already bundled** for other surfaces, so adding the
  /// banners cost no new binaries beyond the map one.
  static const Map<String, String> assetRegistry = <String, String>{
    // Figure with binoculars. Also the profile "discover people" empty state.
    'banner_chat': 'assets/images/illustrations/soko-binoculars.png',
    // Figure with a raised glass. Exported from Figma `7304:24210`.
    'banner_map': 'assets/images/illustrations/soko-with-wine.png',
  };

  /// Resolved bundle path for an `asset` image, or null when unrenderable.
  String? get assetPath => kind == kindAsset ? assetRegistry[value] : null;

  /// Whether this app version knows how to draw this image at all.
  ///
  /// Covers both halves of rule 3: an `asset` whose key we do not ship, and an
  /// unknown `kind` — which the spec does not promise, but the same argument
  /// applies, so a future fourth kind is additive rather than breaking.
  bool get isRenderable => switch (kind) {
    kindUrl => value.isNotEmpty,
    kindAsset => assetPath != null,
    _ => false,
  };

  static FeedImage? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final kind = json['kind'];
    final value = json['value'];
    if (kind is! String || value is! String) return null;
    return FeedImage(kind: kind, value: value);
  }
}

/// Server-supplied colours for one banner.
///
/// **Not in the spec yet** — requested from the backend on 2026-08-26 for
/// v1.106.0, and inert until it lands: every field is nullable, an absent
/// `style` object parses to null, and the widget falls back to the client-side
/// registry. Landing the parser first is deliberate — it is the half that can
/// be written and tested without a round trip, and an unknown extra field on
/// the wire was already a no-op.
///
/// Why colour moved onto the wire after we argued it should not: the original
/// case was "a new banner needs an app release for its art regardless, so a
/// colour field buys nothing the asset key does not already cost." That holds
/// only for `kind: asset`. A `kind: url` illustration needs **no** release, so
/// under the old design a fully backend-authored banner could carry its own
/// artwork and still be stuck with a hardcoded ground. The premise was too
/// narrow, not the reasoning.
///
/// Values are **raw hex as received**, parsed lazily. Keeping the string means
/// a malformed value stays visible for diagnostics instead of collapsing to an
/// indistinguishable null at parse time.
@immutable
class FeedBannerStyle {
  /// Fill behind the whole banner card.
  final String? background;

  /// Fill of the banner's CTA button.
  final String? buttonBackground;

  const FeedBannerStyle({this.background, this.buttonBackground});

  /// Parsed [background], or null when absent or unparseable.
  Color? get backgroundColor => parseHexColor(background);

  /// Parsed [buttonBackground], or null when absent or unparseable.
  Color? get buttonBackgroundColor => parseHexColor(buttonBackground);

  /// Whether this object carries anything usable at all.
  ///
  /// A `style` present but entirely malformed is indistinguishable from an
  /// absent one at the render layer, and both must fall back — so callers ask
  /// this rather than null-checking the object.
  bool get isEmpty => backgroundColor == null && buttonBackgroundColor == null;

  static FeedBannerStyle? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return FeedBannerStyle(
      // Ill-typed values become null rather than throwing: a banner is not
      // worth losing over a colour, and rule 3's posture ("degrade the part,
      // keep the block") applies to presentation generally.
      background: switch (json['background']) {
        final String hex => hex,
        _ => null,
      },
      buttonBackground: switch (json['button_background']) {
        final String hex => hex,
        _ => null,
      },
    );
  }
}

/// One person in an `event_hero`'s optional people-reactions row (D36).
@immutable
class FeedReaction {
  final String userId;
  final String? handle;
  final String? displayName;
  final String? avatarUrl;

  const FeedReaction({
    required this.userId,
    this.handle,
    this.displayName,
    this.avatarUrl,
  });

  static FeedReaction? fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    if (userId is! String) return null;
    return FeedReaction(
      userId: userId,
      handle: json['handle'] as String?,
      displayName: json['display_name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
    );
  }
}

/// One face in a [FeedPersonDetails] row.
///
/// Carries `user_id` and `name` alongside the optional photo **on purpose**: a
/// person with no `avatar_url` must still draw a seeded initial placeholder
/// rather than being dropped. Dropping them would make the cluster disagree
/// with the backend's own copy — "3 pessoas em comum" beside two faces — and
/// the app cannot notice, because it renders [FeedPersonDetails.text] verbatim.
@immutable
class FeedPersonDetailsAvatar {
  /// Placeholder tint seed, and the reason this is required.
  final String userId;
  final String? avatarUrl;

  /// Drives the placeholder's initial letter.
  final String? name;

  const FeedPersonDetailsAvatar({
    required this.userId,
    this.avatarUrl,
    this.name,
  });

  /// Null for an entry with no usable id — skipped rather than throwing, the
  /// same posture as [FeedReaction].
  static FeedPersonDetailsAvatar? fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    if (userId is! String) return null;
    // `is` checks, not casts. A cast failure throws TypeError, which escapes to
    // the block-level catch and turns the WHOLE block into FeedBlockUnknown —
    // so one ill-typed face would silently delete the entire grid. Same lesson
    // [FeedBlock.fromJson] already learned for the envelope.
    final avatarUrl = json['avatar_url'];
    final name = json['name'];
    return FeedPersonDetailsAvatar(
      userId: userId,
      avatarUrl: avatarUrl is String ? avatarUrl : null,
      name: name is String ? name : null,
    );
  }
}

/// The supporting line under a person's handle: up to three faces, then text.
///
/// **Deliberately not named for what fills it.** It carries mutual followers
/// today and may carry shared tastes, a home city or a zine count tomorrow —
/// the backend decides, with no app release. That is why the wire field is
/// `details` and not `social_proof`.
///
/// [text] arrives **backend-localized and final**: the app renders it verbatim
/// and composes no copy of its own — no pluralisation, no name-joining, no
/// counting. [avatars] may be empty while [text] is present; that is a
/// first-class state (a face-less line), not a degradation.
@immutable
class FeedPersonDetails {
  final String text;

  /// Every face the backend sent, in order, **uncapped here**.
  ///
  /// The contract says at most three and the widget renders at most three; the
  /// model keeps what arrived so a test can tell "the backend sent four" from
  /// "the widget drew three". Parsing is not the place to silently discard.
  final List<FeedPersonDetailsAvatar> avatars;

  const FeedPersonDetails({required this.text, this.avatars = const []});

  /// Null when the row should not render at all.
  ///
  /// The backend signals "no row" with `details: null` rather than `{}` or an
  /// empty string — but an empty [text] is treated the same way here, because a
  /// row with faces and nothing to say is not a row.
  static FeedPersonDetails? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final text = json['text'];
    if (text is! String || text.isEmpty) return null;
    final raw = json['avatars'];
    final avatars = raw is List
        ? raw
              .whereType<Map<String, dynamic>>()
              .map(FeedPersonDetailsAvatar.fromJson)
              .whereType<FeedPersonDetailsAvatar>()
              .toList()
        : const <FeedPersonDetailsAvatar>[];
    return FeedPersonDetails(text: text, avatars: avatars);
  }
}

/// One person, as carried by `people_grid`.
///
/// ⚠️ **Deliberately NOT a [FeedItem].** That hierarchy is sealed and its
/// members are *entities you can save, open by item_type, and put in a bundle
/// row* — `feed_item_save.dart`, `feed_item_open.dart` and `feed_bundle_row.dart`
/// all switch over it exhaustively. A person is none of those things: you
/// follow them, you open them at `/u/{handle}`, and no bundle carries them. So
/// adding a member here would turn eight unrelated switches into compile errors
/// and force save/open semantics that have no meaning for a person.
///
/// [handle] is **required, not best-effort**: `/u/{handle}` is the only route to
/// a profile, so a person without one is an untappable card. The backend
/// guarantees it (auto-assigned at insert, enforced by a DB CHECK).
@immutable
class FeedPersonItem {
  final String userId;
  final String handle;
  final String? fullName;
  final String? avatarUrl;

  /// Seeds the follow badge on first paint. The shared follow store owns the
  /// state after that, so these are a starting point and never the truth.
  ///
  /// The backend's suggestion pool currently excludes people the viewer already
  /// follows, so [isFollowing] is false for every row it sends today — but the
  /// card renders the followed state regardless, because that rule may change
  /// and the state comes from the wire rather than being assumed.
  final bool isFollowing;
  final bool requested;
  final bool followsYou;

  /// The optional details row. Null means the row does not render.
  final FeedPersonDetails? details;

  const FeedPersonItem({
    required this.userId,
    required this.handle,
    this.fullName,
    this.avatarUrl,
    this.isFollowing = false,
    this.requested = false,
    this.followsYou = false,
    this.details,
  });

  /// Null when the row lacks a usable id or handle — skipped rather than
  /// throwing, so one malformed person cannot collapse the whole block.
  static FeedPersonItem? fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    final handle = json['handle'];
    if (userId is! String || handle is! String || handle.isEmpty) return null;
    // ⚠️ **`is` checks, never casts, for every optional field.** A cast failure
    // throws TypeError rather than FormatException, and it would escape past
    // [_requiredPersonItems] to the block-level catch — turning one person with
    // `full_name: 123` or `details: []` into a `FeedBlockUnknown` that
    // `renderableFeedBlocks` then drops. The whole grid would vanish because of
    // one bad row, which is precisely what "a malformed person is skipped"
    // exists to prevent. [FeedBlock.fromJson] carries the same warning for the
    // envelope; this is the item-level instance of it.
    //
    // `== true` for the booleans degrades a non-bool to false rather than
    // throwing, which is the same "absent means false" the contract already has.
    final fullName = json['full_name'];
    final avatarUrl = json['avatar_url'];
    final details = json['details'];
    return FeedPersonItem(
      userId: userId,
      handle: handle,
      fullName: fullName is String ? fullName : null,
      avatarUrl: avatarUrl is String ? avatarUrl : null,
      isFollowing: json['is_following'] == true,
      requested: json['requested'] == true,
      followsYou: json['follows_you'] == true,
      details: details is Map<String, dynamic>
          ? FeedPersonDetails.fromJson(details)
          : null,
    );
  }
}

/// **Reserved per-bundle presentation slot — ignored by v0** (D35).
///
/// Which fields a bundle's lines show may vary per bundle. That behaviour is
/// deliberately not designed yet; the slot exists so adding the real rules
/// later is additive rather than breaking.
@immutable
class FeedBundleDisplay {
  final List<String>? lineFields;

  const FeedBundleDisplay({this.lineFields});

  static FeedBundleDisplay? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final raw = json['line_fields'];
    return FeedBundleDisplay(
      lineFields: raw is List ? raw.whereType<String>().toList() : null,
    );
  }
}

/// One entity carried by a block's `items` (PROD-4108).
///
/// A **sealed** base over the two item shapes the feed emits, so a `switch` on
/// an item is exhaustiveness-checked the same way `FeedBlock` is: adding a third
/// entity type fails the build until every renderer handles it.
///
/// It carries only what is common to *every* item and needed by the code that
/// must stay type-agnostic — the impression rails, the dedup gates, the
/// highlight resolver, the list keys. **Everything else lives on the subtype**,
/// because a base that grew `title` would push callers toward reading a
/// display field without deciding which entity they are showing, which is the
/// D34 mistake in another shape.
///
/// ⚠️ **`id` is unique per entity, not per row.** The same venue can legitimately
/// appear in two blocks on one page (D82), so anything keyed on an item must
/// fold in the block/surface too — see `ImpressionScrollTracker.scopeId`.
@immutable
sealed class FeedItem {
  /// Entity id. The join key for impressions, clicks, saves and signals.
  String get id;

  /// Cover image, or null. Named on the base because every card surface needs
  /// a thumbnail and none of them care which entity it belongs to.
  String? get imageUrl;

  const FeedItem();
}

/// An event as carried by `event_hero` and `bundle` blocks.
///
/// A superset assembled from the existing event field vocabulary rather than a
/// new invention, so the app's current card widgets still apply.
@immutable
class FeedEventItem extends FeedItem {
  @override
  final String id;
  final String title;
  @override
  final String? imageUrl;
  final String? descriptionShort;
  final DateTime startsAt;
  final DateTime? endsAt;

  /// Whether the start time is precise, or was defaulted to midnight by the
  /// crawler. Same semantics `core/utils/event_time.dart` already encodes —
  /// hide the time component when false.
  final bool timeKnown;

  final String? venueId;
  final String? venueName;

  /// Sub-venue section (room, hall, stage). Display-only; the full location
  /// reads `{venueName} - {venueSection}`.
  final String? venueSection;

  final String? city;

  /// Localized display label for `categories.first` (e.g. `Música`).
  /// **Render exactly as received** — it is not a slug; do not humanize or
  /// title-case it.
  final String? category;

  /// Canonical, un-localized taxonomy categories. Use these for client-side
  /// logic; use [category] for display.
  final List<String> categories;

  /// **The display contract for price** — already localized and formatted by
  /// the backend, null when there is nothing to show.
  ///
  /// Render exactly as received and never re-format: the backend owns the
  /// separator (an en dash, U+2013), places the currency once on the locale's
  /// side of a range, and lets `price_type == "free"` win over a stray amount
  /// because real data contradicts itself.
  final String? priceLabel;

  /// Raw price fields. Available for client-side logic; **not** a display
  /// source — use [priceLabel]. The app renders no price from these.
  final double? priceMin;
  final double? priceMax;
  final String? currency;
  final String? priceType;

  final String? url;

  const FeedEventItem({
    required this.id,
    required this.title,
    required this.startsAt,
    this.imageUrl,
    this.descriptionShort,
    this.endsAt,
    this.timeKnown = true,
    this.venueId,
    this.venueName,
    this.venueSection,
    this.city,
    this.category,
    this.categories = const [],
    this.priceLabel,
    this.priceMin,
    this.priceMax,
    this.currency,
    this.priceType,
    this.url,
  });

  /// Throws [FormatException] when a required field is missing or ill-typed.
  ///
  /// Deliberately strict: `items` is required on both block types that carry
  /// events, so a malformed item means a malformed *block*. The caller turns
  /// that into [FeedBlockUnknown] rather than rendering a half-empty card.
  factory FeedEventItem.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final title = json['title'];
    final startsAt = json['starts_at'];
    if (id is! String || title is! String || startsAt is! String) {
      throw const FormatException(
        'FeedEventItem requires id, title and starts_at',
      );
    }
    final rawCategories = json['categories'];
    return FeedEventItem(
      id: id,
      title: title,
      startsAt: DateTime.parse(startsAt),
      imageUrl: json['image_url'] as String?,
      descriptionShort: json['description_short'] as String?,
      // Tolerant: an ill-typed or unparseable `ends_at` costs the end time,
      // not the event. `starts_at` above is required, so it stays strict.
      endsAt: switch (json['ends_at']) {
        final String raw => DateTime.tryParse(raw),
        _ => null,
      },
      timeKnown: json['time_known'] as bool? ?? true,
      venueId: json['venue_id'] as String?,
      venueName: json['venue_name'] as String?,
      venueSection: json['venue_section'] as String?,
      city: json['city'] as String?,
      category: json['category'] as String?,
      categories: rawCategories is List
          ? rawCategories.whereType<String>().toList()
          : const [],
      priceLabel: json['price_label'] as String?,
      priceMin: (json['price_min'] as num?)?.toDouble(),
      priceMax: (json['price_max'] as num?)?.toDouble(),
      currency: json['currency'] as String?,
      priceType: json['price_type'] as String?,
      url: json['url'] as String?,
    );
  }

  /// Full location line, per `venue_section`'s spec note.
  String? get locationLine {
    if (venueName == null) return null;
    if (venueSection == null) return venueName;
    return '$venueName - $venueSection';
  }
}

/// A venue as carried by `venue_grid` and `bundle` blocks (PROD-4108).
///
/// Assembled from the existing venue field vocabulary rather than invented, so
/// the app's venue surfaces apply unchanged. **Not** the legacy
/// `/feed/near-you/places` item shape — different surface, different model, even
/// though the rows underneath are the same venues.
///
/// Three fields are absent on purpose, and all three are decisions rather than
/// omissions:
///   * **Opening hours** (D134). 7–16 % coverage in production, and stored as
///     locale-formatted display strings rather than structured times — so "open
///     now" would be a parsing problem stacked on a coverage problem. A row
///     field blank for ~9 venues in 10 reads as broken, not sparse.
///   * **The attribution line** — deferred until bundles are done properly.
///   * **A tap action.** [FeedEventItem] carries none either: the route comes
///     from the *block's* `item_type` (`feed_item_open.dart`), so a per-item
///     action would be a second way to state one fact.
@immutable
class FeedVenueItem extends FeedItem {
  @override
  final String id;

  /// Display name. Called `name` on the wire, not `title` — the two item types
  /// name their headline field differently and the parser mirrors each.
  final String name;

  @override
  final String? imageUrl;

  /// Localized display label for the venue's **primary** type — what the venue
  /// *is*, not what it also contains (ADR-043). **Render exactly as received**;
  /// it is not a slug, so do not humanize or title-case it.
  final String? type;

  /// Canonical, un-localized taxonomy types, **primary first**. Use these for
  /// client-side logic; use [type] for display.
  final List<String> types;

  /// Neighbourhood, already resolved. 92–99 % covered in production, which is
  /// why it is a row field where opening hours are not.
  final String? neighborhood;

  final String? city;

  /// ⚠️ **Parsed and deliberately never rendered.**
  ///
  /// Not merely "the design doesn't use it": the value is **coarser than it
  /// looks**. It comes from the same ranked cache `/feed/near-you/places` uses,
  /// and that cache is keyed on the caller's **geohash-5 cell — roughly 5 km**.
  /// Ranking *and* the stored distances belong to whoever warmed the cell, so
  /// two callers inside one cell get that cell's distances rather than their
  /// own: a tile can say 400 m for a venue 3 km from the person reading it.
  ///
  /// The legacy shelf's `nearYouDistanceLabel` has the same imprecision today.
  /// If a surface ever wants to show distance, that is the moment to raise the
  /// shelf ticket — not the moment to wire up this field.
  final double? distanceKm;

  const FeedVenueItem({
    required this.id,
    required this.name,
    this.imageUrl,
    this.type,
    this.types = const [],
    this.neighborhood,
    this.city,
    this.distanceKm,
  });

  /// Throws [FormatException] when a required field is missing or ill-typed.
  ///
  /// Deliberately strict, exactly as [FeedEventItem.fromJson] is: `items` is
  /// required on both block types that carry venues, so a malformed item means
  /// a malformed *block*. The caller turns that into [FeedBlockUnknown] rather
  /// than rendering a half-empty tile.
  factory FeedVenueItem.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || name is! String) {
      throw const FormatException('FeedVenueItem requires id and name');
    }
    final rawTypes = json['types'];
    return FeedVenueItem(
      id: id,
      name: name,
      imageUrl: json['image_url'] as String?,
      type: json['type'] as String?,
      types: rawTypes is List
          ? rawTypes.whereType<String>().toList()
          : const [],
      neighborhood: json['neighborhood'] as String?,
      city: json['city'] as String?,
      distanceKm: (json['distance_km'] as num?)?.toDouble(),
    );
  }
}

/// A **zine** — a public user list — as carried by `zine_grid` and `bundle`
/// blocks (PROD-4118, spec v1.119.0).
///
/// ⚠️ **The cover is a recipe, not an image**, and this is the field group most
/// likely to be got wrong. The eight `cover*` fields feed
/// [ZineCoverRecipe.fromFields] — the same resolver every other zine surface
/// uses — which is what keeps a feed card identical to the zine it opens into.
/// Flattening them to one URL renders a grid of flat colour. Measured against
/// staging's live payload: **18 of 34** items carry `cover_color: null` and
/// **32 of 34** carry `preview_image_url`, so the PROD-2040 fallback branch is
/// the common path, not an edge case. Drop it and half the grid goes blank.
///
/// **No tap action**, as with [FeedEventItem] and [FeedVenueItem]: the client
/// derives the route from the block's declared `item_type` (D34/D136).
@immutable
class FeedZineItem extends FeedItem {
  @override
  final String id;

  /// Display name. `name`, like a venue and unlike an event's `title` — the
  /// parser mirrors each type's own wire vocabulary rather than normalising.
  final String name;

  /// ⚠️ **Always `null`, deliberately.** The sealed base declares this so every
  /// card surface can ask for a thumbnail without knowing the entity — but a
  /// zine has no single image, it has a recipe, and any of the three URL fields
  /// below is the *wrong* answer on its own. Returning one here would let a
  /// caller that reads the base getter paint flat colour where a photo belongs,
  /// silently and only for zines. Surfaces branch on the sealed type instead.
  @override
  String? get imageUrl => null;

  /// `background_color`, `item_image` or `uploaded_photo`. An unknown value
  /// resolves to `background_color` — the resolver's own fallback, not ours.
  final String? coverType;

  /// One of the six Soko brand colours. **`null` means "pick one from the id"**,
  /// not "no colour" — the resolver hashes [id] for a stable choice.
  final String? coverColor;

  final String? coverTexture;

  /// A brand colour, `ink`, or `paper`.
  final String? coverTextColor;

  /// Proxied uploaded-cover photo, and legacy item images on rows whose
  /// `cover_type` was later backfilled to `background_color`.
  final String? coverImageUrl;

  /// ⚠️ **Read FIRST by the `item_image` branch.** Server-resolved, already
  /// proxied. Render only [coverImageUrl] and every item-image cover falls
  /// through to flat colour — 5 of 34 items on staging today.
  final String? coverItemImageUrl;

  /// The PROD-2040 fallback: the newest item's photo, applied in exactly one
  /// case — `background_color` with **no** `cover_color`. The backend already
  /// applies "a chosen cover suppresses the preview", so it is null whenever
  /// [coverImageUrl] is set.
  final String? previewImageUrl;

  final bool coverShowTitle;
  final bool coverShowTexture;
  final bool coverShowLogo;

  /// The owner's display name for the row's meta line, falling back to the
  /// handle. Non-null on all 34 live items sampled, but nullable on the wire.
  final String? curatorName;

  /// The owner's avatar, for the row's attribution dot (BE v1.123.0).
  ///
  /// **Rendered raw.** The stored value is already an absolute backend
  /// image-proxy URL — `avatar_url` has one writer, the upload handler, which
  /// stores `ImageStore.build_proxy_url()`'s output — and every other owner
  /// projection emits it unwrapped. Rebasing it here would make the feed the
  /// only surface that does.
  ///
  /// `null` when the owner uploaded no photo, which is the common case: the
  /// row then shows the person glyph rather than an initial (D327).
  ///
  /// **The only curator field beyond the name.** The backend's batch loader
  /// also returns the owner's id and `is_expert`, and a pre-merge branch
  /// carried `curator_id` — it was dropped before landing because nothing on
  /// this surface consumes it (the dot only draws when there IS a photo, so
  /// its seeded fallback tint never shows). Don't parse either speculatively;
  /// the contract is additive and asking costs the same later.
  final String? curatorAvatarUrl;

  /// Live item count. **Never zero on this surface** — an empty zine is a draft
  /// and is dropped before composition (confirmed: live range 1–28).
  final int? itemCount;

  const FeedZineItem({
    required this.id,
    required this.name,
    this.coverType,
    this.coverColor,
    this.coverTexture,
    this.coverTextColor,
    this.coverImageUrl,
    this.coverItemImageUrl,
    this.previewImageUrl,
    this.coverShowTitle = true,
    this.coverShowTexture = true,
    this.coverShowLogo = true,
    this.curatorName,
    this.curatorAvatarUrl,
    this.itemCount,
  });

  /// Throws [FormatException] when a required field is missing or ill-typed —
  /// deliberately strict, exactly as its two siblings are. A malformed item
  /// means a malformed *block*, which the caller degrades to
  /// [FeedBlockUnknown] rather than rendering a half-empty tile.
  ///
  /// Everything else is tolerant: an unrecognised `cover_type` or `cover_color`
  /// is carried through as-is and degrades **in the resolver**, which already
  /// has deterministic fallbacks for both. Rejecting them here would throw away
  /// a whole grid over a cover the app knows how to draw anyway.
  factory FeedZineItem.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || name is! String) {
      throw const FormatException('FeedZineItem requires id and name');
    }
    return FeedZineItem(
      id: id,
      name: name,
      coverType: json['cover_type'] as String?,
      coverColor: json['cover_color'] as String?,
      coverTexture: json['cover_texture'] as String?,
      coverTextColor: json['cover_text_color'] as String?,
      coverImageUrl: json['cover_image_url'] as String?,
      coverItemImageUrl: json['cover_item_image_url'] as String?,
      previewImageUrl: json['preview_image_url'] as String?,
      // Default true, matching the backend column defaults — an older payload
      // missing them must show the full cover, not a stripped one.
      coverShowTitle: json['cover_show_title'] as bool? ?? true,
      coverShowTexture: json['cover_show_texture'] as bool? ?? true,
      coverShowLogo: json['cover_show_logo'] as bool? ?? true,
      curatorName: json['curator_name'] as String?,
      curatorAvatarUrl: json['curator_avatar_url'] as String?,
      itemCount: json['item_count'] is int ? json['item_count'] as int : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

/// One block of the server-driven feed.
///
/// A Dart 3 **sealed** hierarchy, so `switch` over a `FeedBlock` is checked for
/// exhaustiveness at compile time: adding a member here fails the build until
/// every dispatcher handles it — which is precisely where PROD-4006 works.
///
/// Two properties of that guarantee, worth stating because both are easy to
/// lose by accident:
///   * It holds only while **no `switch` has a `default` / `_` arm.** One
///     wildcard silently re-opens the whole thing.
///   * It fires when a new **Dart subclass** is added, not when the *backend*
///     adds a new wire type. A new wire type is caught at runtime, by
///     [FeedBlockUnknown].
sealed class FeedBlock {
  /// **Unique per occurrence, not per type** — `event_hero` appears twice in
  /// the v0 layout with ids `hero-lead` / `hero-tail`.
  ///
  /// This is the impression key (PROD-4003) *and* the list key *and* the
  /// paging dedupe key. Never key on [type] for any of those.
  final String id;

  /// Backend-localized kicker above the block ("Em destaque" on the first
  /// hero, absent on the second). Presentation travels with the block, not the
  /// type — which is why the two heroes are one block type, not two.
  final String? eyebrow;

  final String? title;
  final String? subtitle;

  /// The backend decides gating — guest and soft-gating policy lives
  /// server-side (D10). The client renders the treatment and applies **no**
  /// policy of its own; any guest `if` in the feed path is a bug.
  ///
  /// ⚠️ **One deliberate exception exists: `create_cta` (PROD-4319).** Its two
  /// CTAs submit to endpoints that reject a guest token, so the block is
  /// dropped for guests in `renderableFeedBlocks`. The backend built the
  /// server-side gate this rule calls for and Zé ruled it out — the app owns
  /// this one. It is an exception to the rule above, not an application of it,
  /// and it is the only one; a second would mean the policy has moved
  /// client-side by accident rather than by decision.
  final bool blurred;

  /// The `discovery_runs` id of the page fetch that served THIS block
  /// (PROD-4303, contract v2). Per-block rather than per-page so engagement
  /// events keep pointing at the run that actually ranked the block after a
  /// `loadMore` lands a newer page (the latest-page-attribution gap).
  ///
  /// **Forward-compatible: the backend does not send `run_id` per block yet**,
  /// so this is null today and the provider's per-page `blockRunIds` map is the
  /// live fallback. When present on the wire, it wins.
  final String? runId;

  const FeedBlock({
    required this.id,
    this.eyebrow,
    this.title,
    this.subtitle,
    this.blurred = false,
    this.runId,
  });

  /// The wire `type` this block was parsed from. For [FeedBlockUnknown] this
  /// is whatever the backend sent, which is the point.
  String get type;

  /// Parses one block, never throwing.
  ///
  /// Anything this app version cannot render becomes a [FeedBlockUnknown] that
  /// still carries its `id`. That matters more than it looks: the paging guard
  /// counts *response* ids, so an unknown block still advances the feed rather
  /// than reading as "nothing new" and truncating it.
  static FeedBlock fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final type = json['type'];
    if (id is! String || type is! String) {
      // No id means we cannot dedupe or key it. Synthesize a stable-enough
      // placeholder so one malformed envelope can't collapse the page.
      return FeedBlockUnknown(
        id: id is String ? id : '',
        rawType: type is String ? type : '',
        parseError: 'block envelope requires id and type',
      );
    }

    try {
      // Read INSIDE the try. These are casts, and a cast failure throws
      // TypeError, not FormatException — reading them above the try (as this
      // first did) let one ill-typed envelope field escape and tear down the
      // whole page.
      final eyebrow = json['eyebrow'] as String?;
      final title = json['title'] as String?;
      final subtitle = json['subtitle'] as String?;
      final blurred = json['blurred'] as bool? ?? false;
      final runId = json['run_id'] as String?;

      switch (type) {
        case 'event_hero':
          return FeedBlockEventHero(
            id: id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            blurred: blurred,
            runId: runId,
            items: _requiredEventItems(json),
            reactions: _optionalReactions(json),
          );
        case 'bundle':
          final itemType = json['item_type'];
          if (itemType is! String) {
            throw const FormatException('bundle requires item_type');
          }
          return FeedBlockBundle(
            id: id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            blurred: blurred,
            runId: runId,
            itemType: itemType,
            items: _requiredItems(json, itemType),
            // Both are `required` on the wire from v1.110.0, and both are
            // parsed as optional here on purpose — see the field docs. A
            // backend that predates the change still renders correctly
            // instead of throwing the block away.
            // `containsKey`, not a null-check on the value: an explicit
            // `"highlighted_item_ids": null` is a NEW-shape response saying
            // something malformed, and must not be read as an old one.
            highlightedItemIds: json.containsKey('highlighted_item_ids')
                ? _optionalIdList(json['highlighted_item_ids'])
                : null,
            totalCount: json['total_count'] is int
                ? json['total_count'] as int
                : null,
            display: FeedBundleDisplay.fromJson(
              json['display'] as Map<String, dynamic>?,
            ),
            // Opt-in, default false: an absent flag (or pre-flag backend) keeps
            // the plain venue line rather than surfacing the going line.
            showSocialProof: json['show_social_proof'] as bool? ?? false,
          );
        case 'venue_grid':
          // Declares `item_type` like a bundle does, and for the same reason
          // (D34) — but it is `venue` and only `venue`, so an unexpected value
          // is a malformed block rather than a new entity to tolerate. The
          // tolerant direction lives one level up: an unknown *block* type is
          // skipped, which is where a future `<x>_grid` would land.
          final gridItemType = json['item_type'] as String? ?? 'venue';
          if (gridItemType != 'venue') {
            throw FormatException(
              'venue_grid item_type must be venue, got $gridItemType',
            );
          }
          return FeedBlockVenueGrid(
            id: id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            blurred: blurred,
            runId: runId,
            items: _requiredItems(json, gridItemType).cast<FeedVenueItem>(),
            button: FeedButton.fromJson(
              json['button'] as Map<String, dynamic>?,
            ),
          );
        case 'zine_grid':
          // Same posture as `venue_grid` one case up: the type is declared and
          // is `zine` and only `zine`, so an unexpected value is a malformed
          // block rather than a new entity to tolerate. Tolerance for genuinely
          // new shapes lives one level up, at the unknown *block* type.
          final gridItemType = json['item_type'] as String? ?? 'zine';
          if (gridItemType != 'zine') {
            throw FormatException(
              'zine_grid item_type must be zine, got $gridItemType',
            );
          }
          return FeedBlockZineGrid(
            id: id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            blurred: blurred,
            runId: runId,
            items: _requiredItems(json, gridItemType).cast<FeedZineItem>(),
            // Optional here, unlike `venue_grid` — `grid-featured` sends null.
            button: FeedButton.fromJson(
              json['button'] as Map<String, dynamic>?,
            ),
          );
        case 'people_grid':
          // Same posture as the two grids above: the type is declared and is
          // `person` and only `person`, so an unexpected value is a malformed
          // block rather than a new entity to tolerate.
          // `is` rather than a cast (codex round 2). A non-string `item_type`
          // already produced the right OUTCOME — the TypeError was caught and
          // the block became FeedBlockUnknown — but it got there by throwing a
          // type error that the reader has to know is caught two frames up.
          // Stating it is cheaper than re-deriving it, and it stops the next
          // person assuming the cast is safe because "it works".
          final rawItemType = json['item_type'];
          if (rawItemType != null && rawItemType is! String) {
            throw FormatException(
              'people_grid item_type must be a string, got $rawItemType',
            );
          }
          final peopleItemType = (rawItemType as String?) ?? 'person';
          if (peopleItemType != 'person') {
            throw FormatException(
              'people_grid item_type must be person, got $peopleItemType',
            );
          }
          return FeedBlockPeopleGrid(
            id: id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            blurred: blurred,
            runId: runId,
            items: _requiredPersonItems(json),
          );
        case 'banner':
          final button = FeedButton.fromJson(
            json['button'] as Map<String, dynamic>?,
          );
          if (button == null) {
            throw const FormatException('banner requires button');
          }
          return FeedBlockBanner(
            id: id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            blurred: blurred,
            runId: runId,
            text: json['text'] as String?,
            image: FeedImage.fromJson(json['image'] as Map<String, dynamic>?),
            style: FeedBannerStyle.fromJson(
              json['style'] as Map<String, dynamic>?,
            ),
            button: button,
          );
        case 'weekly_bundle':
          final rawCovers = json['cover_image_urls'];
          return FeedBlockWeeklyBundle(
            id: id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            blurred: blurred,
            runId: runId,
            batchId: json['batch_id'] as String?,
            weekStart: _parseDate(json['week_start']),
            weekEnd: _parseDate(json['week_end']),
            coverImageUrls: rawCovers is List
                ? rawCovers.whereType<String>().toList()
                : const [],
            itemCount: json['item_count'] as int?,
            listId: json['list_id'] as String?,
          );
        case 'feed_end':
          final button = FeedButton.fromJson(
            json['button'] as Map<String, dynamic>?,
          );
          if (button == null) {
            throw const FormatException('feed_end requires button');
          }
          return FeedBlockFeedEnd(
            id: id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            blurred: blurred,
            runId: runId,
            button: button,
          );
        case 'feed_complete':
          // PROD-4237. `title` only — the block carries no button, and there
          // is nothing else to require: a `feed_complete` with no title is a
          // block the widget renders as nothing, not a parse failure. The
          // backend never sends both this and `feed_end`.
          return FeedBlockFeedComplete(
            id: id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            blurred: blurred,
            runId: runId,
          );
        case 'unknown_area':
          // PROD-4288. Copy is backend-localized like `feed_complete`'s, so
          // there is nothing to require here: a block with no title renders as
          // nothing rather than failing to parse, and an empty `suggestions`
          // is a legitimate shape (agreed with BE — the heading alone still
          // beats a lone chat banner).
          return FeedBlockUnknownArea(
            id: id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            blurred: blurred,
            suggestions: FeedAreaSuggestion.listFromJson(json['suggestions']),
          );
        case 'create_cta':
          // PROD-4319. The payload is `{id, type}` and nothing else — the app
          // owns every word of this block (see the class doc), so there is
          // nothing here to read and nothing to require. The base fields are
          // still passed through: `blurred` is the backend's to set on any
          // block, and an eyebrow/title would cost nothing if this ever grows
          // one.
          return FeedBlockCreateCta(
            id: id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            blurred: blurred,
          );
        case 'sign_in_gate':
          // PROD-4520. Same `{id, type}` payload as `create_cta` above, for the
          // same reason: the app owns the illustration, the copy and the CTA,
          // so there is nothing on the wire to read.
          //
          // Verified against staging, which sends exactly:
          //   {"id": "sign-in-gate-people", "type": "sign_in_gate",
          //    "eyebrow": null, "title": null, "subtitle": null,
          //    "blurred": false, "run_id": null}
          //
          // ⚠️ **No CTA route on the wire, deliberately.** The gate's only
          // destination is our own login flow with `returnUrlProvider`
          // preserved, which a wire route cannot express — and since PROD-4446
          // a route this build cannot use drops the whole block, so putting one
          // there would be a way to lose the gate entirely.
          return FeedBlockSignInGate(
            id: id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            blurred: blurred,
          );
        default:
          // Rule 1. A type this app version has never heard of.
          return FeedBlockUnknown(id: id, rawType: type);
      }
    } catch (e) {
      // Catch EVERYTHING, not just FormatException. A wrong-typed field throws
      // TypeError, `DateTime.parse` throws FormatException, and a future field
      // could throw something else again — and "the client skips what it
      // cannot render" is worthless if one bad block can still take down the
      // feed. Breadth is the point here, not a lazy catch.
      //
      // A type we DO know, shaped in a way we can't render. Degrading to
      // unknown keeps the rest of the page alive and keeps the id in the
      // paging ledger; it deliberately does NOT coerce missing `items` to an
      // empty list, which would render a valid-looking empty block and mask
      // bad data. `parseError` keeps the two cases distinguishable.
      return FeedBlockUnknown(id: id, rawType: type, parseError: '$e');
    }
  }

  /// Parses `items` as the entity type the block **declared** (D34).
  ///
  /// ⚠️ **`itemType`, never the active feed filter.** The two agree on both
  /// pages today — the Eventos page carries event bundles, the Sítios page
  /// carries venue ones — which is exactly why filter-based dispatch would pass
  /// every current test and then break silently the first time a page carries a
  /// block of the other type. The declared type is the contract; the filter is
  /// not.
  ///
  /// An unknown type throws, which the caller turns into [FeedBlockUnknown] —
  /// so a future `item_type` costs that one block and leaves the page intact.
  /// That is the element-wise rule (D67/D68) applied where it belongs: **at the
  /// block**, not at the item, because a bundle half-parsed into rows we cannot
  /// render is worse than a bundle that is simply not there.
  static List<FeedItem> _requiredItems(
    Map<String, dynamic> json,
    String itemType,
  ) {
    final raw = json['items'];
    if (raw is! List) {
      throw const FormatException('block requires items');
    }
    final maps = raw.whereType<Map<String, dynamic>>();
    return switch (itemType) {
      'event' => maps.map(FeedEventItem.fromJson).toList(),
      'venue' => maps.map(FeedVenueItem.fromJson).toList(),
      // ⚠️ `zine` on the wire, `list` in the store. The app calls a public list
      // a zine and the database calls it a list; the backend translates at its
      // boundary, so `list` never appears here and would be a malformed block.
      'zine' => maps.map(FeedZineItem.fromJson).toList(),
      _ => throw FormatException('unknown item_type: $itemType'),
    };
  }

  /// `event_hero` carries events unconditionally — it has no `item_type` on the
  /// wire, and a hero is an event by definition. Kept separate from
  /// [_requiredItems] so the hero's list stays `List<FeedEventItem>` and its
  /// widget keeps reading `startsAt` without a cast.
  static List<FeedEventItem> _requiredEventItems(Map<String, dynamic> json) {
    final raw = json['items'];
    if (raw is! List) {
      throw const FormatException('block requires items');
    }
    return raw
        .whereType<Map<String, dynamic>>()
        .map(FeedEventItem.fromJson)
        .toList();
  }

  /// `people_grid` carries people unconditionally — kept separate from
  /// [_requiredItems] for two reasons: the list stays `List<FeedPersonItem>`
  /// without a cast, and [FeedPersonItem] is deliberately not a [FeedItem] (see
  /// its class doc), so it cannot go through that helper at all.
  ///
  /// **An empty list is valid here**, unlike every other block: this one is
  /// hydrated per request after composition, so the backend cannot omit it when
  /// it comes back empty. `renderableFeedBlocks` drops the zero-item case.
  /// A person that fails to parse is skipped rather than failing the block.
  static List<FeedPersonItem> _requiredPersonItems(Map<String, dynamic> json) {
    final raw = json['items'];
    if (raw is! List) {
      throw const FormatException('people_grid requires items');
    }
    final out = <FeedPersonItem>[];
    for (final map in raw.whereType<Map<String, dynamic>>()) {
      // Belt-and-braces over the `is` checks in [FeedPersonItem.fromJson]:
      // that constructor is written not to throw, but this loop is what
      // GUARANTEES the invariant holds when someone adds a field later and
      // reaches for a cast. Without it, one bad row escapes to the block-level
      // catch and the entire grid disappears.
      try {
        final person = FeedPersonItem.fromJson(map);
        if (person != null) out.add(person);
      } catch (_) {
        // Skip this person, keep the block.
      }
    }
    return out;
  }

  /// A list of string ids, tolerant of absence and of non-string entries.
  ///
  /// Non-strings are dropped rather than throwing: an unusable id is exactly
  /// the case [FeedBlockBundle.highlightedItems] already skips, so failing the
  /// whole block would be a harsher answer than the contract asks for.
  static List<String> _optionalIdList(Object? raw) {
    if (raw is! List) return const [];
    return raw.whereType<String>().toList();
  }

  static List<FeedReaction>? _optionalReactions(Map<String, dynamic> json) {
    final raw = json['reactions'];
    if (raw is! List) return null;
    return raw
        .whereType<Map<String, dynamic>>()
        .map(FeedReaction.fromJson)
        .whereType<FeedReaction>()
        .toList();
  }

  static DateTime? _parseDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

/// Full-width stacked event cards. v0 carries 2.
class FeedBlockEventHero extends FeedBlock {
  final List<FeedEventItem> items;

  /// Optional people-reactions row (D36). Rendered only when present; `null`
  /// means the row does not appear at all.
  final List<FeedReaction>? reactions;

  const FeedBlockEventHero({
    required super.id,
    required this.items,
    super.eyebrow,
    super.title,
    super.subtitle,
    super.blurred,
    super.runId,
    this.reactions,
  });

  @override
  String get type => 'event_hero';
}

/// A titled group of rows, with the per-row save button as the CTA (D22).
///
/// The block type is `bundle`, never `venue_bundle` / `category_bundle`: the
/// sourcing rule never reaches the client, which is exactly what lets the
/// backend change the selection logic with no app release (D18).
class FeedBlockBundle extends FeedBlock {
  /// A bundle carries exactly one entity type, declared here (D34). v0 emits
  /// `event` only. Kept as a raw string so an unknown future type doesn't
  /// throw — the dispatcher picks a row widget from it.
  final String itemType;

  /// **The full result set** (v1.110.0), in the order the see-all page renders
  /// it, capped by the backend. A bundle that cannot reach two items is
  /// omitted entirely rather than sent short.
  ///
  /// ⚠️ **Not what the home page renders** — that is [highlightedItems]. This
  /// list used to be the 3–6 visible rows and its `minItems`/`maxItems` bounds
  /// were dropped when it became the full set, so a client still rendering it
  /// on the feed shows up to 30 rows where it used to show 3–6.
  final List<FeedItem> items;

  /// Which items the **home-page** block shows: 1–4 of them, typically 3
  /// (D76).
  ///
  /// **Named by id, never by a prefix count** (D77). A count binds
  /// "highlighted" to "first", which holds while the rule is *the next 3
  /// chronologically* and breaks the moment it becomes *the best 3* — failing
  /// by rendering the wrong items while every field still validates.
  ///
  /// **Null when the field was absent**, which is how a pre-v1.110.0 backend
  /// is recognised: on such a response [items] is still the old 3–6 window, so
  /// [highlightedItems] falls back to it and the feed renders exactly as
  /// before. Parsed as optional against a `required` wire field for that
  /// reason — a strict parse would throw away the whole block instead.
  ///
  /// ⚠️ **Null and empty are NOT the same thing**, and collapsing them is the
  /// bug this nullability exists to prevent. A v1.110+ response carrying
  /// `total_count` but no usable ids is *malformed*, not *old* — and on it
  /// [items] is the FULL set. Treating it as old would render up to 30 rows on
  /// the home feed, which is precisely the failure the highlight window
  /// exists to stop. See [carriesFullResultSet].
  final List<String>? highlightedItemIds;

  /// The true number of results — `>= items.length`, and strictly greater
  /// whenever the backend's cap truncated the set (D78).
  ///
  /// **Never derive this from `items.length`**: the two differing is the whole
  /// point, and it is what [hasSeeAll] reads. Null on a pre-v1.110.0 backend,
  /// which correctly yields no see-all affordance.
  final int? totalCount;

  /// Reserved and null in v0 (D35). Ignore it; render a fixed event row.
  final FeedBundleDisplay? display;

  /// Whether the client should render the friends-going social-proof line
  /// ("{name} vai") on this bundle's event rows. **The backend decides per
  /// bundle** — some bundles want the line, some don't — so the client never
  /// infers it from the bundle type or from the presence of `going` data.
  ///
  /// **Defaults to false** (the `show_social_proof` wire field absent or a
  /// pre-flag backend): the row renders its plain venue line, exactly as before
  /// the flag existed. No effect on venue/zine bundles — the going line is an
  /// event-row concept.
  final bool showSocialProof;

  const FeedBlockBundle({
    required super.id,
    required this.itemType,
    required this.items,
    this.highlightedItemIds,
    this.totalCount,
    super.eyebrow,
    super.title,
    super.subtitle,
    super.blurred,
    super.runId,
    this.display,
    this.showSocialProof = false,
  });

  /// The rows the **home page** renders, resolved from [highlightedItemIds].
  ///
  /// **An id that matches nothing is skipped, never rendered blank** — a
  /// stated client conformance requirement, and one whose failure is silent
  /// otherwise. Order follows the *ids*, not [items]: the backend chose that
  /// order, and it is free to highlight items out of see-all order.
  ///
  /// Falls back to [items] **only on a pre-v1.110.0 payload**, which is what
  /// makes an older backend render correctly rather than emptily. On a
  /// new-shape payload it never does — see [carriesFullResultSet].
  List<FeedItem> get highlightedItems {
    final ids = highlightedItemIds;
    if (ids == null) return carriesFullResultSet ? const [] : items;
    final byId = {for (final item in items) item.id: item};
    return [
      for (final id in ids)
        if (byId[id] case final item?) item,
    ];
  }

  /// Whether this block came from a backend that speaks v1.110.0 or later, and
  /// therefore whether [items] is the **full result set** rather than the
  /// home-page window.
  ///
  /// Either new field is enough: they ship together, so one arriving without
  /// the other is a malformed new-shape response, not an old one. The
  /// distinction is load-bearing — get it wrong in the permissive direction
  /// and a malformed bundle renders up to 30 rows where 3 belong, silently.
  bool get carriesFullResultSet =>
      highlightedItemIds != null || totalCount != null;

  /// Whether to render the see-all affordance (D87).
  ///
  /// **One rule, no per-bundle knowledge.** A bundle whose full set *is* its
  /// highlights has nothing behind the tap, so it gets no chevron; the day its
  /// source starts returning more, the chevron appears **with no app release**.
  /// That is why the client must not learn which bundle types have a real
  /// source yet.
  bool get hasSeeAll => (totalCount ?? 0) > highlightedItems.length;

  @override
  String get type => 'bundle';
}

/// The Sítios page's *Perto de ti* grid — a titled grid of venue tiles
/// (PROD-4108, Figma `7675:38682`).
///
/// **Not bundle-shaped, and the difference is the point** (D137). A bundle
/// carries a full result set, a `total_count` and a highlight window because its
/// see-all page renders that set from the same payload. This block's "ver mais"
/// leaves the feed contract entirely — it opens the app's existing
/// `/shelves/near-you` page — so the block carries **only what it displays**.
/// D78 and D87 govern bundles, not this: there is no wider set behind [items]
/// and no count to compare against.
///
/// Its items come from the **same query** that destination uses, which is what
/// makes the two coherent by construction rather than by coincidence. Source
/// them differently and a user taps a grid the backend composed and lands on a
/// list the client composed — different venues, different order, nothing
/// erroring. ⚠️ **So this block must never grow a client-side fetch.** It
/// renders what arrived.
class FeedBlockVenueGrid extends FeedBlock {
  /// Exactly the venues the grid shows.
  ///
  /// ⚠️ **0–6, not 6.** The backend's count is a *ceiling*: per-caller
  /// seen-suppression drops venues this reader has already been shown, and a
  /// thin corpus yields fewer still. Two readers in one city legitimately get
  /// different grids of different lengths, so with the client's 3 columns a
  /// **ragged last row is expected rather than a defect**.
  ///
  /// ⚠️ **It can be empty, and the backend cannot omit the block when it is** —
  /// the block is placed during composition, before the per-caller query runs,
  /// and the cursor's layout digest is taken over that composition. Dropping it
  /// server-side after the page was sliced would shorten a page the digest
  /// already covered. So the *client* drops it, in `renderableFeedBlocks`
  /// (Zé, 2026-09-01): a "Perto de ti" heading over a live chevron and nothing
  /// underneath reads as a loading failure, and the contract says there are no
  /// client-side empty states for blocks.
  final List<FeedVenueItem> items;

  /// The **unconditional** "ver mais" affordance (D137) — unlike a bundle's
  /// see-all it does not depend on there being more results than shown, because
  /// there is no "more" to count. Still subject to rule 2: an un-allowlisted
  /// route hides it.
  final FeedButton? button;

  const FeedBlockVenueGrid({
    required super.id,
    required this.items,
    this.button,
    super.eyebrow,
    super.title,
    super.subtitle,
    super.blurred,
    super.runId,
  });

  /// Declared for the same reason a bundle declares it (D34): the tile widget is
  /// keyed on the block's own type, never on the active filter. Constant here
  /// because the parser rejects any other value — see `FeedBlock.fromJson`.
  String get itemType => 'venue';

  @override
  String get type => 'venue_grid';
}

/// A titled grid of zine covers (PROD-4118) — the Zines page's only new block
/// type, used three times: featured at 2, editor picks at 4, recommended at 4.
///
/// Shaped like [FeedBlockVenueGrid] — it carries only what it displays, so no
/// `total_count`, no wider result set, no highlight window — with **two
/// differences that are the whole ticket**:
///
/// 1. ⚠️ **It is NOT the `venue_grid` empty-block exception.** A `venue_grid`
///    can arrive empty because it is *placed* during composition and *filled*
///    per caller afterwards, which is why `renderableFeedBlocks` drops the
///    zero-item case. Every zine source runs **inside** composition, so an
///    empty zine grid is omitted server-side like any other block. Adding a
///    zero-item guard here would be dead code guarding a state that cannot
///    occur — and it would read as deliberate to whoever finds it next.
///
///    Verified rather than assumed: a guest page on staging omits
///    `grid-featured` and `grid-editor-picks` entirely and pages the remaining
///    five blocks, rather than sending them empty.
///
/// 2. **[button] is optional**, unlike the venue grid's unconditional one: the
///    featured grid replaces the old Highlighted shelf, which ships no "ver
///    mais" by design, and sends `null`.
class FeedBlockZineGrid extends FeedBlock {
  /// Exactly the zines the grid shows. Never empty — see the class doc.
  ///
  /// The backend owns the count and the client owns the columns (D8), so the
  /// widget lays out `ceil(items.length / 2)` rows and a ragged last row is
  /// expected rather than a defect.
  final List<FeedZineItem> items;

  /// The see-all affordance, or `null` when the grid has no destination.
  ///
  /// ⚠️ **Nullable is the contract, not defensiveness.** `grid-featured` sends
  /// `null` because there is no page to open. Rendering a chevron regardless
  /// would dead-end the tap. Still subject to rule 2 on top of that: an
  /// un-allowlisted route hides it.
  final FeedButton? button;

  const FeedBlockZineGrid({
    required super.id,
    required this.items,
    this.button,
    super.eyebrow,
    super.title,
    super.subtitle,
    super.blurred,
    super.runId,
  });

  /// Declared for the same reason a bundle declares it (D34): the tile widget
  /// keys on the block's own type, never on the active filter. Constant here
  /// because the parser rejects any other value — see [FeedBlock.fromJson].
  String get itemType => 'zine';

  @override
  String get type => 'zine_grid';
}

/// A grid of person cards — the *Pessoas* feed's lead block.
///
/// Shaped like `zine_grid`: it carries only what it displays, so there is no
/// `total_count`, no wider result set and no highlighted window. **Unlike it,
/// there is no `button` at all** — this grid has no see-all destination, so the
/// field is absent rather than nullable.
///
/// ⚠️ **It IS the `venue_grid` empty-block exception, not the `zine_grid` case.**
/// Everything about this block is viewer-relative — who is suggested, the follow
/// state, and every word of each details row — so the backend cannot fill it
/// inside composition, which is cached per `(filter, city, locale, slate)` with
/// no user dimension. It is placed as an empty shell and hydrated per request,
/// after the page has been sliced, so by the time emptiness is knowable the
/// block is already committed to the page. A zero-item `people_grid` therefore
/// reaches the client, and `renderableFeedBlocks` drops it.
///
/// The backend owns the item count; the client owns the columns (3), so the
/// widget lays out `ceil(items.length / 3)` rows and a ragged last row is
/// expected rather than a defect.
class FeedBlockPeopleGrid extends FeedBlock {
  /// The people the grid shows. **May be empty** — see the class doc.
  final List<FeedPersonItem> items;

  const FeedBlockPeopleGrid({
    required super.id,
    required this.items,
    super.eyebrow,
    super.title,
    super.subtitle,
    super.blurred,
    super.runId,
  });

  /// Declared for the same reason `zine_grid` declares it (D34): the tile
  /// widget keys on the block's own type, never on the active filter. Constant
  /// because the parser rejects any other value.
  String get itemType => 'person';

  @override
  String get type => 'people_grid';
}

/// Full-width text + illustration + CTA. Structure fixed, content
/// server-defined.
class FeedBlockBanner extends FeedBlock {
  final String? text;
  final FeedImage? image;
  final FeedButton button;

  /// Server-supplied ground and button fills. Null until the backend ships
  /// them (requested for v1.106.0); the widget falls back to the client-side
  /// registry keyed on the asset key, then to a default.
  final FeedBannerStyle? style;

  const FeedBlockBanner({
    required super.id,
    required this.button,
    super.eyebrow,
    super.title,
    super.subtitle,
    super.blurred,
    super.runId,
    this.text,
    this.image,
    this.style,
  });

  @override
  String get type => 'banner';
}

/// The weekly-bundle cover card, as today. Cover-level fields only — the items
/// stay behind `GET /api/v1/app/recommendations/weekly`, which the card already
/// opens.
class FeedBlockWeeklyBundle extends FeedBlock {
  final String? batchId;
  final DateTime? weekStart;
  final DateTime? weekEnd;
  final List<String> coverImageUrls;
  final int? itemCount;
  final String? listId;

  const FeedBlockWeeklyBundle({
    required super.id,
    super.eyebrow,
    super.title,
    super.subtitle,
    super.blurred,
    super.runId,
    this.batchId,
    this.weekStart,
    this.weekEnd,
    this.coverImageUrls = const [],
    this.itemCount,
    this.listId,
  });

  @override
  String get type => 'weekly_bundle';
}

/// End-of-feed card. The button renders **visibly disabled** in v0 (D24).
class FeedBlockFeedEnd extends FeedBlock {
  final FeedButton button;

  const FeedBlockFeedEnd({
    required super.id,
    required this.button,
    super.eyebrow,
    super.title,
    super.subtitle,
    super.blurred,
    super.runId,
  });

  @override
  String get type => 'feed_end';
}

/// The end of the feed, placed by the backend (PROD-4237).
///
/// [title] only — the localized "É tudo, malta" — and no button. The backend
/// appends it on the last page of the last slate **instead of** [FeedBlockFeedEnd],
/// never both.
///
/// ⚠️ **The app must never render an end-of-feed card on its own initiative**
/// (Zé, PROD-4236). With neither this block nor `feed_end` present the feed
/// simply ends. That is why the terminal state is its own wire type rather than
/// a nullable button the client interprets: under the nullable-button design a
/// misconfigured route and "the feed ended" would have shared one signal, and a
/// CTA hidden for being un-allowlisted would have silently rendered "That's all
/// folks".
class FeedBlockFeedComplete extends FeedBlock {
  const FeedBlockFeedComplete({
    required super.id,
    super.eyebrow,
    super.title,
    super.subtitle,
    super.blurred,
    super.runId,
  });

  @override
  String get type => 'feed_complete';
}

/// PROD-4319 — the "help me get to know this place" card: a line of copy and the
/// two contribution CTAs (import a Google Maps list, send an Instagram post).
///
/// **The wire payload is `{id, type}` and nothing else, and that is deliberate.**
/// This block inverts the page's usual rule — normally the backend supplies the
/// copy (D7) and the app renders what it is sent. Two independent reasons:
///
///  1. The three strings already ship in `en` / `pt` / `pt-BR` / `es`, because
///     the legacy Discovery page (`DiscoveryHelpUsActions`) has used them since
///     2025. Authoring them server-side would redo finished translation work.
///  2. **`action.route` could not express the buttons even if it carried them.**
///     Both open native bottom sheets; the CTA allowlist
///     (`feed_action_routes.dart`) admits routes only, and a sheet has no route
///     to allow.
///
/// So the split is the one `unknown_area`'s chips already use: the **backend
/// decides whether and where**, the **app owns what it says and does**. A block
/// rather than a flag on `unknown_area` precisely so it can be placed anywhere,
/// the way the chat banner is.
class FeedBlockCreateCta extends FeedBlock {
  const FeedBlockCreateCta({
    required super.id,
    super.eyebrow,
    super.title,
    super.subtitle,
    super.blurred,
  });

  @override
  String get type => 'create_cta';
}

/// PROD-4520 — the backend telling a guest to sign in, on `filter=people`.
///
/// **Server-driven, where it used to be a client-side decision.** PROD-4445
/// gated this in the app and never called the endpoint for a guest (D9). The
/// backend has since built the guest path, so the app now asks like any other
/// filter and renders whatever comes back — which for a guest is this block.
///
/// The app still owns **everything the reader sees**: the illustration, the
/// Variant C copy in four locales, and the CTA through
/// `navigateToLoginPreservingReturn` so the OAuth round-trip returns to the
/// feed instead of `/home`. Only the trigger moved.
///
/// ⚠️ **The type is named generally but emitted people-only for now.** It must
/// not encode the filter, or a second one gets added the first time another
/// filter needs a gate.
class FeedBlockSignInGate extends FeedBlock {
  const FeedBlockSignInGate({
    required super.id,
    super.eyebrow,
    super.title,
    super.subtitle,
    super.blurred,
  });

  @override
  String get type => 'sign_in_gate';
}

/// One city the backend offers when it cannot serve the caller's area
/// (PROD-4288).
///
/// **Every field except the ids is backend-localized**, and the split between
/// [label] and [name] is deliberate: the app does no parsing of [label], so it
/// cannot recover the city name by splitting on the comma, and it needs the
/// bare name separately to build the search scope.
///
/// [name] is localized too, not raw. It ends up as the header's location line
/// (`'${city.name}, $iso2'`), and `/geo/cities` already returns
/// `localized_city_name`, so the picker stores a localized name as well —
/// sending a raw one here is what would break parity, not preserve it.
@immutable
class FeedAreaSuggestion {
  /// Seeded local UUID. Written straight into the picker scope, and sent back
  /// as `city_id` on the next feed request.
  final String cityId;

  /// Chip text, rendered verbatim — e.g. "Lisbon, PT".
  final String label;

  /// The city name alone, for the scope — e.g. "Lisbon".
  final String name;

  final double latitude;
  final double longitude;

  /// ISO-3166-1 alpha-2, for the scope's `iso2`.
  final String countryCode;

  /// Display country name for the scope, localized.
  final String countryName;

  const FeedAreaSuggestion({
    required this.cityId,
    required this.label,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.countryCode,
    required this.countryName,
  });

  /// A suggestion, or null when it is missing anything the tap needs.
  ///
  /// Null rather than a throw: one malformed entry drops **that chip**, it does
  /// not cost the block. A chip that cannot change the scope is worse than an
  /// absent one — it would look tappable and do nothing.
  static FeedAreaSuggestion? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final cityId = raw['city_id'];
    final label = raw['label'];
    final lat = raw['latitude'];
    final lon = raw['longitude'];
    // ⚠️ **Every field the scope needs is validated here, not just the obvious
    // ones** (codex, 2026-09-08). The country pair was originally accepted as
    // `as String? ?? ''`, which failed the rule this method exists for in both
    // directions: a *missing* `country_code` produced a tappable chip that
    // persists a scope whose header line reads "Lisbon, " — malformed, and
    // visibly so — and a *wrong-typed* one threw on the cast, which the outer
    // parser catches by degrading the WHOLE block to unknown, when the
    // contract is that one bad entry costs one chip.
    final countryCode = raw['country_code'];
    final countryName = raw['country_name'];
    if (cityId is! String || cityId.isEmpty) return null;
    if (label is! String || label.isEmpty) return null;
    if (lat is! num || lon is! num) return null;
    if (countryCode is! String || countryCode.isEmpty) return null;
    if (countryName is! String || countryName.isEmpty) return null;
    final name = raw['name'];
    return FeedAreaSuggestion(
      cityId: cityId,
      label: label,
      // The label is the honest fallback for a missing `name` — it is the same
      // place, just wordier. Splitting it on the comma to recover the name is
      // exactly the parsing the two-field split exists to avoid.
      name: name is String && name.isNotEmpty ? name : label,
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
      countryCode: countryCode,
      countryName: countryName,
    );
  }

  static List<FeedAreaSuggestion> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (FeedAreaSuggestion.fromJson(entry) case final s?) s,
    ];
  }
}

/// "I don't know this area" — the backend cannot serve the caller's location
/// (PROD-4288, emitted by PROD-4290).
///
/// ⚠️ **The app never renders this on its own initiative.** Same rule as
/// `feed_complete`: the reason a feed is unserviceable is the backend's to
/// state, and the client's own zero-block state stays deliberately neutral
/// because it cannot tell out-of-coverage from three other causes. See
/// `feed_notice_states.dart`.
class FeedBlockUnknownArea extends FeedBlock {
  /// Cities to offer instead. May be empty — the heading alone still beats
  /// showing nothing.
  final List<FeedAreaSuggestion> suggestions;

  const FeedBlockUnknownArea({
    required super.id,
    this.suggestions = const [],
    super.eyebrow,
    super.title,
    super.subtitle,
    super.blurred,
  });

  @override
  String get type => 'unknown_area';
}

/// A block this app version cannot render — either an unrecognised wire `type`
/// (rule 1) or a known type whose payload failed to parse.
///
/// It exists as a member of the sealed hierarchy rather than being dropped at
/// parse time for three reasons: the dispatcher's `switch` stays exhaustive
/// without a `default` arm; the *renderer* owns the skip, so a test can assert
/// it; and the block keeps its [id], which the paging ledger needs.
class FeedBlockUnknown extends FeedBlock {
  /// The `type` string the backend actually sent.
  final String rawType;

  /// Non-null when this was a **known** type we failed to parse, rather than a
  /// type we've never heard of. Both render as nothing; only this tells them
  /// apart in tests and diagnostics.
  final String? parseError;

  const FeedBlockUnknown({
    required super.id,
    required this.rawType,
    this.parseError,
  });

  /// True when the backend sent a type this app version has never heard of —
  /// the forward-compatibility case, as opposed to malformed data.
  bool get isUnrecognisedType => parseError == null;

  @override
  String get type => rawType;
}

/// One page of the server-driven Discovery feed.
@immutable
/// The caller's sentiment for ONE entity on this page (PROD-4026 / PROD-4027).
///
/// An object rather than a bare string so a future axis (a "going" chip on a
/// feed card) is an added field, not a breaking change to every value in the
/// map.
@immutable
class FeedEntitySignal {
  /// Pure taste — the 👍 / 👎 thumbs. The wire enum is `liked` / `disliked`
  /// only: an entity the caller has no opinion on is **absent** from the map,
  /// so `none` would be a second way to say the same thing.
  final String sentiment;

  const FeedEntitySignal({required this.sentiment});

  /// Returns `null` for anything unrecognisable — a missing or ill-typed
  /// `sentiment`, or a value this app version does not know. Dropping the
  /// entry degrades that one card to "no opinion"; throwing would cost the
  /// whole feed page over a field the backend is free to extend.
  static FeedEntitySignal? fromJson(Map<Object?, Object?> json) {
    final sentiment = json['sentiment'];
    if (sentiment is! String) return null;
    return FeedEntitySignal(sentiment: sentiment);
  }
}

/// The caller's sentiment for the entities on THIS page, split by entity type.
///
/// Scoped to one page — each cursor response carries its own map and the client
/// **merges** as it scrolls (see `feed_signal_seeds.dart`).
///
/// **Saves are deliberately not here.** `GET /users/me/saved/entity-ids` is the
/// single home of that bit and the app already consumes it; carrying
/// `interested` too would be a second source of truth for one fact, and two
/// sources for one bit is how they end up disagreeing.
@immutable
class FeedSignals {
  /// Keyed by event id. **An absent id means `none`, not "unknown"** — the
  /// backend omits entities the caller has no opinion on.
  final Map<String, FeedEntitySignal> events;

  /// Keyed by venue id. Populated from the Sítios page (PROD-4108) — the grid
  /// and all three venue bundles — and empty on the Eventos page. Always
  /// present either way, so the client never null-checks.
  final Map<String, FeedEntitySignal> venues;

  const FeedSignals({this.events = const {}, this.venues = const {}});

  static const empty = FeedSignals();

  /// Returns **null** for a missing or ill-typed `signals`, so the caller can
  /// tell "this backend does not send the map" from "the map is legitimately
  /// empty". Only the latter authorises seeding `none` and skipping the GETs.
  ///
  /// Takes [Object?] rather than a map: the whole value is backend-supplied, so
  /// a cast here would be the one throw in a parse layer whose entire contract
  /// is that it never throws.
  static FeedSignals? fromJson(Object? json) {
    if (json is! Map) return null;
    return FeedSignals(
      events: _parseMap(json['events']),
      venues: _parseMap(json['venues']),
    );
  }

  static Map<String, FeedEntitySignal> _parseMap(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, FeedEntitySignal>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! Map) continue;
      final signal = FeedEntitySignal.fromJson(value);
      if (signal != null) out[key] = signal;
    }
    return out;
  }
}

/// The viewer's friends interested in ONE event — the "Dos teus amigos" line.
///
/// Rendered as "John vai" / "Denise e Louise vão" / "Emily + 3 pessoas vão" on
/// a bundle event row. The people arrive already resolved (name/handle/avatar);
/// the app composes the "vai/vão" verb from [count] (see `FeedGoingRow`).
@immutable
class FeedGoingEntry {
  /// Up to three friends to show, most-recent signal first — the same
  /// projection as `event_hero` reactions, so one avatars-row widget serves
  /// both surfaces.
  final List<FeedReaction> preview;

  /// The true number of the viewer's friends interested, `>= preview.length`.
  /// Drives the "+N pessoas" overflow the three-avatar preview cannot show.
  final int count;

  const FeedGoingEntry({required this.preview, required this.count});

  /// Tolerant: a person that fails to parse is dropped, never fatal. A missing
  /// or ill-typed `count` falls back to the preview length so the line still
  /// renders without an overflow rather than throwing away the whole entry.
  static FeedGoingEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawPreview = json['preview'];
    final preview = rawPreview is List
        ? rawPreview
              .whereType<Map<String, dynamic>>()
              .map(FeedReaction.fromJson)
              .whereType<FeedReaction>()
              .toList()
        : <FeedReaction>[];
    final rawCount = json['count'];
    final count = rawCount is int ? rawCount : preview.length;
    return FeedGoingEntry(preview: preview, count: count);
  }
}

/// The friends-going lines for the events on THIS page, keyed by event id.
///
/// A viewer-relative side-map, the sibling of [FeedSignals]: computed per
/// request from the sliced page, never part of the block cache. Each page
/// carries its own map and the client merges as it scrolls (see
/// `FeedGoingSeeds`). Events-only, nested under `events` to mirror
/// [FeedSignals].
@immutable
class FeedGoing {
  /// Keyed by event id. An absent id means no friend is interested — the row
  /// renders its venue line instead.
  final Map<String, FeedGoingEntry> events;

  const FeedGoing({this.events = const {}});

  static const empty = FeedGoing();

  /// Returns **null** for a missing or ill-typed `going`, so the caller can
  /// tell "this backend does not send the map" from "the map is legitimately
  /// empty" — the same distinction [FeedSignals.fromJson] draws. Only an empty
  /// map (not a null) authorises clearing stale seeds for a page.
  static FeedGoing? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawEvents = json['events'];
    if (rawEvents is! Map) return const FeedGoing();
    final out = <String, FeedGoingEntry>{};
    for (final entry in rawEvents.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final value = FeedGoingEntry.fromJson(entry.value);
      if (value != null) out[key] = value;
    }
    return FeedGoing(events: out);
  }
}

class FeedHomeOut {
  /// Echo of the resolved filter this page was composed for.
  final FeedFilter filter;

  /// Ordered blocks for this page. An empty block is omitted by the backend —
  /// the feed just gets shorter, and there are no client-side empty states for
  /// blocks (D23).
  final List<FeedBlock> blocks;

  /// Pass back as `cursor` for the next page **of this slate**.
  ///
  /// ⚠️ **Per-slate since PROD-4237, not per-feed.** It is `null` on the
  /// slate's last page — the one carrying `feed_end` or `feed_complete` — which
  /// is no longer the same thing as "the feed has ended". Before slates those
  /// were three names for one moment: the layout was exhausted, `next_cursor`
  /// was null, and `feed_end` had rendered. The next slate is reached **only**
  /// through the `feed_end` button's `next_slate` action, never by auto-paging,
  /// and that falls out of this null rather than being enforced separately.
  final String? nextCursor;

  /// The caller's sentiment for the entities on this page, so the like/dislike
  /// chips render from this response instead of one
  /// `GET /{entity}/{id}/signal` per card (PROD-4027).
  ///
  /// **`null` means the response carried no `signals` key at all** — an older
  /// backend, or a response cached before PROD-4026 shipped. That is NOT the
  /// same as a present-but-empty map, which is what a guest (or a page whose
  /// entities the caller has no opinion on) legitimately gets.
  ///
  /// The difference is load-bearing: an empty map is an authoritative "no
  /// opinions on this page", so the client seeds `none` and skips the GETs.
  /// Absent means "this backend cannot answer", so the client must seed
  /// nothing and fall back to the per-entity fetch — otherwise every card
  /// would render as unrated and never correct itself.
  final FeedSignals? signals;

  /// The viewer's friends interested in the events on this page (the "Dos teus
  /// amigos" line), keyed by event id. Same per-request, viewer-relative
  /// posture as [signals] — **`null` means the response carried no `going`
  /// key** (an older backend), which is not the same as a present-but-empty
  /// map (a guest, or a page where no friend is interested).
  final FeedGoing? going;

  /// The served slate's `discovery_runs` id for this page fetch (PROD-4257).
  ///
  /// One page fetch = one run. Carried so client engagement
  /// (`POST /app/discovery/engagement`) joins back to the exact ranking via
  /// `(run_id, item_id)`.
  ///
  /// ⚠️ **Often `null` on this endpoint by design.** The block-composed home
  /// feed frequently serves from a path that persists no run, and run logging
  /// can be disabled entirely — either way the client degrades gracefully:
  /// session stitching still works, only the slate join is skipped. Never
  /// require it; only forward it when present.
  final String? runId;

  /// Which ranking filled this page's discovery blocks (PROD-4373).
  ///
  /// `personalized` — the viewer's own slate (or, for a guest, the city's
  /// canonical guest slate). `safe_bet` — the shared city slate served
  /// instantly to a signed-in viewer whose personal pool was cold; their pool
  /// warms in the background and the next cursor-less request upgrades to
  /// `personalized`. `null` when the page carried no usable discovery slate,
  /// or on an older backend.
  ///
  /// Kept as a raw string, not an enum, per this file's forward-compatibility
  /// rules: a third kind must flow through unchanged, never throw.
  final String? slateKind;

  const FeedHomeOut({
    required this.filter,
    required this.blocks,
    this.nextCursor,
    this.signals,
    this.going,
    this.runId,
    this.slateKind,
  });

  factory FeedHomeOut.fromJson(Map<String, dynamic> json) {
    final rawBlocks = json['blocks'];
    return FeedHomeOut(
      filter: FeedFilter.fromWire(json['filter'] as String?),
      blocks: rawBlocks is List
          ? rawBlocks
                .whereType<Map<String, dynamic>>()
                .map(FeedBlock.fromJson)
                .toList()
          : const [],
      nextCursor: json['next_cursor'] as String?,
      signals: FeedSignals.fromJson(json['signals']),
      going: FeedGoing.fromJson(json['going']),
      runId: json['run_id'] as String?,
      slateKind: json['slate_kind'] as String?,
    );
  }
}
