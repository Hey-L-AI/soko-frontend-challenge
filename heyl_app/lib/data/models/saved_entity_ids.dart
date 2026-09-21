/// Response of `GET /api/v1/app/users/me/saved/entity-ids`
/// (`operationId: getSavedEntityIds`, schema `SavedEntityIdsOut`).
///
/// The three arrays are already **deduplicated server-side** and map 1:1 onto
/// the saved-state id sets consumed by `isItemSavedProvider` (filled-vs-outline
/// save/bookmark buttons). This single response replaces the old per-list
/// `GET /lists/{id}/items` fan-out (one request per owned list). See
/// PROD-2844 (backend) / PROD-2845 (this migration).
///
/// Note: `venue_ids` and `google_place_ids` overlap by design — a saved local
/// venue appears in `venue_ids` and, if it also has a Google Place id,
/// additionally in `google_place_ids`. The consumer's existing OR logic
/// (`venueId ∈ venueIds || googlePlaceId ∈ googlePlaceIds`) is unchanged.
class SavedEntityIdsOut {
  final List<String> eventIds;
  final List<String> venueIds;
  final List<String> googlePlaceIds;

  const SavedEntityIdsOut({
    this.eventIds = const [],
    this.venueIds = const [],
    this.googlePlaceIds = const [],
  });

  factory SavedEntityIdsOut.fromJson(Map<String, dynamic> json) {
    // The schema marks no field required, so tolerate missing/null arrays.
    // Defensively drop non-strings and empty strings (the backend already
    // filters empty google_place_ids, but keep the client robust).
    List<String> readIds(String key) {
      final raw = json[key];
      if (raw is! List) return const [];
      return raw.whereType<String>().where((s) => s.isNotEmpty).toList();
    }

    return SavedEntityIdsOut(
      eventIds: readIds('event_ids'),
      venueIds: readIds('venue_ids'),
      googlePlaceIds: readIds('google_place_ids'),
    );
  }
}
