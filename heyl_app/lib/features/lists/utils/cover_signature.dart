import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../data/models/user_list.dart';

/// PROD-3217 — canonical signature of a list's zine-cover recipe.
///
/// MUST stay byte-identical to the backend mirror
/// (`heyl-backend/heyl/apps/shares/cover_signature.py`) — the app's freshness
/// decision and the backend stale-guard only agree if both produce the same
/// sha1 hex. Pinned by a golden vector on both sides
/// (`test/features/lists/cover_signature_test.dart` and the Python
/// `test_cover_signature.py`).
///
/// Contract:
/// * canonical string = `parts.join('|')`, then sha1(utf-8) hex.
/// * null/absent → `''`; bool → `'1'` / `'0'`.
/// * field order is fixed (below).
///
/// We sign only the RAW recipe fields the user edits (plus the list name, which
/// is baked into the PNG) — every user-facing cover change mutates one of them
/// (including [UserList.coverItemId] when the cover item is switched). Derived
/// values (resolved item-image URL, the newest-item fallback photo) are
/// deliberately NOT signed: matching them across FE/BE adds drift risk for a
/// rare case. Known, accepted gap: a cover whose photo mutates underneath a
/// fixed `cover_item_id` won't bust the signature on content change alone.
String computeCoverRenderSignature(UserList list) {
  final parts = <String>[
    list.coverType ?? '',
    list.coverColor ?? '',
    list.coverTexture ?? '',
    list.coverTextColor ?? '',
    list.coverItemId ?? '',
    list.coverImageUrl ?? '',
    list.coverShowTitle ? '1' : '0',
    list.coverShowTexture ? '1' : '0',
    list.coverShowLogo ? '1' : '0',
    list.name,
  ];
  return sha1.convert(utf8.encode(parts.join('|'))).toString();
}
