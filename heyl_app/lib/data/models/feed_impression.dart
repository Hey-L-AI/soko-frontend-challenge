/// One viewport impression sent to POST /feed/impressions for seen-suppression.
/// Only the persisted trio plus [surface] reach the store — shelf_id/card_index/
/// visible_ms ride the analytics path (`item_impression`), not this write.
class FeedImpressionIn {
  final String itemId;

  /// `'event' | 'venue' | 'zine' | 'person'` (v1.160.0).
  ///
  /// ⚠️ **`zine` on the wire, `list` in the store.** The app calls a public list
  /// a zine; `user_entity_impressions` calls it a `list`, and the server
  /// translates at the boundary. Posting `'list'` is a **422** — it is the
  /// store's spelling, not the client's.
  ///
  /// `person` opened in v1.160.0 (PROD-4451) and **nothing in this app posts
  /// one.** The people grid is deliberately off this rail (PROD-4511): the
  /// Pessoas feed suppresses nothing, and hiding a suggestion because the
  /// viewer scrolled past it is explicitly out of scope. It writes to the
  /// engagement ledger instead, whose `item_type` is an open string. So the
  /// enum is wider than the client's behaviour, on purpose — if you are here
  /// to "finish the job" by sending one, that is a product decision, not a
  /// loose end.
  final String itemType;

  final DateTime seenAt;

  /// Which **block class** showed the card (v1.112.0, PROD-4069) — one of
  /// `hero`, `bundle_highlight`, `bundle_see_all`.
  ///
  /// A hero is hard to miss and a row in a long list is easy to scroll past,
  /// so the two no longer count as equal evidence: the backend maps this to a
  /// `retrieval_type` with its own weight in seen-suppression.
  ///
  /// **A coarse class, never a slot.** Block id and card position stay off
  /// this rail and travel on the `item_impression` analytics event; the store
  /// splits rows per surface and re-merges them with weights at read, so one
  /// entity still reads as one exposure count.
  ///
  /// Safe to send ahead of the backend release: `FeedImpressionIn` is
  /// `extra="ignore"` server-side, so a backend predating v1.112.0 drops the
  /// field rather than rejecting the batch. Omitting it records at the flat
  /// feed weight, exactly as before the field existed.
  final String? surface;

  const FeedImpressionIn({
    required this.itemId,
    required this.itemType,
    required this.seenAt,
    this.surface,
  });

  Map<String, dynamic> toJson() => {
    'item_id': itemId,
    'item_type': itemType,
    'seen_at': seenAt.toUtc().toIso8601String(),
    if (surface != null) 'surface': surface,
  };
}

/// The `surface` values the client sends on both impression rails.
///
/// **Deliberately the same strings on both** — `FeedImpressionIn.surface`
/// (suppression) and the `item_impression` analytics event — so a
/// `GROUP BY surface` means one thing across the two stores. The vocabulary is
/// the backend's, from v1.112.0; it is an open string there, not an enum, so
/// an unknown value degrades to the default weight instead of 422ing a batch.
abstract final class FeedImpressionSurface {
  /// An `event_hero` block — full-width, hard to miss.
  static const String hero = 'hero';

  /// A highlighted row on a home-page bundle.
  static const String bundleHighlight = 'bundle_highlight';

  /// A row on a bundle's see-all page — displayed is not read.
  static const String bundleSeeAll = 'bundle_see_all';

  /// A tile in the Sítios page's *Perto de ti* grid (PROD-4108).
  ///
  /// ⚠️ **Client-added, and not yet one of the backend's weighted values.** The
  /// other three come from the backend's v1.112.0 vocabulary; this one names a
  /// surface that did not exist when that list was written. Sending it is safe
  /// by the backend's own design — `surface` is an open string there, so an
  /// unknown value degrades to the **default weight** rather than 422ing a
  /// batch.
  ///
  /// Naming it honestly beats reusing `bundle_highlight`: a grid tile is not a
  /// bundle row, and mislabelling it would make a `GROUP BY surface` quietly
  /// wrong in a way nothing would ever flag. Today it rides the click event
  /// only — the home feed's impression detectors are PROD-4008's scope, so the
  /// grid emits clicks without impressions exactly as the hero and highlighted
  /// bundle rows do.
  static const String venueGrid = 'venue_grid';

  /// A tile in one of the Zines page's three `zine_grid` blocks (PROD-4118).
  ///
  /// Unlike [venueGrid], this one **is** in the backend's vocabulary — it was
  /// registered with the zines feed (spec v1.119.0) and maps to a weighted
  /// `feed_zine_*` retrieval type rather than falling back to the default.
  static const String zineGrid = 'zine_grid';

  /// A card in the Pessoas feed's `people_grid` block (PROD-4511).
  ///
  /// Like [venueGrid] and unlike [zineGrid], this is **client-added**: it names
  /// a surface that postdates the backend's v1.112.0 vocabulary. Safe by the
  /// backend's own design — `surface` is an open string on both rails, so an
  /// unrecognised value records at the flat weight rather than 422ing the
  /// batch. It lands as `retrieval_type='feed_people_grid'`.
  ///
  /// ⚠️ **This surface rides the ENGAGEMENT rail only.** No `FeedImpressionIn`
  /// is ever posted for a person — see [FeedImpressionIn.itemType]. The
  /// constant lives here anyway because the vocabulary is deliberately shared
  /// across both rails, so a `GROUP BY surface` means one thing wherever it is
  /// run; splitting it would be the first crack in that.
  static const String peopleGrid = 'people_grid';

  /// A highlighted row on a zine bundle, on the home page.
  ///
  /// Deliberately **not** [bundleHighlight]: the two are different corpora with
  /// different weights, and merging them would make an entity's exposure count
  /// depend on which feed page it happened to appear on.
  static const String zineBundleHighlight = 'zine_bundle_highlight';

  /// A row on a zine bundle's see-all page.
  static const String zineBundleSeeAll = 'zine_bundle_see_all';

  /// The see-all surface for a bundle carrying [itemType].
  ///
  /// The see-all page is one widget over three entity types, so the surface it
  /// reports has to be derived rather than fixed — it used to be a constant,
  /// which was right while only events and venues shared the page.
  static String bundleSeeAllFor(String itemType) =>
      itemType == 'zine' ? zineBundleSeeAll : bundleSeeAll;

  /// The home-page highlighted-row surface for a bundle carrying [itemType].
  static String bundleHighlightFor(String itemType) =>
      itemType == 'zine' ? zineBundleHighlight : bundleHighlight;
}
