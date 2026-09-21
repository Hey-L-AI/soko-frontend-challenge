import 'dart:io';
import 'dart:typed_data';

/// PROD-2785 — channel-ready share payload returned by [SharesApi]. Wraps
/// what we need for the Instagram Stories handoff:
///
///   * [imageFile] — a temp-dir PNG ready to hand to
///     `InstagramStoryHandoff.shareToStory(...)` (the canonical
///     backend-rendered card, downloaded from `InstagramStoryAsset.imageUrl`).
///     **Null on web** — `getTemporaryDirectory()` (path_provider) is
///     native-only and there's no `path_provider_web` resolved, so the web
///     build skips the temp write (PROD-3805). Web consumes [imageBytes]
///     instead; the file-only path (direct IG-Story handoff) is native-only.
///   * [imageBytes] — the same PNG's decoded bytes, kept in memory so
///     the Save-image channel can write it to the gallery on native and
///     stream it into a browser download on web without re-reading the
///     temp file. Cheap to keep — the API decode already produced these.
///   * [attributionUrl] — the deep link IG attaches as the "Open on Soko"
///     link sticker; also used as the body of the WhatsApp / Copy link /
///     system-share channels so every channel resolves to the same surface.
///   * [backgroundTopColor] / [backgroundBottomColor] — hex hints from the
///     backend so the IG-Story sticker layer sits on a gradient that
///     matches the card chrome (e.g. card with burgundy bottom → burgundy
///     bottom gradient). Null when not supplied; the handoff falls back
///     to white.
class ShareAsset {
  const ShareAsset({
    required this.imageFile,
    required this.imageBytes,
    required this.attributionUrl,
    this.backgroundTopColor,
    this.backgroundBottomColor,
  });

  final File? imageFile;
  final Uint8List imageBytes;
  final String attributionUrl;
  final String? backgroundTopColor;
  final String? backgroundBottomColor;
}
