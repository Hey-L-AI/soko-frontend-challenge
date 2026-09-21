/// Sibling-navigation context for venue/event detail screens.
///
/// When a user opens a detail from a multi-item source (a chat message's
/// card array, or a saved list's items), the source attaches a
/// [DetailSiblings] via go_router's `extra`. The detail screen reads it
/// and enables horizontal-swipe navigation between siblings — swiping
/// left/right calls `context.replace()` to the prev/next sibling route
/// with an updated [DetailSiblings] (only `currentIndex` changes).
///
/// **Not persistent.** Refreshing or deep-linking lands on the single
/// detail without the array context — the navigation falls back to
/// "use the OS back button to return to the source".
enum DetailSiblingType { event, place }

class DetailSibling {
  final DetailSiblingType type;
  final String id;

  const DetailSibling({required this.type, required this.id});
}

class DetailSiblings {
  final List<DetailSibling> items;
  final int currentIndex;

  /// Optional list scoping — when present, route paths are emitted as
  /// `/lists/<listId>/venues/<id>` / `/lists/<listId>/events/<id>` so
  /// swipe navigation stays inside the in-list detail flow. Null for
  /// chat-sourced navigation, which uses standalone detail routes.
  final String? listId;

  const DetailSiblings({
    required this.items,
    required this.currentIndex,
    this.listId,
  });

  bool get hasPrev => currentIndex > 0;
  bool get hasNext => currentIndex < items.length - 1;

  DetailSibling get current => items[currentIndex];
  DetailSibling? get prev => hasPrev ? items[currentIndex - 1] : null;
  DetailSibling? get next => hasNext ? items[currentIndex + 1] : null;

  DetailSiblings withIndex(int index) => DetailSiblings(
        items: items,
        currentIndex: index,
        listId: listId,
      );

  /// Returns the route path for [sibling] under this collection's list
  /// scoping (in-list when `listId` is set, standalone otherwise).
  String routeFor(DetailSibling sibling) {
    final segment = sibling.type == DetailSiblingType.event ? 'events' : 'venues';
    if (listId != null) {
      return '/lists/$listId/$segment/${sibling.id}';
    }
    return '/$segment/${sibling.id}';
  }
}
