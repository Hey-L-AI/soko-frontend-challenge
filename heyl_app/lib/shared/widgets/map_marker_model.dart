import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

/// Types of map markers supported by the app — controls render style only.
///
/// Orthogonal to [MapMarkerCategory] (which controls *what* the pin
/// semantically represents — venue vs event — and drives pin color).
enum MapMarkerType {
  /// User's current location (blue dot)
  userLocation,

  /// Place/event suggestion (amber circle with sparkle)
  place,

  /// Indexed marker with letter (A, B, C...)
  letter,

  /// Simple pin marker for detail views
  pin,
}

/// Semantic category of a map marker — drives pin color via Mapbox style
/// match expressions (PROD-1978). Orthogonal to [MapMarkerType] (render
/// style). A marker can be a `letter` pin that is also semantically a
/// `venue` (blue) or an `event` (green).
///
/// Encoded into the GeoJSON feature's `item_type` property so the shared
/// style expression can branch on it: `['match', ['get','item_type'], ...]`.
/// The wire vocabulary (`'place' | 'event'`) matches the backend's
/// `SavedItemType` discriminator (PROD-1993); the Dart enum name keeps
/// `venue` because "venue" is the term the FE design system uses.
enum MapMarkerCategory { venue, event }

extension MapMarkerCategoryWire on MapMarkerCategory {
  /// Stable string used in the Mapbox style `['get','item_type']`
  /// expression. Matches the backend's `item_type` enum (PROD-1993):
  /// `MapMarkerCategory.venue → 'place'`, `MapMarkerCategory.event → 'event'`.
  String get wire {
    switch (this) {
      case MapMarkerCategory.venue:
        return 'place';
      case MapMarkerCategory.event:
        return 'event';
    }
  }
}

/// Cluster styling constants shared by the web and native map widgets
/// (PROD-1978). Kept as a static class rather than a `ThemeExtension`
/// because the values are non-theme-dependent geometry/breakpoints, and
/// the cluster fill color lives in `AppColors.mapClusterFill`.
class MapClusterTokens {
  MapClusterTokens._();

  /// Radius in pixels for the cluster source (Mapbox clusterRadius).
  static const double sourceClusterRadius = 50;

  /// Max zoom at which to cluster points (Mapbox clusterMaxZoom).
  static const double sourceClusterMaxZoom = 14;

  /// Cluster bubble radius ramp (small/medium/large) keyed off `point_count`.
  /// Bumped ~30 % in PROD-2205-followup so the touch target matches the
  /// new pin sizing — see [MapPinTokens].
  static const double bubbleRadiusSmall = 21;
  static const double bubbleRadiusMedium = 29;
  static const double bubbleRadiusLarge = 36;

  /// `point_count` thresholds — `[mediumAt, largeAt]`. A cluster with
  /// `point_count < mediumAt` is small; `>= mediumAt && < largeAt` is
  /// medium; `>= largeAt` is large.
  static const int mediumAt = 10;
  static const int largeAt = 50;
}

/// Unclustered pin styling — radius + stroke for both selected and
/// unselected states. Mapbox style expressions on `circle-radius` and
/// `circle-stroke-width` branch on the per-feature `selected` property
/// (PROD-2205) and resolve to these values.
///
/// Bumped roughly +30 % over the original 8/12/0.5 values
/// (PROD-2205-followup) to give a comfortably tappable target on
/// phones. Selected pins also pick up a 3-px stroke as the primary
/// "you are here" differentiator now that the yellow-fill highlight
/// has been retired in favour of keeping each pin's semantic colour
/// (event green / venue blue).
class MapPinTokens {
  MapPinTokens._();

  static const double unselectedRadius = 10;
  // PROD-2205-followup r2: bumped 14 → 17 (≈ +20 %) for stronger
  // visual prominence on the focused pin.
  static const double selectedRadius = 17;

  /// Stroke width for unselected pins. Soko/Ink at this weight reads
  /// as a thin outline that separates the fill from the basemap
  /// without dominating it.
  static const double unselectedStrokeWidth = 0.5;

  /// Stroke width for the selected pin(s). Same Soko/Ink colour, just
  /// thicker — paired with the radius bump this is what tells the
  /// user which pin "is" the item they're reading about.
  static const double selectedStrokeWidth = 3;
}

/// Unified height for the list-page / zine map surfaces (cover map,
/// list-view body map, zine item-page map). Keeping the three at the
/// same height avoids the "map shrinks when I open an item" feel
/// PROD-2205 dogfooding surfaced. Other map surfaces (chat compact,
/// detail blocks via `AspectRatio`, places modal via viewport
/// fraction) intentionally pick their own height.
const double kZineMapHeight = 360;

/// Controls the "Tap to interact / Lock map" activation chip on
/// list-related map surfaces (cover, list-view body, zine item, and
/// the event / venue detail blocks).
///
/// `false` ships today (PROD-2205-followup) — maps are interactive
/// from mount, no chip rendered. Flipping this to `true` re-enables
/// the chip everywhere in one move; useful for a rollback or an A/B
/// test on the lock-by-default behaviour. The chip code path in
/// [MapboxMapWidget] is untouched — only its gate.
const bool kListMapsStaticByDefault = false;

/// Data model for a map marker
class MapMarker {
  /// Unique identifier for the marker
  final String id;

  /// Latitude coordinate
  final double lat;

  /// Longitude coordinate
  final double lng;

  /// Type of marker to display
  final MapMarkerType type;

  /// Optional label text (e.g., "A", "B", "C" for letter markers)
  final String? label;

  /// Whether this marker is currently selected
  final bool isSelected;

  /// Optional data attached to the marker (e.g., ItemSuggestion)
  final dynamic data;

  /// Optional custom color override
  final Color? color;

  /// Accuracy radius in meters (for user location marker circle)
  final double? accuracyM;

  /// Semantic category — venue vs event. Drives pin color via Mapbox
  /// style match expression. Nullable for backwards-compatibility:
  /// markers without a category fall back to the default pin color.
  final MapMarkerCategory? category;

  /// PROD-2671: registered Mapbox image id for a per-category PNG teardrop
  /// pin — the category/key (e.g. `'pin-music'`, `'pin-default'`). Only
  /// consumed by the Map page's `categoryIcons` symbol-layer rendering;
  /// null everywhere else, so existing consumers keep the circle pins.
  final String? iconImage;

  /// PROD-2807: when non-null this marker is a **"+k" overflow bubble** (a
  /// dense grid cell collapsed by the custom selection), not an individual
  /// pin — `k` is this count. The Map page renders it via the bubble layers
  /// ([`overflow_count`] feature property); [category] gives the colour
  /// breakdown (venue / event / null = mixed). Null everywhere else.
  final int? overflowCount;

  /// PROD-2906 (A6): true when the v2 server marked this stack's [overflowCount]
  /// as a lower bound (a saturated cell) — the title renders "N+" instead of
  /// "N". Always false for the client-side selection; never trips at launch.
  final bool overflowCountCapped;

  /// PROD-2671: the Map page's inline pin label. [pinTitle] = the item name
  /// (placeholder "Venue title"/"Event title" until the `/map/pins` payload
  /// carries a real name); [pinSubtitle] = the localized secondary-facet label.
  /// Rendered to the right of the teardrop glyph. Null everywhere else.
  final String? pinTitle;
  final String? pinSubtitle;

  /// PROD-2671: for a **"+k" overflow bubble**, the ≤5 member pin-keys in
  /// stack order (front-first) — the map draws them as a stack of teardrops
  /// shifted 3 px up-and-left per layer. [venueCount]/[eventCount] drive the
  /// bubble's "X venues" / "Y events" title. Null / 0 for individual pins.
  final List<String>? stackIcons;
  final int? venueCount;
  final int? eventCount;

  /// PROD-2671: true when this is a **terminal** (co-located / "unsplittable")
  /// overflow bubble — tapping it opens the cluster-focus flow (fade the rest +
  /// scope the drawer to its members) instead of zooming. Only meaningful on
  /// overflow bubbles.
  final bool overflowTerminal;

  /// PROD-2671: cluster-focus dims every marker except the focused cluster —
  /// the renderers drop this marker's icon + caption opacity when true.
  final bool dimmed;

  /// PROD-2989: true once this item's single-item detail sheet has been opened
  /// this map-page visit (a "seen" hint). The renderers stamp it as the `viewed`
  /// feature property and fold the [MapPinIconTokens.viewedIconOpacity]
  /// `icon-opacity` multiplier into the pin's
  /// icon + caption opacity — orthogonal to `dimmed` (focus) and the reveal
  /// animation, which it composes with. Only meaningful on individual pins;
  /// bubbles keep `false`.
  final bool viewed;

  /// PROD-2947 (FE-1): score-driven `icon-size` multiplier for this pin (from a
  /// pool-normalized relevance rank — `MapPinIconTokens.scoreSizeMultiplier`).
  /// `1.0` = baseline (no score / flat pool). The renderers stamp it as the
  /// `icon_scale` feature property and multiply it into the zoom-interpolated
  /// `icon-size`. Only set on individual pins — bubbles keep `1.0`.
  final double scoreSizeMul;

  /// PROD-2947 (FE-1): caption placement priority (`symbol-sort-key`) from the
  /// pin's RAW relevance score (`MapPinIconTokens.captionSortKey` = `1 − score`;
  /// lower = higher priority). Stamped as the `sort_key` feature property so a
  /// higher-scored pin's caption wins a collision with a lower-scored neighbour.
  /// `0.0` (top priority) by default; only meaningful on individual pins.
  ///
  /// PROD-3004: always stamped, but only *honoured* when the pool's scores vary —
  /// a flat pool sets `symbol-z-order: viewport-y`, which makes Mapbox ignore the
  /// key. See [mapSymbolZOrder].
  final double captionSortKey;

  const MapMarker({
    required this.id,
    required this.lat,
    required this.lng,
    required this.type,
    this.label,
    this.isSelected = false,
    this.data,
    this.color,
    this.accuracyM,
    this.category,
    this.iconImage,
    this.overflowCount,
    this.overflowCountCapped = false,
    this.pinTitle,
    this.pinSubtitle,
    this.stackIcons,
    this.venueCount,
    this.eventCount,
    this.overflowTerminal = false,
    this.dimmed = false,
    this.viewed = false,
    this.scoreSizeMul = 1.0,
    this.captionSortKey = 0.0,
  });

  /// Create a user location marker
  factory MapMarker.userLocation({
    required double lat,
    required double lng,
    double? accuracyM,
  }) {
    return MapMarker(
      id: 'user_location',
      lat: lat,
      lng: lng,
      type: MapMarkerType.userLocation,
      accuracyM: accuracyM,
    );
  }

  /// Create a place marker
  factory MapMarker.place({
    required String id,
    required double lat,
    required double lng,
    dynamic data,
    bool isSelected = false,
    MapMarkerCategory? category,
    String? iconImage,
    String? pinTitle,
    String? pinSubtitle,
  }) {
    return MapMarker(
      id: id,
      lat: lat,
      lng: lng,
      type: MapMarkerType.place,
      pinTitle: pinTitle,
      pinSubtitle: pinSubtitle,
      data: data,
      isSelected: isSelected,
      category: category,
      iconImage: iconImage,
    );
  }

  /// Create a letter marker (A, B, C...)
  factory MapMarker.letter({
    required String id,
    required double lat,
    required double lng,
    required String letter,
    dynamic data,
    bool isSelected = false,
    Color? color,
    MapMarkerCategory? category,
    String? iconImage,
    String? pinTitle,
    String? pinSubtitle,
  }) {
    return MapMarker(
      id: id,
      lat: lat,
      lng: lng,
      type: MapMarkerType.letter,
      pinTitle: pinTitle,
      pinSubtitle: pinSubtitle,
      label: letter,
      data: data,
      isSelected: isSelected,
      color: color,
      category: category,
      iconImage: iconImage,
    );
  }

  /// Create a pin marker for detail views
  factory MapMarker.pin({
    required String id,
    required double lat,
    required double lng,
    Color? color,
    MapMarkerCategory? category,
    String? iconImage,
    String? pinTitle,
    String? pinSubtitle,
  }) {
    return MapMarker(
      id: id,
      lat: lat,
      lng: lng,
      type: MapMarkerType.pin,
      pinTitle: pinTitle,
      pinSubtitle: pinSubtitle,
      color: color,
      category: category,
      iconImage: iconImage,
    );
  }

  /// Create a copy with different selection state
  MapMarker copyWith({
    String? id,
    double? lat,
    double? lng,
    MapMarkerType? type,
    String? label,
    bool? isSelected,
    dynamic data,
    Color? color,
    double? accuracyM,
    MapMarkerCategory? category,
    String? iconImage,
    int? overflowCount,
    bool? overflowCountCapped,
    String? pinTitle,
    String? pinSubtitle,
    List<String>? stackIcons,
    int? venueCount,
    int? eventCount,
    bool? overflowTerminal,
    bool? dimmed,
    bool? viewed,
    double? scoreSizeMul,
    double? captionSortKey,
  }) {
    return MapMarker(
      id: id ?? this.id,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      type: type ?? this.type,
      label: label ?? this.label,
      isSelected: isSelected ?? this.isSelected,
      data: data ?? this.data,
      color: color ?? this.color,
      accuracyM: accuracyM ?? this.accuracyM,
      category: category ?? this.category,
      iconImage: iconImage ?? this.iconImage,
      overflowCount: overflowCount ?? this.overflowCount,
      overflowCountCapped: overflowCountCapped ?? this.overflowCountCapped,
      pinTitle: pinTitle ?? this.pinTitle,
      pinSubtitle: pinSubtitle ?? this.pinSubtitle,
      stackIcons: stackIcons ?? this.stackIcons,
      venueCount: venueCount ?? this.venueCount,
      eventCount: eventCount ?? this.eventCount,
      overflowTerminal: overflowTerminal ?? this.overflowTerminal,
      dimmed: dimmed ?? this.dimmed,
      viewed: viewed ?? this.viewed,
      scoreSizeMul: scoreSizeMul ?? this.scoreSizeMul,
      captionSortKey: captionSortKey ?? this.captionSortKey,
    );
  }

  /// Round accuracyM to nearest 10m to avoid unnecessary rebuilds from float churn
  int get _accuracyBucket => ((accuracyM ?? 0).round()) ~/ 10;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MapMarker &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          lat == other.lat &&
          lng == other.lng &&
          type == other.type &&
          label == other.label &&
          isSelected == other.isSelected &&
          _accuracyBucket == other._accuracyBucket &&
          color == other.color &&
          category == other.category &&
          iconImage == other.iconImage &&
          overflowCount == other.overflowCount &&
          overflowCountCapped == other.overflowCountCapped &&
          pinTitle == other.pinTitle &&
          pinSubtitle == other.pinSubtitle &&
          venueCount == other.venueCount &&
          eventCount == other.eventCount &&
          overflowTerminal == other.overflowTerminal &&
          dimmed == other.dimmed &&
          viewed == other.viewed &&
          scoreSizeMul == other.scoreSizeMul &&
          captionSortKey == other.captionSortKey &&
          listEquals(stackIcons, other.stackIcons);

  @override
  int get hashCode => Object.hashAll(<Object?>[
    id,
    lat,
    lng,
    type,
    label,
    isSelected,
    _accuracyBucket,
    color,
    category,
    iconImage,
    overflowCount,
    overflowCountCapped,
    pinTitle,
    pinSubtitle,
    venueCount,
    eventCount,
    overflowTerminal,
    dimmed,
    viewed,
    scoreSizeMul,
    captionSortKey,
    stackIcons == null ? null : Object.hashAll(stackIcons!),
  ]);
}

/// PROD-2671: how far to pull the Map-page search rect IN from each edge of the
/// visible area, as a fraction of that dimension — so we don't fetch/select
/// items hugging the screen border (they render half-clipped and pop in/out on
/// the smallest camera nudge). Applied on all four sides of the visible rect;
/// the derived radius (centre→corner of the shrunk rect) shrinks with it.
/// Shared by the web + native platform impls so they can't drift. Tunable: 0.05
/// keeps the inner ~90 % of each dimension. 0 = the full visible area.
const double kMapSearchAreaMarginFraction = 0.05;

/// PROD-3003: duration (ms) of the camera RECENTER ease — the my-location
/// button (`centerToToken`) and value-diff center changes. One shared constant
/// consumed by BOTH renderers (web `createEaseToOptions`, native
/// `MapAnimationOptions`) so the platforms can't drift again; both use a plain
/// `easeTo` (web always did; native used a 300 ms `flyTo` arc before — the
/// direct ease is calmer for a short recenter and matches the longer-tested
/// web feel). Deliberately NOT used by the pin-tap ease (250 ms) or the
/// cluster expansion zoom (400 ms) — those are separate, already-matched
/// gestures.
const int kMapRecenterEaseMs = 500;

/// PROD-2999: the Map page's opening zoom-in settle — shared by BOTH renderers
/// (was web-only private statics; hoisted so native can't drift).
///
/// Birth-zoom offset: the map opens this much zoomed OUT from the target, then
/// eases in. Big enough to read as a deliberate settle.
const double kMapOpenSettleZoomDelta = 2.0;

/// Duration (ms) of the opening zoom-in settle ease. Kept comfortably longer
/// than a typical `/map/pins` fetch (~0.5 s) so the final pins are ready to
/// reveal the moment the ease settles (no wider-set flash).
const int kMapOpenSettleMs = 800;

// ── PROD-3000: the Map page's pin-reveal animation — shared by BOTH
// renderers (was web-only private statics; hoisted so native can't drift).
// Each pin fades + scales up + does a small lift ("jump"), starting at a
// RANDOM moment within the stagger window so pins pop up in no particular
// order. Tuned live in `pin-reveal-mockup.html`; web drives it with a 16 ms
// per-frame `setData` loop, native with an awaited partial-update loop
// (`updateGeoJSONSourceFeatures`). Native also keeps a whole-layer fade of
// the same length as its failure fallback.

/// Duration (ms) of ONE pin's full reveal animation (fade + scale + lift).
/// Also the length of native's whole-layer fallback fade, so the two reveal
/// modes read as the same moment.
const int kMapRevealFadeMs = 350;

/// Window (ms) within which each new pin's animation randomly starts.
const int kMapRevealStaggerMs = 600;

/// Fade-in portion (ms) of a pin's animation (opacity reaches 1 here; the
/// scale/lift keep going until [kMapRevealFadeMs]).
const int kMapRevealFadePortionMs = 200;

/// Scale a pin is born at (fraction of its final size).
const double kMapRevealStartScale = 0.25;

/// Overshoot scale at the pop's peak, before settling to 1.0.
const double kMapRevealPeakScale = 1.3;

/// When the overshoot peak lands within the pin's own 0..1 progress.
const double kMapRevealPeakOffset = 0.3;

/// The lift: a pin starts this many px BELOW its final spot…
const double kMapRevealBelowPx = 6;

/// …overshoots this many px ABOVE it, then settles to 0.
const double kMapRevealAbovePx = 14;

double _revealEaseOut(double t) => 1 - math.pow(1 - t, 3).toDouble();
double _revealEaseInOut(double t) =>
    t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3).toDouble() / 2;

/// Reveal curves (mirror pin-reveal-mockup.html "Chosen"). [local] is a pin's
/// own 0..1 progress. Motion is two eased segments split at
/// [kMapRevealPeakOffset]: rise-to-overshoot, then settle.
double mapRevealOpacity(double local) {
  final f = kMapRevealFadePortionMs / kMapRevealFadeMs;
  if (f <= 0) return 1;
  return _revealEaseOut((local / f).clamp(0.0, 1.0));
}

double mapRevealScale(double local) {
  if (local <= kMapRevealPeakOffset) {
    final p = _revealEaseOut(local / kMapRevealPeakOffset);
    return kMapRevealStartScale +
        (kMapRevealPeakScale - kMapRevealStartScale) * p;
  }
  final p = _revealEaseInOut(
    (local - kMapRevealPeakOffset) / (1 - kMapRevealPeakOffset),
  );
  return kMapRevealPeakScale + (1.0 - kMapRevealPeakScale) * p;
}

double mapRevealLiftPx(double local) {
  // +below (under the final spot) → -above (overshoot up) → 0 (settle).
  if (local <= kMapRevealPeakOffset) {
    final p = _revealEaseOut(local / kMapRevealPeakOffset);
    return kMapRevealBelowPx + (-kMapRevealAbovePx - kMapRevealBelowPx) * p;
  }
  final p = _revealEaseInOut(
    (local - kMapRevealPeakOffset) / (1 - kMapRevealPeakOffset),
  );
  return -kMapRevealAbovePx + (0 - -kMapRevealAbovePx) * p;
}

// ── Pin-landing haptics — shared by BOTH renderers ────────────────────────
//
// A pin's reveal ends by dropping from its overshoot back onto its spot
// ([mapRevealLiftPx] → 0 at local = 1). That touchdown gets the lightest
// haptic we have — the same [HapticFeedback.selectionClick] the results
// drawer fires on a snap.
//
// Landings arrive as a staggered rain (random starts across
// [kMapRevealStaggerMs]), so a dense result set would land 30+ pins inside a
// second. Tapping every one of those is a sustained buzz, not a texture —
// hence the throttle in [MapPinLandingHaptics]: a minimum gap between taps
// plus a per-burst cap, which turns the rain into a few distinct raindrops
// and then falls silent while the rest of the pins land quietly.

/// Minimum gap between two landing taps. Below ~50 ms the taps stop reading as
/// separate events on iOS and smear into one buzz.
/// PROD-2993 — how much every plotted marker grows while the results drawer sits
/// at its `half` snap and the map is highlighting what you're reading.
///
/// It applies to **individual pins and stacks alike** (D14), through the same
/// per-feature `icon_scale` property the score-driven sizing already uses — so
/// the two just multiply. The reason it exists at all: at `half` the visible
/// strip of map is short, and pins tuned to read against a full-screen map are
/// too small to pick out in it.
///
/// Visual only — tune freely. 1.4 is the ticket's number and has not yet been
/// judged on a device.
const double kMapHighlightSizeMul = 1.4;

/// PROD-2992 — the pin-focus enlargement: the single tapped pin grows by this
/// while its detail sheet is open and the rest of the map recedes (dimmed to
/// 25%). Distinct from [kMapHighlightSizeMul] (the results-highlight whole-map
/// bump) — pin-focus enlarges only the ONE focused pin. `1.25` is the ticket's
/// "+25%"; visual only, tune freely, not yet judged on a device.
const double kMapPinFocusSizeMul = 1.25;

/// PROD-3828 — the SELECTION enlargement for category-icon pins: a pin marked
/// by `selectedMarkerId` / `selectedMarkerIds` grows by this much.
///
/// Why it exists: under `categoryIcons` the unclustered circle is fully
/// transparent, and selection was expressed *only* as `circle-radius` +
/// `circle-stroke-*` — so on an icon surface the highlight was simply
/// invisible. The `selected` feature property was already stamped by both
/// renderers; nothing read it. This gives it a reader on the icon layers.
///
/// Unlike [kMapHighlightSizeMul] and [kMapPinFocusSizeMul] — which the Map
/// page's provider bakes into `MapMarker.scoreSizeMul` (the per-feature
/// `icon_scale`) — this one is applied **renderer-side**, as a `case` on the
/// `selected` property multiplied into the same icon-size expression. It has
/// to be: the surfaces that need it (chat places modal, zine item page, event
/// + venue detail blocks) pass `selectedMarkerId(s)` straight to the widget
/// and never go through `map_render_provider`. Multiplying into the same
/// expression means it still composes with score × highlight × focus.
///
/// `1.25` mirrors [kMapPinFocusSizeMul] — the closest analogue, one pin
/// singled out from the rest. Visual only; tune freely, not yet judged on a
/// device.
const double kMapPinSelectedSizeMul = 1.25;

const int kMapRevealHapticMinGapMs = 60;

/// Most taps one burst of landings may fire, however many pins land.
const int kMapRevealHapticMaxPerBurst = 10;

/// A quiet stretch (no pin landing at all) this long ends the current burst —
/// the next landing starts a fresh one with the cap reset. Sized so a pan's
/// refetch always reads as a new burst, while a DENSE reveal — the only case
/// the cap exists for — can never split into two and spend it twice: its
/// landings are packed into the [kMapRevealStaggerMs] window, far closer than
/// this. A sparse reveal (a handful of pins, landings possibly further apart
/// than this) may well split, which costs nothing — it was never near the cap.
const int kMapRevealHapticBurstResetMs = 400;

/// PROD-2981 — the map's answer to "did my tap register?": one light haptic the
/// instant a pin or a stack is tapped, before a single pixel moves. The work a
/// tap kicks off can take a moment to show up on screen, and an unacknowledged
/// tap is what makes people tap again. Same vocabulary as the drawer snap and
/// the pin landings. No-ops on web (mirrors the results drawer's guard).
void fireMapTapHaptic() {
  if (kIsWeb) return;
  HapticFeedback.selectionClick();
}

/// Fires a light haptic as each revealed pin touches down, throttled so a dense
/// reveal reads as a patter rather than a buzz. See the section comment above.
///
/// Clock-agnostic: callers pass the same monotonic ms clock that drives their
/// reveal loop, so the throttle is measured against animation time.
/// No-ops on web, which has no haptics (mirrors the results drawer's guard).
class MapPinLandingHaptics {
  int? _lastLandingMs;
  int _lastTapMs = 0;
  int _burstCount = 0;

  /// Call the moment a pin's reveal reaches its settled state.
  void pinLanded(int nowMs) {
    if (kIsWeb) return;

    // A long enough silence since the previous landing means this one belongs
    // to a new reveal (a pan's refetch, say) — reset the cap for it.
    final last = _lastLandingMs;
    if (last == null || nowMs - last > kMapRevealHapticBurstResetMs) {
      _burstCount = 0;
    }
    _lastLandingMs = nowMs;

    if (_burstCount >= kMapRevealHapticMaxPerBurst) return;
    if (_burstCount > 0 && nowMs - _lastTapMs < kMapRevealHapticMinGapMs) {
      return;
    }

    _burstCount++;
    _lastTapMs = nowMs;
    HapticFeedback.selectionClick();
  }
}

/// PROD-2671: snapshot of the map camera, delivered to `onCameraIdle`
/// each time the map settles (Mapbox `moveend`). The Map page converts it
/// into a `MapQuery` center + search radius for settle-to-search.
class MapCameraState {
  final double centerLat;
  final double centerLng;
  final double zoom;

  /// Visible-bounds corners (north-east + south-west) in lat/lng.
  final double neLat;
  final double neLng;
  final double swLat;
  final double swLng;

  const MapCameraState({
    required this.centerLat,
    required this.centerLng,
    required this.zoom,
    required this.neLat,
    required this.neLng,
    required this.swLat,
    required this.swLng,
  });

  /// Whether a lat/lng falls inside the visible viewport rectangle.
  /// Handles the antimeridian case (viewport crossing ±180°), where the
  /// south-west longitude is numerically greater than the north-east.
  bool contains(double lat, double lng) {
    if (lat < swLat || lat > neLat) return false;
    if (swLng <= neLng) return lng >= swLng && lng <= neLng;
    return lng >= swLng || lng <= neLng; // wraps the antimeridian
  }

  /// Great-circle metres between two lat/lng pairs.
  static double _haversineM(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const earthRadiusM = 6378137.0;
    double toRad(double d) => d * (math.pi / 180.0);
    final dLat = toRad(lat2 - lat1);
    final dLng = toRad(lng2 - lng1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(toRad(lat1)) *
            math.cos(toRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusM * c;
  }

  /// A search radius (metres) that **circumscribes** the visible viewport: the
  /// great-circle distance from the centre to the NE corner. Clamped to the
  /// API's accepted `radius_meters` window (100 m – 50 km).
  ///
  /// Use this when the radius must COVER everything on screen — the Map page
  /// sends it to `/map/pins`, where anything in a viewport corner falling
  /// outside the radius would silently vanish from the results.
  ///
  /// A circle drawn at this radius passes through the four corners and bulges
  /// past the edges, so it reads as "bigger than the map". When the radius is
  /// something the user is picking and looking at, use
  /// [inscribedRadiusMeters].
  double get radiusMeters =>
      _haversineM(centerLat, centerLng, neLat, neLng).clamp(100.0, 50000.0);

  /// A radius (metres) that **fits inside** the visible viewport: the distance
  /// from the centre to the nearest edge, i.e. half the shorter of the two
  /// viewport spans. Clamped to the same window as [radiusMeters].
  ///
  /// This is the one to use where the radius is DRAWN and the circle should sit
  /// within the frame (the location picker). It is deliberately smaller than
  /// [radiusMeters]: the viewport corners fall OUTSIDE it, so a scope built
  /// from this searches less than the map shows.
  double get inscribedRadiusMeters {
    final halfHeight = _haversineM(centerLat, centerLng, neLat, centerLng);
    final halfWidth = _haversineM(centerLat, centerLng, centerLat, neLng);
    return math.min(halfHeight, halfWidth).clamp(100.0, 50000.0);
  }
}

/// DEBUG-ONLY (Map page): the search area the FE currently sends to `/map/pins`,
/// drawn on the map as a translucent soko-red overlay so we can eyeball exactly
/// what the backend receives (radius circle and/or v2 viewport rectangle) vs.
/// the visible screen. Built in `MapScreen` from the committed `MapQuery`; only
/// ever non-null in `kDebugMode` (the debug tab is compiled out otherwise).
///
/// Both parts are optional and drawn only when actually sent:
/// - [radiusMeters] — the `radius_meters` circle (center + radius). Always sent
///   for `all` scope; null hides the circle.
/// - the [swLat]/[swLng]/[neLat]/[neLng] rectangle — the v2 `viewport_*` bounds,
///   sent only when server-side selection (`pins_version=2`) is active; a null
///   corner hides the rectangle.
@immutable
class MapSearchAreaOverlay {
  final double centerLat;
  final double centerLng;

  /// The circle radius (metres) sent as `radius_meters`, or null to hide it.
  final double? radiusMeters;

  /// The v2 viewport rectangle corners, or null (any corner) to hide it.
  final double? swLat;
  final double? swLng;
  final double? neLat;
  final double? neLng;

  const MapSearchAreaOverlay({
    required this.centerLat,
    required this.centerLng,
    this.radiusMeters,
    this.swLat,
    this.swLng,
    this.neLat,
    this.neLng,
  });

  bool get hasCircle => radiusMeters != null;

  bool get hasRect =>
      swLat != null && swLng != null && neLat != null && neLng != null;

  @override
  bool operator ==(Object other) =>
      other is MapSearchAreaOverlay &&
      other.centerLat == centerLat &&
      other.centerLng == centerLng &&
      other.radiusMeters == radiusMeters &&
      other.swLat == swLat &&
      other.swLng == swLng &&
      other.neLat == neLat &&
      other.neLng == neLng;

  @override
  int get hashCode => Object.hash(
    centerLat,
    centerLng,
    radiusMeters,
    swLat,
    swLng,
    neLat,
    neLng,
  );
}

/// Fired when the map settles after a pan/zoom (Mapbox `moveend`).
typedef MapCameraIdleCallback = void Function(MapCameraState camera);

/// PROD-2671: rendering constants for the Map page's category PNG pins
/// (web symbol layer). Source PNGs are 80×110 px; [iconSize] is the
/// Mapbox `icon-size` multiplier applied to that source.
class MapPinIconTokens {
  MapPinIconTokens._();

  /// PROD-2989 — `icon-opacity` multiplier for a pin whose item has been
  /// "viewed" (its detail sheet was opened this map-page visit); `1.0` = no
  /// fade. THE single source of truth for the "seen" fade strength — both the
  /// web and native renderers fold this into their icon-opacity expression, so
  /// change the fade here (nowhere else). Composes multiplicatively with the
  /// focus-dim and the web open-reveal fade. Tune freely — visual only.
  static const double viewedIconOpacity = 0.6;

  /// Zoom-interpolated `icon-size` stops for the unclustered category pins
  /// (source PNGs are 80×110 px), as `(zoom, size)` pairs in ascending zoom.
  /// Mapbox `interpolate ['linear']` between them, clamped to the endpoint
  /// sizes outside the range. Tune freely — visual only; the caption-offset
  /// math and [iconSizeForZoom] both read this list, so labels + debug
  /// read-outs stay locked to whatever curve is set here.
  ///
  /// Current curve (user-tuned) is a "valley": pins are 0.4× when zoomed out
  /// (≤ 11) and zoomed in (≥ 18), and settle to 0.3× across the comfortable
  /// working range (14–17):
  ///   • ≤ 11        → 0.4× (clamped; the map is city/region-scoped so we don't
  ///                   grow further at world view)
  ///   • 11 → 14     → 0.4× ↘ 0.3× (bigger as you zoom out)
  ///   • 14 → 17     → flat 0.3×
  ///   • 17 → 18     → 0.3× ↗ 0.4× (bigger as you zoom in)
  ///   • ≥ 18        → 0.4× (clamped)
  static const List<(double zoom, double size)> iconSizeStops = [
    (11, 0.4),
    (14, 0.3),
    (17, 0.3),
    (18, 0.4),
  ];

  /// PROD-3830 — a smaller curve for the COMPACT surfaces: the chat preview
  /// (`optimizeForSmallSize`, `maxZoom: 14`, non-interactive) and the 1:1
  /// event/venue detail blocks.
  ///
  /// Why they need their own: [iconSizeStops] was tuned for a full-screen map.
  /// On the 80×110 source art its 0.3× working value renders **24×33 px**,
  /// against the **20×20 px** (r10) circle it replaces — and the teardrop is
  /// bottom-anchored, so it occupies the space *above* the coordinate rather
  /// than straddling it. On a map a few hundred px tall that reads as a pin
  /// that has outgrown its map.
  ///
  /// This is the same curve scaled to **0.7×**, giving ~17×23 px at the
  /// working zooms: narrower than the old circle, a little taller, and
  /// visually about the same weight. The shape of the curve is preserved
  /// (bigger when zoomed right out and right in, settling across the middle)
  /// so behaviour stays predictable across surfaces.
  ///
  /// Visual only — tune freely. Chosen on judgement and checked against
  /// measured pixel sizes rather than an approved spec, so it is the first
  /// thing to adjust if the pins read wrong on a device.
  static const List<(double zoom, double size)> compactIconSizeStops = [
    (11, 0.28),
    (14, 0.21),
    (17, 0.21),
    (18, 0.28),
  ];

  /// [iconSizeStops] flattened to `[zoom0, size0, zoom1, size1, …]` for
  /// splicing straight into a Mapbox `interpolate` expression.
  static List<double> get iconSizeStopsFlat => [
    for (final (zoom, size) in iconSizeStops) ...[zoom, size],
  ];

  /// Source PNG dimensions (px) — the caption-offset math tracks these.
  static const double sourceWidthPx = 80;
  static const double sourceHeightPx = 110;

  /// The inline caption's base `text-size` (px) = 1 em. MUST match the
  /// `text-size` set on the icon+label symbol layer, since the caption offset
  /// below is expressed in ems.
  static const double captionTextSizePx = 13;

  /// Gap (px) between the pin's right edge and the caption (Figma 6949-21685).
  static const double captionGapPx = 6;

  /// PROD-2671: the inline caption's `text-offset` (ems) as a **zoom-interpolated
  /// expression**, so it tracks the BOTTOM-anchored pin's *scaled* size at every
  /// zoom. A single constant offset (ems ≈ fixed screen-px) drifts off the pin
  /// as it shrinks when zoomed out — the pin is small but the caption stays a
  /// pin-height away. Deriving the stops from the same [iconSizeStops] as
  /// `icon-size` keeps the two locked together:
  ///   • x = clear the pin's right half-width + a [captionGapPx] gap
  ///   • y = lift a full pin-height (negative = up) so the caption's top-left
  ///     block aligns with the BOTTOM-anchored pin's top.
  /// Shared verbatim by the web (`text-offset`) and native
  /// (`textOffsetExpression`) symbol layers so they never diverge.
  ///
  /// PROD-2993: [sizeMul] scales the offset to track the **results-highlight
  /// enlargement** — the narrow half-drawer grows *every* pin by
  /// [kMapHighlightSizeMul] (`MapHighlightState.enlargeAll`), and the icon layer
  /// bakes that into its `icon-size` via the per-feature `icon_scale`. The
  /// caption can't read `icon_scale` the same way: Mapbox has no operator to
  /// scale a `text-offset` array by a per-feature value (array elements must be
  /// `["literal", …]` constants), and a `["zoom"]` interpolate must stay the
  /// OUTERMOST expression (it can't be nested in a `case`/`match` on the scale).
  /// So the enlargement can only be folded in GLOBALLY, as a plain multiplier on
  /// the (Dart-computed) stop literals — which is exactly right in `enlargeAll`
  /// mode, where every pin shares the same bump. The half-width scales with the
  /// pin; the [captionGapPx] gap stays a constant screen distance. Defaults to
  /// `1.0` (no enlargement) for every other surface.
  ///
  /// PROD-3828: [stops] overrides the curve (null → [iconSizeStops]). It MUST
  /// be the same list the icon layer's `icon-size` was built from, or the
  /// caption drifts off the pin at every zoom — the offset is derived from the
  /// pin's scaled height.
  static List<Object> captionOffsetExpression({
    double sizeMul = 1.0,
    List<(double, double)>? stops,
  }) {
    List<Object> stop(double zoom, double size) {
      final scaled = size * sizeMul;
      final ex =
          (sourceWidthPx * scaled / 2 + captionGapPx) / captionTextSizePx;
      final ey = -(sourceHeightPx * scaled) / captionTextSizePx;
      return <Object>[
        zoom,
        <Object>[
          'literal',
          <double>[ex, ey],
        ],
      ];
    }

    return <Object>[
      'interpolate',
      <Object>['linear'],
      <Object>['zoom'],
      for (final (zoom, size) in stops ?? iconSizeStops) ...stop(zoom, size),
    ];
  }

  /// The rendered `icon-size` multiplier at [zoom] — replicates the Mapbox
  /// linear interpolation over [iconSizeStops] (clamped to the endpoint sizes
  /// outside that range). Kept in lock-step with the symbol-layer `icon-size`
  /// expression so debug read-outs match what's actually painted. Multiply by
  /// [sourceWidthPx]/[sourceHeightPx] for the on-screen pin size in px.
  /// PROD-3828: [stops] overrides the curve for a surface that needs smaller
  /// (or larger) pins than the full-screen Map page — null keeps
  /// [iconSizeStops]. Pass the SAME list here, to [captionOffsetExpression]
  /// and to [pinHitDistance], or the captions and tap targets desynchronise
  /// from the rendered art.
  static double iconSizeForZoom(double zoom, {List<(double, double)>? stops}) {
    final curve = stops ?? iconSizeStops;
    if (zoom <= curve.first.$1) return curve.first.$2;
    if (zoom >= curve.last.$1) return curve.last.$2;
    for (var i = 0; i < curve.length - 1; i++) {
      final (z0, s0) = curve[i];
      final (z1, s1) = curve[i + 1];
      if (zoom <= z1) {
        final t = (zoom - z0) / (z1 - z0);
        return s0 + (s1 - s0) * t;
      }
    }
    return curve.last.$2; // unreachable — the clamp above covers zoom ≥ last.
  }

  /// Forgiveness margin (px) around a single pin's rendered rectangle for tap
  /// hit-testing. The tappable area is the icon dilated by this much on every
  /// side, so the target tracks the pin's on-screen size at every zoom —
  /// replacing the old constant r24 hit circle, which was ~2× the pin at the
  /// working zooms (taps clearly beside/below a pin still opened it).
  static const double pinHitMarginPx = 6;

  /// Geometric tap hit-test for a single (BOTTOM-anchored) pin: the rendered
  /// `sourceWidthPx`×`sourceHeightPx` × [iconSizeForZoom] rectangle, dilated
  /// by [pinHitMarginPx]. [anchorX]/[anchorY] are the pin's projected screen
  /// point (= the teardrop tip; the body extends upward).
  ///
  /// Returns the tap's distance (px) to the pin rectangle's CENTRE when the
  /// tap is inside — so overlapping candidates can be tie-broken nearest-wins
  /// — or null on a miss. Used by the native renderer's Dart-side tap path;
  /// the web renderer hit-tests the rendered icon via a
  /// `queryRenderedFeatures` box padded by the same [pinHitMarginPx].
  ///
  /// PROD-3828: [stops] overrides the curve (null → [iconSizeStops]) and must
  /// match the one the icon layer renders with, or the tap target stops
  /// covering the pin.
  static double? pinHitDistance({
    required double tapX,
    required double tapY,
    required double anchorX,
    required double anchorY,
    required double zoom,
    List<(double, double)>? stops,
  }) {
    final s = iconSizeForZoom(zoom, stops: stops);
    final halfW = (sourceWidthPx * s) / 2 + pinHitMarginPx;
    final h = sourceHeightPx * s;
    final dx = tapX - anchorX;
    if (dx.abs() > halfW) return null;
    if (tapY > anchorY + pinHitMarginPx) return null;
    if (tapY < anchorY - h - pinHitMarginPx) return null;
    final dy = tapY - (anchorY - h / 2);
    return math.sqrt(dx * dx + dy * dy);
  }

  // ── PROD-2947 (FE-1) — score-driven pin styling (SIZE only) ──────────────
  // The backend returns a real per-pin relevance `score ∈ [0,1]` (higher = more
  // relevant), but the live values are tightly clustered (most venues ≈ 0.25,
  // events ≈ 0), so an ABSOLUTE score→size mapping is imperceptible. Instead we
  // map each pin's score through a **relevance rank normalized against the
  // fetched candidate pool** ([ScoreNormalizer], built per entity by
  // `mapMarkersProvider`) → the pool's least-relevant pin renders smallest, its
  // most-relevant largest, regardless of how compressed the absolute range is.
  // The pool only refetches on camera-settle, so a pin's size is **stable during
  // a pan** (it re-slices the same pool). Opacity is left at 100% for now.

  /// A pin whose pool score-range spans less than this is treated as flat — the
  /// normalizer returns null (→ baseline `1.0×`), so a uniform / null-score pool
  /// renders exactly as before ("graceful when scores are flat/equal").
  static const double scoreVariationEpsilon = 1e-6;

  /// Per-pin `icon-size` multiplier from a pool-**normalized** relevance
  /// [normalized] (`[0,1]`, from [ScoreNormalizer]): `0.0 → 0.85×`,
  /// `0.5 → 1.00×`, `1.0 → 1.15×` (linear `0.85 + 0.30·x`). A null value (no
  /// score, or a flat pool) → `1.0` (baseline). Multiplied INTO the
  /// zoom-interpolated `icon-size` expression as a per-feature `icon_scale`
  /// property.
  static double scoreSizeMultiplier(double? normalized) {
    if (normalized == null) return 1.0;
    final x = normalized.clamp(0.0, 1.0);
    return 0.85 + 0.30 * x;
  }

  /// PROD-2947 (FE-1): caption placement priority from a **raw** relevance
  /// [score] (`[0,1]`), used as the single-pin layer's `symbol-sort-key`. Mapbox
  /// places **lower** sort keys first, and with `text-allow-overlap: false` a
  /// lower key wins a caption collision — so we invert: `1 − score`, giving the
  /// most-relevant pin the lowest key (highest priority). When two pin captions
  /// would overlap, the higher-scored one keeps its caption and the other's
  /// text drops (its icon stays — "no text on top of text"). Uses RAW (absolute)
  /// score so a pin's caption priority doesn't shift with what else is on screen.
  /// A null/absent score → `1.0` (lowest priority).
  ///
  /// PROD-3004: the key is stamped, and both layers' `symbol-sort-key` set,
  /// **unconditionally** on both platforms. What varies with the pool is
  /// `symbol-z-order`, not the key — see [mapSymbolZOrder]. A flat pool sets
  /// `viewport-y`, which makes Mapbox ignore the key outright, so a uniform key
  /// can no longer perturb the ordering.
  static double captionSortKey(double? score) =>
      1.0 - (score ?? 0.0).clamp(0.0, 1.0);
}

/// PROD-3004: the `symbol-z-order` both single-pin symbol layers (icon + caption)
/// must carry, given the pins currently on screen. This is the entire flat-pool
/// tie-break gate, and it is deliberately IDENTICAL on web and native.
///
/// Mapbox derives its sorting from the layer's z-order and sort-key together
/// (same logic in gl-js `symbol_bucket.ts` and the native core's
/// `symbol_layout.cpp`):
///
/// ```
/// canOverlap        = text-allow-overlap || icon-allow-overlap
///                  || text-ignore-placement || icon-ignore-placement
/// sortFeaturesByKey = zOrder != 'viewport-y' && hasSymbolSortKey
/// sortFeaturesByY   = (zOrder == 'viewport-y'
///                      || (zOrder == 'auto' && !sortFeaturesByKey)) && canOverlap
/// ```
///
/// **`viewport-y` masks the sort key outright** — it is exactly "unset the key",
/// expressed as a value you can SET. That is the whole point: the native SDK
/// can't cleanly unset a layout property, so before this it was stuck with the
/// key always live (flat pools tie-breaking by source order) while web, which
/// can unset, fell back to viewport-Y. One settable enum, one gate, both sides.
///
/// - **Scores vary → `auto`.** The key drives caption placement priority and icon
///   z-order (PROD-2940): the most relevant pin keeps its caption in a collision,
///   and its teardrop draws on top.
/// - **Flat pool → `viewport-y`.** The key is ignored. The ICON layer overlaps
///   (`icon-allow-overlap`) so it gets true viewport-Y depth — the "lower pin in
///   front" look, recomputed per frame from real screen position, so it holds
///   under rotation. The CAPTION layer is `text-allow-overlap: false`, so
///   `canOverlap` is FALSE and it never sorts by viewport-Y at all: it falls back
///   to source order. Same on both platforms — which is the fix.
///
/// **Which branch actually runs: `auto`.** Measured 2026-07-13 against BOTH
/// staging and production, `/map/pins` returns widely-varying `score` values —
/// ~133 distinct across 150 venue pins and ~114 across 150 event pins on prod.
/// The gate keys off those scores, so real pools are essentially NEVER flat and
/// `viewport-y` is a **fallback**, not the common case: it fires only on a
/// genuinely uniform pool, a single pin, or if the backend stops scoring.
///
/// (An earlier version of this comment claimed the opposite — that flat was the
/// normal state "until PROD-2985 rolls scoring out". Wrong: PROD-2985 tunes the
/// personalization axis WEIGHTS; it does not gate whether pins are scored. Note
/// the `MAP_PINS_RELEVANCE_SCORING` / `MAP_PINS_AXIS_SCORE_ENABLED` flags control
/// only the personalization rerank layered ON TOP of the base score — their state
/// doesn't decide whether `score` varies. Don't reason from flag names here;
/// `curl` `/map/pins` and look at the spread.)
String mapSymbolZOrder(Iterable<MapMarker> markers) =>
    scoreOrderingActive(markers) ? 'auto' : 'viewport-y';

/// PROD-2947 (FE-1): whether the pins' relevance scores actually VARY — i.e.
/// whether the stamped [MapMarker.captionSortKey] values carry any signal at all.
/// True for live pools (scoring is on and scores spread widely — see
/// [mapSymbolZOrder]); false only for a genuinely uniform pool, a single pin, or a
/// scoring-off state (every score null → every key `1.0`). Drives [mapSymbolZOrder],
/// and nothing else. Bubbles and the user-location dot are excluded — they don't
/// enter the single-pin symbol layers.
bool scoreOrderingActive(Iterable<MapMarker> markers) {
  double? first;
  for (final m in markers) {
    if (m.overflowCount != null) continue; // overflow bubble
    if (m.type != MapMarkerType.place) continue; // user-location dot etc.
    if (first == null) {
      first = m.captionSortKey;
    } else if (m.captionSortKey != first) {
      return true;
    }
  }
  return false;
}

/// PROD-2947 (FE-1): maps a raw relevance `score` to a `[0,1]` **rank within a
/// pool** via min–max normalization. Built once per entity from the fetched
/// candidate pool's scores (`ScoreNormalizer.fromScores`), then applied to each
/// shown pin. Because the reference is the whole pool (which only refetches on
/// camera-settle), a pin's normalized value — and thus its size — is stable
/// while the user pans (the map re-slices the same pool). Degrades to a no-op
/// (returns null → baseline) when the pool has no scored pins or no spread.
class ScoreNormalizer {
  final double? _min;
  final double? _span;

  const ScoreNormalizer._(this._min, this._span);

  /// A normalizer that always returns null (baseline) — no scores / flat pool.
  static const ScoreNormalizer flat = ScoreNormalizer._(null, null);

  /// Build from a pool's [scores] (nulls ignored). Returns [flat] when fewer
  /// than two scored pins or the spread is below
  /// [MapPinIconTokens.scoreVariationEpsilon].
  factory ScoreNormalizer.fromScores(Iterable<double?> scores) {
    double? lo, hi;
    for (final s in scores) {
      if (s == null) continue;
      lo = (lo == null || s < lo) ? s : lo;
      hi = (hi == null || s > hi) ? s : hi;
    }
    if (lo == null || hi == null) return flat;
    final span = hi - lo;
    if (span <= MapPinIconTokens.scoreVariationEpsilon) return flat;
    return ScoreNormalizer._(lo, span);
  }

  /// Whether this normalizer will actually differentiate (false = flat pool).
  bool get isActive => _min != null && _span != null;

  /// The pool-relative rank of [score] in `[0,1]` (clamped), or null when this
  /// is flat or [score] is null → the caller renders the baseline size.
  double? normalize(double? score) {
    if (score == null || _min == null || _span == null) return null;
    return ((score - _min) / _span).clamp(0.0, 1.0);
  }
}

/// Callback type for marker tap events (consumer-facing legacy hook).
/// Fires once per pin tap. Consumers using the tooltip flow normally
/// don't need this — the shell handles selection internally. Kept for
/// non-tooltip side effects (e.g. card-carousel sync in
/// `places_map_modal`).
typedef OnMarkerTap = void Function(MapMarker marker);

/// Content for the pin tooltip — populated by each map consumer via
/// `MapboxMapWidget.tooltipContentResolver`. Kept deliberately small
/// (PROD-2016 v1): item name + item type label. Future iterations may
/// extend this; do not add fields until product asks.
class MapPinTooltipContent {
  /// Primary line — item name (venue or event title).
  final String title;

  /// Secondary line — localised item-type label ("Lugar" / "Evento", etc.).
  /// Falls back to the wire string when no localised form is available.
  final String subtitle;

  /// PROD-2017: hide the "View details" button when the marker has no
  /// destination route (e.g. external event occurrences with no
  /// `venue_id`). Default `true` preserves the existing tooltip layout
  /// for every other call site.
  final bool showViewDetails;

  const MapPinTooltipContent({
    required this.title,
    required this.subtitle,
    this.showViewDetails = true,
  });
}

/// Resolves the tooltip content for a given marker. Returning null
/// hides the tooltip for that specific marker even if the feature is
/// otherwise enabled.
typedef MapPinTooltipContentResolver =
    MapPinTooltipContent? Function(MapMarker marker);

/// Callback fired when the user activates the tooltip's "View details"
/// button. The map widget itself doesn't know about routing — the host
/// page (which has `listId` / surface context in scope) picks the
/// correct destination route per PROD-2016 § "View details navigation".
typedef OnMapPinViewDetails = void Function(MapMarker marker);

/// A rectangular zone with a custom cursor, used by [MapCursorOverride].
class MapCursorZone {
  final double top;
  final double left;
  final double width;
  final double height;
  final String cursor;

  const MapCursorZone({
    required this.top,
    required this.left,
    required this.width,
    required this.height,
    this.cursor = 'pointer',
  });

  bool contains(double x, double y) =>
      x >= left && x <= left + width && y >= top && y <= top + height;
}

/// Defines zones where the Mapbox grab cursor should be overridden on web.
/// On desktop browsers, Mapbox GL JS sets cursor:grab on its container which
/// bleeds through to Flutter overlay widgets (buttons, drawers, banners).
/// This config tells the web map implementation to dynamically switch the
/// cursor to 'default' in the specified zones via a mousemove listener.
class MapCursorOverride {
  /// Height in pixels from the top where cursor should be 'default'.
  /// Covers overlay elements like back/fit-all buttons.
  final double topPx;

  /// Height in pixels from the bottom where cursor should be 'default'.
  /// Covers overlay elements like the bottom drawer.
  final double bottomPx;

  /// Specific rectangular zones with custom cursors (e.g. 'pointer' for buttons).
  /// Checked before the top/bottom zones.
  final List<MapCursorZone> zones;

  const MapCursorOverride({
    this.topPx = 0,
    this.bottomPx = 0,
    this.zones = const [],
  });
}

/// Configuration for map bounds fitting.
///
/// Two ways to drive what the map fits to:
///
/// 1. **Bounding-box mode** — all four of [north] / [south] / [east] /
///    [west] are set. The map fits to that lat/lng rectangle regardless
///    of where markers fall. Used by the `/lists` hub to fit a selected
///    city's bbox (PROD-1911). Mapbox `fitBounds(sw, ne)` natively.
///
/// 2. **Marker mode** — bbox fields are null and the caller passes
///    `fitMarkers: true` to the map widget. The map computes the bounds
///    from the marker positions. Existing default.
///
/// Either way, [padding] (or the per-side variants) controls the inset
/// from the viewport edges; [maxZoom] caps how far the fit can zoom in
/// (useful when fitting a single marker / a tiny bbox).
class MapBoundsConfig {
  /// Padding around the bounds in pixels
  final int padding;

  /// Optional different padding for each side
  final int? paddingTop;
  final int? paddingBottom;
  final int? paddingLeft;
  final int? paddingRight;

  /// Maximum zoom level when fitting bounds
  final double? maxZoom;

  /// Animation duration in milliseconds
  final int duration;

  /// North (max latitude) of an explicit bounding box. When all four
  /// edges are non-null the map fits to this rectangle instead of the
  /// marker-derived bounds.
  final double? north;

  /// South (min latitude) of an explicit bounding box.
  final double? south;

  /// East (max longitude) of an explicit bounding box.
  final double? east;

  /// West (min longitude) of an explicit bounding box.
  final double? west;

  const MapBoundsConfig({
    this.padding = 50,
    this.paddingTop,
    this.paddingBottom,
    this.paddingLeft,
    this.paddingRight,
    this.maxZoom,
    this.duration = 500,
    this.north,
    this.south,
    this.east,
    this.west,
  });

  /// True when an explicit lat/lng bbox is set on this config — callers
  /// (the platform-specific map implementations) should prefer fitting
  /// to it over the marker-derived bounds.
  bool get hasBbox =>
      north != null && south != null && east != null && west != null;

  /// Standard framing for "detail-style" surfaces — square or small tiles
  /// rendering a single primary pin (event/venue detail blocks, zine item
  /// single- and multi-pin maps). 40 px padding on every side and
  /// `maxZoom: 16` so a single pin can't auto-fit to street level.
  /// Established by PROD-2017 (zine item) and promoted to a constant by
  /// PROD-2042 once the detail blocks adopted the same numbers.
  static const MapBoundsConfig detailDefault = MapBoundsConfig(
    paddingTop: 40,
    paddingBottom: 40,
    paddingLeft: 40,
    paddingRight: 40,
    maxZoom: 16,
  );
}
