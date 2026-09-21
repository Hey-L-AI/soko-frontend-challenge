import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

import 'package:heyl_app/data/datasources/api/api_client.dart';
import 'package:heyl_app/data/datasources/api/share_failure.dart';
import 'package:heyl_app/data/models/share_asset.dart';
import 'package:heyl_app/data/models/share_channel_asset.dart';

/// PROD-2785 / PROD-2784 — channel-aware share-asset client.
///
/// Backend contract (verified in `open-api/heyl-webapp-v1.openapi.yaml`
/// lines 8801–8882):
///
///   `GET /api/v1/app/shares/{context}/{subject_id}/channels/instagram_story`
///   → `ShareChannelAssetOut { asset: InstagramStoryAsset, attribution_url,
///                             deep_link, ready, ... }`
///
/// Sync handler (ADR-028). First call may take ~1–2 s for the Playwright
/// render; subsequent calls hit the GCS cache and return in sub-100 ms.
abstract class SharesApi {
  /// Fetch the Instagram-Story-ready PNG + tap-back URL + bg-color hints
  /// for the given `{shareContext, entityId}`. Downloads the rendered
  /// asset to a temp file and returns a [ShareAsset] ready for the
  /// `InstagramStoryHandoff`.
  ///
  /// Throws [ShareFailure] subtypes:
  ///   - 403 → [ShareNotShareable]
  ///   - 429 → [ShareRateLimited]
  ///   - network / timeout → [ShareNetworkError]
  ///   - other HTTP / I-O → [ShareUnknown]
  Future<ShareAsset> getInstagramStoryAsset({
    required String shareContext,
    required String entityId,
  });

  /// Fetch ONLY the decoded card PNG bytes (no temp file), so it works on web.
  /// Used for in-app display of the persona card via `Image.memory`.
  Future<Uint8List> getInstagramStoryBytes({
    required String shareContext,
    required String entityId,
  });

  /// PROD-4388 — the canonical URL to put in a share sheet for
  /// `{shareContext, entityId}`.
  ///
  /// `GET /api/v1/app/shares/{context}/{subject_id}` →
  /// `attribution.share_url`, which the backend picks as
  /// `public_url ?? short_url ?? deep_link`. Preferring the server's choice
  /// keeps the preference order in ONE place instead of in every client.
  ///
  /// Throws the same [ShareFailure] subtypes as the asset calls. Callers are
  /// expected to catch and fall back to a locally-built URL — a share must
  /// never fail just because a link mint failed.
  Future<String> getShareUrl({
    required String shareContext,
    required String entityId,
  });
}

class DioSharesApi implements SharesApi {
  /// [isWeb] is a seam over the compile-time [kIsWeb] so the web-vs-native
  /// temp-file branch (PROD-3805) is unit-testable on the VM. Production
  /// leaves it at the [kIsWeb] default; tests inject `true` to drive the
  /// web path without a browser.
  DioSharesApi({required ApiClient apiClient, bool isWeb = kIsWeb})
    : _apiClient = apiClient,
      _isWeb = isWeb;

  final ApiClient _apiClient;
  final bool _isWeb;

  Dio get _dio => _apiClient.dio;

  @override
  Future<ShareAsset> getInstagramStoryAsset({
    required String shareContext,
    required String entityId,
  }) async {
    final ShareChannelAssetOut payload;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v1/app/shares/$shareContext/$entityId/channels/instagram_story',
      );
      final data = response.data;
      if (data == null) {
        throw const ShareUnknown(
          message: 'Empty response body from share-asset endpoint',
        );
      }
      payload = ShareChannelAssetOut.fromJson(data);
    } on DioException catch (e) {
      throw _mapDioError(e);
    }

    // v1.17.0 — BE now inlines the card-only PNG as base64 (no second
    // HTTP fetch). Decode once, then write to a temp file so the IG
    // handoff + `Image.file` previews can consume a real file path.
    // Bytes stay in memory so the Save-image channel can hand them to
    // the gallery / browser download without a re-read.
    //
    // PROD-3805 — web has no `path_provider_web`, so `getTemporaryDirectory()`
    // throws `UnimplementedError` and the whole fetch rejects (silent grey
    // skeleton). Skip the temp write on web and build from bytes only; the
    // web consumers (preview `Image.memory`, Save-image `imageBytes`) never
    // need a file, and direct IG-Story handoff is native-only.
    final Uint8List bytes;
    final File? imageFile;
    try {
      bytes = base64Decode(payload.asset.imageBase64);
      imageFile = _isWeb
          ? null
          : await _writeBytesToTemp(
              bytes: bytes,
              base64: payload.asset.imageBase64,
              format: payload.asset.imageFormat,
            );
    } catch (e) {
      throw ShareUnknown(message: 'Failed to decode share asset: $e');
    }

    return ShareAsset(
      imageFile: imageFile,
      imageBytes: bytes,
      attributionUrl: payload.attributionUrl,
      backgroundTopColor: payload.asset.backgroundTopColor,
      backgroundBottomColor: payload.asset.backgroundBottomColor,
    );
  }

  /// Fetches ONLY the decoded card PNG bytes (no temp-file write), so it works
  /// on web too — [getInstagramStoryAsset] writes a temp file via
  /// `getTemporaryDirectory`, which is native-only. Used to render the persona
  /// card in-app (`Image.memory`), where no file path is needed.
  @override
  Future<Uint8List> getInstagramStoryBytes({
    required String shareContext,
    required String entityId,
  }) async {
    final ShareChannelAssetOut payload;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v1/app/shares/$shareContext/$entityId/channels/instagram_story',
      );
      final data = response.data;
      if (data == null) {
        throw const ShareUnknown(
          message: 'Empty response body from share-asset endpoint',
        );
      }
      payload = ShareChannelAssetOut.fromJson(data);
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
    return base64Decode(payload.asset.imageBase64);
  }

  /// Writes the decoded PNG bytes to the app's temp directory so
  /// `Image.file` (preview tile) and `InstagramStoryHandoff.shareToStory`
  /// (sticker pasteboard) can consume a real file path.
  ///
  /// Filename includes a hash of the base64 payload so two different
  /// rendered assets don't collide; the BE keeps `(context, id)`
  /// rendering stable so the same hash repeats across calls and we don't
  /// pile up tmp files.
  @override
  Future<String> getShareUrl({
    required String shareContext,
    required String entityId,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v1/app/shares/$shareContext/$entityId',
      );
      final data = response.data;
      final attribution = data?['attribution'] as Map<String, dynamic>?;
      final shareUrl = attribution?['share_url'] as String?;
      if (shareUrl == null || shareUrl.isEmpty) {
        // An older backend has no `share_url`; fall back through the same
        // order it would have applied so a mid-rollout client still shortens.
        final fallback =
            (attribution?['public_url'] ??
                    attribution?['short_url'] ??
                    attribution?['deep_link'])
                as String?;
        if (fallback == null || fallback.isEmpty) {
          throw const ShareUnknown(
            message: 'Share descriptor carried no usable URL',
          );
        }
        return fallback;
      }
      return shareUrl;
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  Future<File> _writeBytesToTemp({
    required Uint8List bytes,
    required String base64,
    required String format,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final ext = format.toLowerCase();
    final fileName =
        'share_ig_story_${bytes.length}_${base64.hashCode.toRadixString(16)}.$ext';
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  ShareFailure _mapDioError(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.connectionError) {
      return const ShareNetworkError();
    }

    final status = e.response?.statusCode;
    switch (status) {
      case 403:
        final detail = _stringField(e.response?.data, 'detail');
        return ShareNotShareable(detail: detail);
      case 429:
        return const ShareRateLimited();
      default:
        return ShareUnknown(
          statusCode: status,
          message: _stringField(e.response?.data, 'detail'),
        );
    }
  }

  String? _stringField(dynamic body, String key) {
    if (body is Map<String, dynamic>) {
      final value = body[key];
      if (value is String) return value;
    }
    return null;
  }
}
