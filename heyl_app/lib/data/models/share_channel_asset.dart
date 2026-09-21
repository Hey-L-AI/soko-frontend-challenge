/// PROD-2785 / PROD-2784 — channel-asset endpoint response.
///
/// Mirrors `ShareChannelAssetOut` from `open-api/heyl-webapp-v1.openapi.yaml`.
/// Returned by `GET /api/v1/app/shares/{context}/{subject_id}/channels/{channel}`.
class ShareChannelAssetOut {
  const ShareChannelAssetOut({
    required this.channel,
    required this.context,
    required this.id,
    required this.asset,
    required this.attributionUrl,
    required this.deepLink,
    required this.ready,
  });

  final String channel;
  final String context;
  final String id;

  /// Per-channel polymorphic payload. For `instagram_story` this is an
  /// [InstagramStoryAsset]; future channels (`copy_link`, `whatsapp`,
  /// `og_image`, `tiktok_story`) each define their own payload schema in
  /// this same slot.
  final InstagramStoryAsset asset;

  /// Channel-agnostic shortio URL.
  final String attributionUrl;

  /// Deep link to the in-app destination, with `utm_source=<channel>` and
  /// `utm_campaign=<context>` appended.
  final String deepLink;

  /// Always `true` in v1 (handler renders synchronously). Reserved for a
  /// future skeleton-then-poll path when expensive channels (AI posters)
  /// land.
  final bool ready;

  // TODO(PROD-2785): identity-field casts retained pending Phase 3
  // `requireString` helper (see docs/platform/error-handling-discipline.md).
  // Drop the `gstack:allow` markers once the helper lands.
  factory ShareChannelAssetOut.fromJson(Map<String, dynamic> json) {
    return ShareChannelAssetOut(
      channel:
          json['channel']
              as String, // gstack:allow check-error-handling json-cast-string
      context:
          json['context']
              as String, // gstack:allow check-error-handling json-cast-string
      id:
          json['id']
              as String, // gstack:allow check-error-handling json-cast-string
      asset: InstagramStoryAsset.fromJson(
        json['asset'] as Map<String, dynamic>,
      ),
      attributionUrl:
          json['attribution_url']
              as String, // gstack:allow check-error-handling json-cast-string
      deepLink:
          json['deep_link']
              as String, // gstack:allow check-error-handling json-cast-string
      ready: json['ready'] as bool? ?? true,
    );
  }
}

/// IG-Story channel payload — card-only transparent PNG returned inline
/// as base64. The two `backgroundColor` hints are currently both Soko/Ink
/// (`#3B0F18`) so the IG-Story share extension paints a solid burgundy
/// frame behind the card sticker.
///
/// **v1.17.0 (PROD-2784 follow-up) contract change** — previously this
/// payload carried `image_url` (a GCS-proxy URL requiring a second HTTP
/// fetch) and the asset was a 1080×1920 working canvas. It now carries
/// `image_base64` + `image_format` inline, and `dimensions` reflects the
/// **card-only** rendered size (e.g. 600×750 for Event/Place) with a
/// transparent background outside the card.
class InstagramStoryAsset {
  const InstagramStoryAsset({
    required this.imageBase64,
    required this.imageFormat,
    required this.dimensions,
    required this.backgroundTopColor,
    required this.backgroundBottomColor,
  });

  /// Base64-encoded card-only PNG bytes (transparent background outside
  /// the card). Decode and write to a temp file before handing to
  /// `Image.file` / `InstagramStoryHandoff.shareToStory`.
  final String imageBase64;

  /// Image MIME subtype of [imageBase64] (currently always `png`).
  /// Drives the temp-file extension picked by `SharesApi`.
  final String imageFormat;

  final ShareDimensions dimensions;

  /// Hex color (e.g. `#3B0F18`) for the top of the IG-Story background
  /// gradient. Today equals [backgroundBottomColor] (sticker mode — top
  /// == bottom paints a solid burgundy frame).
  final String backgroundTopColor;

  /// Hex color for the bottom of the gradient. See [backgroundTopColor].
  final String backgroundBottomColor;

  // TODO(PROD-2785): identity-field casts retained pending Phase 3
  // `requireString` helper (see docs/platform/error-handling-discipline.md).
  // Drop the `gstack:allow` markers once the helper lands.
  factory InstagramStoryAsset.fromJson(Map<String, dynamic> json) {
    return InstagramStoryAsset(
      imageBase64:
          json['image_base64']
              as String, // gstack:allow check-error-handling json-cast-string
      imageFormat: (json['image_format'] as String?) ?? 'png',
      dimensions: ShareDimensions.fromJson(
        json['dimensions'] as Map<String, dynamic>,
      ),
      backgroundTopColor:
          json['background_top_color']
              as String, // gstack:allow check-error-handling json-cast-string
      backgroundBottomColor:
          json['background_bottom_color']
              as String, // gstack:allow check-error-handling json-cast-string
    );
  }
}

class ShareDimensions {
  const ShareDimensions({required this.width, required this.height});

  final int width;
  final int height;

  factory ShareDimensions.fromJson(Map<String, dynamic> json) {
    return ShareDimensions(
      width: json['width'] as int,
      height: json['height'] as int,
    );
  }
}
