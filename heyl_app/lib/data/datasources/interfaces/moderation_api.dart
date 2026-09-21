import '../../models/moderation.dart';

/// UGC moderation API (PROD-2264): reports + blocks.
abstract class IModerationApi {
  /// Submit a UGC moderation report. Idempotent within a rolling 24-hour
  /// window on `(reporter, target_type, target_id, reason)`. Rate-limited to
  /// 10 user-initiated reports per hour.
  Future<ReportCreated> submitReport(ReportCreateRequest request);

  /// Block another user. Writes a companion `Report` row in the same
  /// transaction so backoffice T&S sees the abuse pattern. Idempotent.
  Future<BlockCreated> blockUser(BlockCreateRequest request);

  /// List the caller's active blocks.
  Future<List<BlockedUser>> listBlocks();

  /// Unblock a user (soft-delete). Returns whether or not the block existed
  /// for the caller — the server intentionally does not leak that.
  Future<void> unblock(String blockId);
}
