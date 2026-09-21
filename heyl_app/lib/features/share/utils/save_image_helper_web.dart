// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

import 'save_image_helper.dart';

/// Web — creates a Blob-backed anchor and clicks it to trigger a browser
/// download. Mirrors the existing pattern in
/// `lib/features/memories/screens/memories_download_helper_web.dart`.
SaveImageHelper createSaveImageHelper() => _WebSaveImageHelper();

class _WebSaveImageHelper implements SaveImageHelper {
  @override
  Future<void> saveImageBytes(
    Uint8List bytes, {
    required String filename,
  }) async {
    final blob = html.Blob([bytes], 'image/png');
    final url = html.Url.createObjectUrlFromBlob(blob);
    try {
      final anchor = html.AnchorElement()
        ..href = url
        ..download = '$filename.png'
        ..style.display = 'none';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
    } finally {
      html.Url.revokeObjectUrl(url);
    }
  }
}
