import 'package:shared_preferences/shared_preferences.dart';

/// Persists the image-derived background colour for zine detail (item)
/// pages to SharedPreferences (PROD-4072).
///
/// Each item's colour is extracted from its poster image once and then
/// reused forever, keyed by the item's **stable id**. The stored value is
/// the ARGB int (`Color.toARGB32()`). Keying by item id — not the image URL —
/// freezes the colour against later image / proxy-URL changes, which is
/// the ticket's requirement: "generate on first load and then keep using
/// the same forever".
///
/// Bumping the `v1` prefix invalidates every cached colour at once — use
/// that when the extraction algorithm itself changes (a content-neutral
/// way to force a recompute for all items).
class ZineItemColorCache {
  ZineItemColorCache(this._prefs);

  // v5 (PROD-4072): standout-hue → snap to nearest Soko brand pastel.
  // Bumping the version invalidates every colour cached under an earlier
  // algorithm so they recompute once with the current one.
  static const _prefix = 'zine_item_color_v5_';

  final SharedPreferences _prefs;

  String _key(String itemId) => '$_prefix$itemId';

  /// Cached ARGB colour value for [itemId], or null on a cache miss.
  int? read(String itemId) => _prefs.getInt(_key(itemId));

  /// Persists [argb] (a `Color.toARGB32()`) for [itemId], reused on every
  /// subsequent load.
  Future<void> write(String itemId, int argb) =>
      _prefs.setInt(_key(itemId), argb);
}
