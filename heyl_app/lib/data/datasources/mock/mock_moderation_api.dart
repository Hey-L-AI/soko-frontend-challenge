import '../../models/moderation.dart';
import '../interfaces/moderation_api.dart';

/// In-memory mock of [IModerationApi] for offline/test runs.
class MockModerationApi implements IModerationApi {
  final List<BlockedUser> _blocks = [];
  int _reportSeq = 0;
  int _blockSeq = 0;

  @override
  Future<ReportCreated> submitReport(ReportCreateRequest request) async {
    _reportSeq++;
    return ReportCreated(
      reportId: 'mock-report-$_reportSeq',
      status: ReportStatus.pending,
      createdAt: DateTime.now().toUtc(),
      idempotentHit: false,
    );
  }

  @override
  Future<BlockCreated> blockUser(BlockCreateRequest request) async {
    _blockSeq++;
    final now = DateTime.now().toUtc();
    final existing = _blocks.where(
      (b) => b.blockedUserId == request.blockedUserId,
    );
    if (existing.isNotEmpty) {
      return BlockCreated(
        blockId: existing.first.blockId,
        reportId: 'mock-report-$_reportSeq',
        blockedUserId: request.blockedUserId,
        createdAt: existing.first.createdAt,
      );
    }
    final blockId = 'mock-block-$_blockSeq';
    _blocks.add(
      BlockedUser(
        blockId: blockId,
        blockedUserId: request.blockedUserId,
        blockedUserDisplayName: 'Blocked User $_blockSeq',
        createdAt: now,
      ),
    );
    return BlockCreated(
      blockId: blockId,
      reportId: 'mock-report-$_reportSeq',
      blockedUserId: request.blockedUserId,
      createdAt: now,
    );
  }

  @override
  Future<List<BlockedUser>> listBlocks() async => List.unmodifiable(_blocks);

  @override
  Future<void> unblock(String blockId) async {
    _blocks.removeWhere((b) => b.blockId == blockId);
  }
}
