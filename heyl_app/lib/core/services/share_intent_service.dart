import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../utils/instagram_url.dart';

/// Service that listens for incoming shared text from other apps (e.g.,
/// Instagram → Soko via the OS share sheet).
///
/// On web, this is a no-op since share intents are not applicable.
class ShareIntentService {
  StreamSubscription<List<SharedMediaFile>>? _subscription;

  /// Callback invoked when an Instagram URL is received from a share intent.
  void Function(String url, InstagramUrlType type)? onInstagramUrl;

  /// Start listening for incoming share intents.
  void init() {
    if (kIsWeb) return;

    // Handle intents that arrive while the app is running.
    _subscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_handleSharedMedia);

    // Handle the initial intent (app launched via share).
    ReceiveSharingIntent.instance
        .getInitialMedia()
        .then(_handleSharedMedia);
  }

  void _handleSharedMedia(List<SharedMediaFile> files) {
    for (final file in files) {
      // SharedMediaFile.path contains the shared text for text/plain intents.
      final text = file.path;
      if (text.isEmpty) continue;

      final parsed = InstagramUrl.extract(text);
      if (parsed != null) {
        onInstagramUrl?.call(parsed.url, parsed.type);
        // Reset the intent so it's not re-processed.
        ReceiveSharingIntent.instance.reset();
        return;
      }
    }
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}

/// Provider for the share intent service.
final shareIntentServiceProvider = Provider<ShareIntentService>((ref) {
  final service = ShareIntentService();
  ref.onDispose(() => service.dispose());
  return service;
});
