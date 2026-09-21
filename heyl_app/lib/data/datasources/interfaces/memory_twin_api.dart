import '../../models/models.dart';

/// Read + delete + export contract for the twin-shaped memory endpoints.
///
/// Mirror of OpenAPI `UserMemory` tag (PROD-1617 / PROD-1914):
///   - GET    /api/v1/app/users/me/memory                              → twin
///   - DELETE /api/v1/app/users/me/memory?confirm=true                 → bulk clear
///   - DELETE /api/v1/app/users/me/memory/facts/{fact_id}              → 204
///   - DELETE /api/v1/app/users/me/memory/facts/observations/{obs_id}  → 204
///   - DELETE /api/v1/app/users/me/memory/facts/dimensions/{dim_name}  → 204
///   - POST   /api/v1/app/users/me/memory/facts/chips/suppress         → 204
///   - POST   /api/v1/app/users/me/memory/facts/chips/nudge            → { nudge_level }
///   - GET    /api/v1/app/users/me/memory/export                       → bytes (JSON download)
abstract class IMemoryTwinApi {
  Future<MemoryTwinResponse> getTwin();
  Future<BulkClearResponse> clearAll();
  Future<void> deleteFact(String factId);
  Future<void> deleteObservation(String observationId);
  Future<void> deleteDimension(String dimensionName);

  /// Hide one (dimension, value) chip without deleting its backing facts
  /// (the saved item and the chip's sibling chips stay).
  Future<void> suppressChip({
    required String dimension,
    String? family,
    required String value,
  });

  /// Push a chip's tick level down (−) or up (+). Returns the new net level.
  Future<int> nudgeChip({
    required String dimension,
    String? family,
    required String value,
    required bool increase,
  });

  Future<List<int>> exportJson();

  /// "Conta-nos sobre ti": submit a free-text self-description, which the
  /// backend turns into user_stated memory facts immediately (Phase 5).
  ///   - POST /api/v1/app/users/me/memory/tell-us  → { status, facts_written, facts }
  Future<TellUsResult> tellUs(String text);
}
