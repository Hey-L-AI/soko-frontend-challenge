import 'save_image_helper.dart';

/// Stub — never reachable at runtime; the conditional import in
/// `save_image_helper.dart` picks either the native or web variant.
SaveImageHelper createSaveImageHelper() {
  throw UnsupportedError(
    'Cannot create SaveImageHelper without dart:html or dart:io',
  );
}
