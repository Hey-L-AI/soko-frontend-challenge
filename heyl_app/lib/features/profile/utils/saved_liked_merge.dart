import '../../../data/models/saved_item.dart';

/// One row of the profile Saved tab, and why it is there (PROD-3779).
///
/// [saved] and [liked] are independent — saving says "I want to go", liking
/// says "I liked it", and an entity can carry both. The row paints a marker per
/// true flag rather than picking one, because hiding either would hide a fact
/// the user stated.
class SavedOrLikedItem {
  final SavedItem item;
  final bool saved;
  final bool liked;

  const SavedOrLikedItem({
    required this.item,
    required this.saved,
    required this.liked,
  });
}

/// Identity of the underlying entity. Deliberately NOT `savedId`: the same
/// venue arrives with a saved-item id in the saved list and a signal-row id in
/// the liked list, so keying on it would show one entity as two rows.
String savedItemEntityKey(SavedItem it) =>
    it.eventId ?? it.venueId ?? it.savedId;

/// The owner's Saved tab list for one segment: their saves, plus the entities
/// they liked, newest first.
///
/// [wantEvent] picks the segment (Events vs Places) — an item is an event iff
/// it carries an `eventId`, mirroring how the tab has always split them.
///
/// When [showLikes] is false the result is exactly the saved list with no
/// markers: that is a visitor's view, which PROD-3779 leaves untouched because
/// a like is not public.
///
/// A saved+liked entity appears ONCE, taking the saved list's copy (both are
/// the same entity card; only the id and timestamp differ). Ordering uses
/// `createdAt`, which is the save time for a save and `rated_at` for a like —
/// "most recently acted on", which is what a merged list should read as.
List<SavedOrLikedItem> mergeSavedAndLiked({
  required List<SavedItem> saved,
  required List<SavedItem> liked,
  required bool wantEvent,
  required bool showLikes,
}) {
  bool inSegment(SavedItem it) => (it.eventId != null) == wantEvent;

  final savedInSegment = saved.where(inSegment).toList();
  if (!showLikes) {
    return [
      for (final it in savedInSegment)
        SavedOrLikedItem(item: it, saved: false, liked: false),
    ];
  }

  final savedKeys = savedInSegment.map(savedItemEntityKey).toSet();
  final likedKeys = liked.map(savedItemEntityKey).toSet();
  final likedOnly = liked
      .where((it) => inSegment(it) && !savedKeys.contains(savedItemEntityKey(it)))
      .toList();

  final rows = [
    for (final it in [...savedInSegment, ...likedOnly])
      SavedOrLikedItem(
        item: it,
        saved: savedKeys.contains(savedItemEntityKey(it)),
        liked: likedKeys.contains(savedItemEntityKey(it)),
      ),
  ]..sort((a, b) => b.item.createdAt.compareTo(a.item.createdAt));

  return rows;
}
