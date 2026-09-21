import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/constants/api_constants.dart';
import '../../../features/feedback/app_feedback_area.dart';
import 'api_client.dart';

/// Contract for submitting app-wide feedback (PROD-2900).
///
/// One submission carries an optional "report an issue" and/or "give an idea"
/// note, each with an optional voice attachment. Voice notes are transcribed
/// server-side (Whisper) — the client only uploads the audio; there is no
/// client-side transcription.
abstract class IAppFeedbackApi {
  /// Submit one feedback entry. Throws [DioException] on failure.
  ///
  /// [issueAudioPath] / [ideaAudioPath] are the recorder outputs: a `blob:`
  /// URL on web, a file path on mobile. At least one of the text/audio fields
  /// should be non-empty (the server rejects a fully-empty submission with 422).
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
  });
}

/// Real implementation backed by `POST /api/v1/app/app-feedback` (multipart).
class AppFeedbackApi implements IAppFeedbackApi {
  final ApiClient _apiClient;

  AppFeedbackApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

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
    final formMap = <String, dynamic>{
      'area': area.wire,
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      if (issueText != null && issueText.trim().isNotEmpty)
        'issue_text': issueText.trim(),
      if (ideaText != null && ideaText.trim().isNotEmpty)
        'idea_text': ideaText.trim(),
      if (appVersion != null && appVersion.isNotEmpty)
        'app_version': appVersion,
      if (platform != null && platform.isNotEmpty) 'platform': platform,
      if (locale != null && locale.isNotEmpty) 'locale': locale,
    };

    final issueAudio = await _audioMultipart(issueAudioPath, 'issue');
    if (issueAudio != null) formMap['issue_audio'] = issueAudio;
    final ideaAudio = await _audioMultipart(ideaAudioPath, 'idea');
    if (ideaAudio != null) formMap['idea_audio'] = ideaAudio;

    final formData = FormData.fromMap(formMap);

    debugPrint('[AppFeedbackApi] Submitting feedback (area=${area.wire})');
    await _dio.post(
      ApiConstants.appFeedback,
      data: formData,
      options: Options(
        contentType: 'multipart/form-data',
        sendTimeout: ApiConstants.uploadTimeout,
        receiveTimeout: ApiConstants.uploadTimeout,
      ),
    );
  }

  /// Build a [MultipartFile] for a recorder output, or null when [path] is
  /// empty. Mirrors the voice-message upload: on web the recorder yields a
  /// `blob:` URL whose bytes must be fetched first.
  ///
  /// The filename and content type must describe the *actual* container, which
  /// differs per platform (see [AudioRecorderService]): web records Opus in
  /// WebM, iOS records AAC in MP4 (`.m4a`), Android records Opus in Ogg. Naming
  /// everything `.webm` and letting Dio default the type to
  /// `application/octet-stream` made the server reject every mobile recording
  /// (PROD-2990).
  Future<MultipartFile?> _audioMultipart(String? path, String box) async {
    if (path == null || path.isEmpty) return null;

    if (kIsWeb && path.startsWith('blob:')) {
      final bytes = await _fetchBlobData(path);
      return MultipartFile.fromBytes(
        bytes,
        filename: '$box.webm',
        contentType: DioMediaType('audio', 'webm'),
      );
    }

    final (ext, mimeSubtype) = _containerFor(path);
    return MultipartFile.fromFile(
      path,
      filename: '$box.$ext',
      contentType: DioMediaType('audio', mimeSubtype),
    );
  }

  /// Map a recorder output path to its (extension, audio MIME subtype).
  ///
  /// Falls back to the platform default when the path carries no extension.
  (String, String) _containerFor(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot == -1 ? '' : path.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'm4a' => ('m4a', 'mp4'),
      'mp4' => ('mp4', 'mp4'),
      'ogg' => ('ogg', 'ogg'),
      'opus' => ('ogg', 'ogg'),
      'wav' => ('wav', 'wav'),
      'webm' => ('webm', 'webm'),
      'mp3' => ('mp3', 'mpeg'),
      _ => defaultTargetPlatform == TargetPlatform.iOS
          ? ('m4a', 'mp4')
          : ('ogg', 'ogg'),
    };
  }

  Future<Uint8List> _fetchBlobData(String blobUrl) async {
    final response = await http.get(Uri.parse(blobUrl));
    if (response.statusCode == 200) {
      return response.bodyBytes;
    }
    throw Exception('Failed to fetch blob data: ${response.statusCode}');
  }
}
