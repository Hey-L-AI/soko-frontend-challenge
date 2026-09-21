/// Shared `Hero` tags for the zine-page → item-detail shared-element morph
/// (PROD-4160-followup).
///
/// **The only page-open flight left in the app.** The sibling flights this file
/// once served — feed/Library card → detail, Library/feed thumbnail → zine
/// cover — were deliberately reverted: when every page open had a shared
/// element the effect stopped meaning anything, and those opens now simply
/// slide in from the side (`_slidePage` in `app_router.dart`). Do not
/// reintroduce a tag here for a new surface without that being the point.
///
/// Tapping a zine item card flies two coordinated Heroes into the in-list
/// detail page: the poster image (bottom-right of the card → the detail's top
/// [SokoPhotoCollage] main tile) and the card's background colour panel (→ the
/// detail's coloured card region). Both are keyed by the entity id so the
/// source (zine card) and destination (detail) match.
///
/// [zineDetailPosterHeroTag] deliberately returns the **same** string the
/// collage main tile already uses for its fullscreen-gallery Hero
/// (`soko_photo_collage.dart` → `'detail-collage-photo:$seed:main'`, where
/// `seed == entityId`). Reusing it means the zine poster and the collage tile
/// share one Hero identity with no edit to the shared collage widget — the
/// buried zine card is simply ignored during the later detail → gallery
/// transition (only the top two routes animate). Keep the two strings in sync.
library;

/// Poster image Hero tag — matches the collage main tile's gallery Hero tag.
String zineDetailPosterHeroTag(String entityId) =>
    'detail-collage-photo:$entityId:main';

/// Background colour-panel Hero tag — its own namespace, distinct from the
/// poster/gallery tag above.
String zineDetailColorHeroTag(String entityId) => 'zine-detail-color:$entityId';
