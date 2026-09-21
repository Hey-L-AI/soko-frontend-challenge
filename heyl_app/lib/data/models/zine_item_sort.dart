/// Server-side ordering for a zine's items — the `sort` query param on the
/// four zine-item endpoints (backend v1.128.0).
///
/// `null` is a real, distinct choice: omitting `sort` keeps whatever order
/// the list itself carries, including an owner's hand-arranged `custom`
/// sequence. There is deliberately no wire value for `custom` — omission is
/// how a client asks for it. Sending a value overrides the list's stored
/// `sort_mode` for that request only and writes nothing back.
///
/// Same vocabulary as `GET /users/me/library` (see `LibrarySort`).
enum ZineItemSort {
  /// By `user_list_items.added_at` DESC — when the item was added to THIS
  /// list. Never the tip or any later edit: `added_at` is stamped once at
  /// insert with no `onupdate` (`updated_at` is the one that moves).
  ///
  /// Deliberately NOT the same thing `recent` means on `GET /users/me/library`,
  /// where recency also folds in follows and the latest client `view_item`.
  /// Same wire word, narrower meaning here — hence the UI label
  /// "Recently added" rather than the library's bare "Recent".
  recent,

  /// By event title / venue name, accent- and case-folded by the DB collation.
  alphabetical,

  /// By next occurrence still ahead (a past one does not count); places have
  /// no date and fall to the end. The event's date, NOT the added date.
  chronological;

  String get wire => name;

  /// Whether this ordering ranks by the EVENTS' own dates.
  ///
  /// The server has no date for a place, so places sink to the end under such
  /// a sort. The list view partitions by type before rendering, so it promotes
  /// the Events section above Places here — otherwise the rows the user just
  /// asked to order by date sit below a Places block that the sort did not
  /// touch. A future event-centric sort only has to answer true here.
  bool get ordersByEventDate => this == ZineItemSort.chronological;
}
