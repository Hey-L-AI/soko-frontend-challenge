/// What kind of executed selection a past-search entry re-executes
/// (PROD-3499). Wire values match the backend enum exactly.
enum MapSearchHistoryType {
  keyword,
  venue,
  event,
  location,
  list;

  /// Wire string for requests (`keyword | venue | event | location | list`).
  String get wire => name;

  /// Null for values this client version doesn't know — callers skip those
  /// entries instead of failing the whole history fetch.
  static MapSearchHistoryType? fromWire(String? value) {
    for (final t in MapSearchHistoryType.values) {
      if (t.name == value) return t;
    }
    return null;
  }
}

/// One past-search entry served by `GET /map/search-history` (PROD-3495
/// contract). Served as-is — no staleness guarantees; the client resolves
/// the target on tap (Decision #21).
class MapSearchHistoryEntry {
  final String id;
  final MapSearchHistoryType type;

  /// Entity id for venue/event/list, `/geo/areas` prediction id (possibly
  /// non-UUID) for location, null for keyword.
  final String? targetId;

  /// The raw typed text — always present for keyword, optional otherwise.
  final String? queryText;

  /// What the row shows. Client-supplied at record time; the server never
  /// re-derives it (a renamed venue keeps its old label until re-selected).
  final String displayLabel;

  final String? imageUrl;
  final DateTime lastUsedAt;

  const MapSearchHistoryEntry({
    required this.id,
    required this.type,
    this.targetId,
    this.queryText,
    required this.displayLabel,
    this.imageUrl,
    required this.lastUsedAt,
  });

  /// Throws on unknown [type] — list parsers pre-filter via
  /// [MapSearchHistoryType.fromWire] to skip forward-incompatible entries.
  factory MapSearchHistoryEntry.fromJson(Map<String, dynamic> j) =>
      MapSearchHistoryEntry(
        id: j['id'] as String,
        type: MapSearchHistoryType.fromWire(j['type'] as String?)!,
        targetId: j['target_id'] as String?,
        queryText: j['query_text'] as String?,
        displayLabel: j['display_label'] as String,
        imageUrl: j['image_url'] as String?,
        lastUsedAt: DateTime.parse(j['last_used_at'] as String),
      );
}
