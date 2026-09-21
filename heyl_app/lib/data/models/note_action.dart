/// The authoritative note transition a list-item write applied to the item's
/// note (its `tip`), as returned by the backend on every list-item write
/// response (`UserListItemAddOut`, `UserListItemWriteOut`) — see PROD-4552 and
/// `docs/api/list-item-note-transitions.md` in heyl-backend.
///
/// The transition is derived by the backend from the persisted before/after
/// values inside the writing transaction, so the client never infers it. A
/// backend predating PROD-4552 omits the field; the client must then report
/// [unknown] rather than guess a transition, and reporting excludes unknown
/// transitions from exact rates.
enum NoteAction {
  /// A note where there was none.
  added('added'),

  /// Changed to different non-empty text (a case change counts as an edit).
  updated('updated'),

  /// The note was cleared.
  removed('removed'),

  /// No note either side, or the same note after trimming/NFC normalization.
  unchanged('unchanged'),

  /// The backend response carried no transition metadata (older server). Report
  /// it, but exclude it from exact note-behaviour rates.
  unknown('unknown');

  const NoteAction(this.wire);

  /// The wire value carried in analytics payloads and returned by the backend.
  final String wire;

  /// Parse a backend `note_action` value. A null or unrecognised value — an
  /// older backend that omits the field, or a value from a newer contract —
  /// maps to [unknown] rather than throwing, so a stale client degrades to an
  /// honest "unknown" instead of crashing or inventing a transition.
  static NoteAction fromWire(String? value) {
    for (final action in NoteAction.values) {
      if (action.wire == value) return action;
    }
    return NoteAction.unknown;
  }

  /// Whether this transition actually changed the note. [unchanged] is a no-op
  /// (suppress the `list_element_note` event); [unknown] is a confirmed write
  /// whose transition we can't classify, so it is still reported.
  bool get isNoteChange =>
      this == NoteAction.added ||
      this == NoteAction.updated ||
      this == NoteAction.removed;
}
