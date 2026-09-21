import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/datasources/interfaces/moderation_api.dart';
import '../../../data/models/moderation.dart';
import '../../../providers/api_provider.dart';

/// Outcome of a [ReportSubmissionController.submit] call. The sheet uses
/// this to pick the right user-facing toast.
sealed class ReportSubmissionResult {
  const ReportSubmissionResult();
}

class ReportSubmissionSuccess extends ReportSubmissionResult {
  final ReportCreated report;
  const ReportSubmissionSuccess(this.report);
}

class ReportSubmissionRateLimited extends ReportSubmissionResult {
  const ReportSubmissionRateLimited();
}

class ReportSubmissionTargetNotFound extends ReportSubmissionResult {
  const ReportSubmissionTargetNotFound();
}

class ReportSubmissionError extends ReportSubmissionResult {
  final Object error;
  const ReportSubmissionError(this.error);
}

/// Outcome of a [ReportSubmissionController.block] call.
sealed class BlockSubmissionResult {
  const BlockSubmissionResult();
}

class BlockSubmissionSuccess extends BlockSubmissionResult {
  final BlockCreated block;
  const BlockSubmissionSuccess(this.block);
}

class BlockSubmissionSelfTarget extends BlockSubmissionResult {
  const BlockSubmissionSelfTarget();
}

class BlockSubmissionTargetNotFound extends BlockSubmissionResult {
  const BlockSubmissionTargetNotFound();
}

class BlockSubmissionError extends BlockSubmissionResult {
  final Object error;
  const BlockSubmissionError(this.error);
}

/// Thin wrapper around [IModerationApi] that classifies submission
/// outcomes the sheet cares about (429 → rate-limited, 404 → gone, other
/// errors → generic failure). PROD-2264.
class ReportSubmissionController {
  final IModerationApi _api;

  ReportSubmissionController(this._api);

  Future<ReportSubmissionResult> submit(ReportCreateRequest request) async {
    try {
      final created = await _api.submitReport(request);
      return ReportSubmissionSuccess(created);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 429) return const ReportSubmissionRateLimited();
      if (status == 404) return const ReportSubmissionTargetNotFound();
      debugPrint('[Moderation] report submit failed (status=$status): $e');
      return ReportSubmissionError(e);
    } catch (e) {
      debugPrint('[Moderation] report submit failed: $e');
      return ReportSubmissionError(e);
    }
  }

  Future<BlockSubmissionResult> block(BlockCreateRequest request) async {
    try {
      final created = await _api.blockUser(request);
      return BlockSubmissionSuccess(created);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 400) return const BlockSubmissionSelfTarget();
      if (status == 404) return const BlockSubmissionTargetNotFound();
      debugPrint('[Moderation] block failed (status=$status): $e');
      return BlockSubmissionError(e);
    } catch (e) {
      debugPrint('[Moderation] block failed: $e');
      return BlockSubmissionError(e);
    }
  }
}

final reportSubmissionControllerProvider = Provider<ReportSubmissionController>(
  (ref) {
    return ReportSubmissionController(ref.watch(moderationApiProvider));
  },
);
