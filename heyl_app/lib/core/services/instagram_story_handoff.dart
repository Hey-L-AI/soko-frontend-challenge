import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show PlatformException;
import 'package:social_share/social_share.dart';

/// Hands off a pre-rendered PNG to the Instagram Stories composer as a
/// **centered sticker** layered over a top→bottom gradient. IG attaches an
/// "Open on Soko" link sticker automatically when `attributionURL` is
/// present.
///
/// PROD-2785 / PROD-2788. See:
///   docs/investigations/context/prod-2785-share-to-instagram-story-frontend.md
///
/// ## Why sticker-mode (not full-bleed)
///
/// The `social_share` package supports both — pass the asset as
/// `imagePath` for sticker-mode, or as `backgroundResourcePath` for
/// full-bleed. We tried full-bleed first; IG silently drops
/// `com.instagram.sharedSticker.backgroundImage` for Soko (we're not a
/// Meta-verified IG-sharing partner) and falls back to "sticker over
/// gradient". The user actually prefers the centered look, and the
/// backend (PROD-2784) returns gradient color hints (`background_top_color`,
/// `background_bottom_color`) specifically so the FE sticker layer can sit
/// on a gradient that matches the card chrome. So we stop fighting IG and
/// embrace the sticker-mode contract:
///
///   - `imagePath`             → `com.instagram.sharedSticker.stickerImage`
///   - `backgroundResourcePath`→ (omitted)
///   - `backgroundTopColor`    → `com.instagram.sharedSticker.backgroundTopColor`
///   - `backgroundBottomColor` → `com.instagram.sharedSticker.backgroundBottomColor`
///   - `attributionURL`        → `com.instagram.sharedSticker.contentURL`
///
/// This is a deliberately thin wrapper around `social_share` so a future
/// pivot to a custom MethodChannel (if the package's sticker / attribution
/// fidelity proves insufficient on device) is a single-file swap behind
/// the same Dart API.
class InstagramStoryHandoff {
  const InstagramStoryHandoff({String? appId}) : _injectedAppId = appId;

  final String? _injectedAppId;

  /// Compile-time default. Wire via
  /// `--dart-define=FB_APP_ID=...` to match `$(FACEBOOK_APP_ID)` baked into
  /// `heyl_app/ios/Flutter/{Debug,Release}.xcconfig` and the `resValue` in
  /// `heyl_app/android/app/build.gradle.kts`.
  ///
  /// Falls back to the **staging** Meta app id (Debug.xcconfig) so devs
  /// running `flutter run` on iOS without dart-defines can still test the
  /// IG Stories handoff. Override for prod with
  /// `--dart-define=FB_APP_ID=2210824612782021`.
  static const String _envAppId = String.fromEnvironment(
    'FB_APP_ID',
    defaultValue: '1233583358948693',
  );

  /// Hands [contentImage] to Instagram Stories as a centered sticker
  /// layered over a top→bottom gradient. IG attaches an "Open on Soko"
  /// link sticker pointing at [attributionUrl].
  ///
  /// [backgroundTopColor] / [backgroundBottomColor] (CSS hex `#RRGGBB`)
  /// drive the gradient behind the sticker. The backend supplies these
  /// per-card so the gradient matches the card's chrome; pass `null` to
  /// fall back to plain white.
  ///
  /// Returns:
  ///   * `true`  — IG was opened and the asset was dispatched (best-effort:
  ///                the OS gives no callback after handoff).
  ///   * `false` — Instagram is not installed, the platform is web/desktop,
  ///                or the IG `canOpenURL` probe failed.
  ///
  /// Rethrows unexpected [PlatformException]s.
  Future<bool> shareToStory({
    required File contentImage,
    required String attributionUrl,
    String? backgroundTopColor,
    String? backgroundBottomColor,
  }) async {
    if (!_isSupportedPlatform) return false;

    final appId = _resolveAppId();

    try {
      final result = await SocialShare.shareInstagramStory(
        appId: appId,
        // Sticker-mode: the rendered card goes here (→ stickerImage).
        // No backgroundResourcePath — let the gradient hints do the work.
        imagePath: contentImage.path,
        backgroundTopColor: backgroundTopColor ?? '#FFFFFF',
        backgroundBottomColor: backgroundBottomColor ?? '#FFFFFF',
        attributionURL: attributionUrl,
      );
      return result != null;
    } on PlatformException catch (e) {
      final msg = (e.message ?? '').toLowerCase();
      if (e.code == 'FailedToOpen' ||
          msg.contains('not installed') ||
          msg.contains('failed to open')) {
        return false;
      }
      rethrow;
    }
  }

  String _resolveAppId() {
    final id = _injectedAppId ?? _envAppId;
    if (id.isEmpty) {
      throw StateError(
        'InstagramStoryHandoff: FB_APP_ID is not configured. Pass via '
        '--dart-define=FB_APP_ID=<id> or construct '
        'InstagramStoryHandoff(appId: ...). Must match \$(FACEBOOK_APP_ID) '
        'in heyl_app/ios/Flutter/*.xcconfig and the resValue in '
        'heyl_app/android/app/build.gradle.kts.',
      );
    }
    return id;
  }

  bool get _isSupportedPlatform =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
}
