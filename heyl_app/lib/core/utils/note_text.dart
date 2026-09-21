import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Shared note normalization + measurement for the note-transition analytics
/// (PROD-4553). These mirror the single cross-language rule from heyl-backend's
/// `normalize_note()` (`docs/api/list-item-note-transitions.md`), so the
/// client-computed `has_note` and `note_length` agree with the backend's
/// authoritative `note_action`. Never send the note text itself — only these
/// derived values travel.

/// Normalize a note the same way the backend does before comparing or measuring
/// it: Unicode **NFC**-normalize, then strip leading/trailing whitespace. A
/// null or empty note normalizes to the empty string.
String normalizeNote(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  return unorm.nfc(raw).trim();
}

/// Whether a note is present: its normalized form is non-empty.
bool noteIsPresent(String? raw) => normalizeNote(raw).isNotEmpty;

/// The note's length in Unicode **code points** of its normalized form, to
/// agree with the backend (Python `len(str)`), never UTF-16 code units or
/// bytes. `String.runes` yields code points, so an emoji outside the BMP counts
/// as one. An absent or whitespace-only note has length 0.
int noteLength(String? raw) => normalizeNote(raw).runes.length;
