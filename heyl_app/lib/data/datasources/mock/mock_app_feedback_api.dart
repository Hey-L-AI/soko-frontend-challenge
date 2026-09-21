import 'package:flutter/foundation.dart';

import '../../../features/feedback/app_feedback_area.dart';
import '../api/app_feedback_api.dart';

/// Mock app-feedback API — logs the submission and succeeds after a short
/// delay. Used behind [useMockApiProvider] for UI prototyping and tests.
class MockAppFeedbackApi implements IAppFeedbackApi {
  @override
  Future<void> submitAppFeedback({
    required AppFeedbackArea area,
    String? sessionId,
    String? issueText,
    String? ideaText,
    String? issueAudioPath,
    String? ideaAudioPath,
    String? appVersion,
    String? platform,
    String? locale,
  }) async {
    debugPrint(
      '[MockAppFeedbackApi] area=${area.wire} session=$sessionId '
      'issue="${issueText ?? ''}" idea="${ideaText ?? ''}" '
      'issueAudio=${issueAudioPath != null} ideaAudio=${ideaAudioPath != null}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
}
