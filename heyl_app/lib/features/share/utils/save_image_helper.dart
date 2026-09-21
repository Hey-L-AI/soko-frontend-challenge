import 'dart:typed_data';

import 'save_image_helper_stub.dart'
    if (dart.library.html) 'save_image_helper_web.dart'
    if (dart.library.io) 'save_image_helper_native.dart';

/// Platform-agnostic interface for saving a rendered share PNG to the
/// user's device. Native builds write to the photo library / gallery via
/// `gal`; web streams a browser download via `dart:html`.
abstract class SaveImageHelper {
  /// Writes [bytes] to the platform-appropriate destination under
  /// [filename]. Throws on failure (permission denied, quota, etc.) so
  /// the caller can surface an error toast.
  Future<void> saveImageBytes(Uint8List bytes, {required String filename});

  factory SaveImageHelper() => createSaveImageHelper();
}
