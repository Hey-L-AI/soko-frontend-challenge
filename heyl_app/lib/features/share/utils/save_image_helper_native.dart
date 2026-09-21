import 'dart:typed_data';

import 'package:gal/gal.dart';

import 'save_image_helper.dart';

/// Native (iOS + Android) — writes PNG bytes to the photo library via
/// [Gal]. `gal` handles the permission dance internally and throws
/// `GalException` on denial / IO failure; callers should catch and
/// surface a Soko error toast.
SaveImageHelper createSaveImageHelper() => _NativeSaveImageHelper();

class _NativeSaveImageHelper implements SaveImageHelper {
  @override
  Future<void> saveImageBytes(
    Uint8List bytes, {
    required String filename,
  }) async {
    // `Gal.putImageBytes` on iOS drops the row under Photos → Recents;
    // on Android it lands under `Pictures/{name}`. Album omitted so
    // Photos categorises it in the default camera roll. `name`
    // becomes the file basename minus extension; `gal` appends the
    // right one from the byte header.
    await Gal.putImageBytes(bytes, name: filename);
  }
}
