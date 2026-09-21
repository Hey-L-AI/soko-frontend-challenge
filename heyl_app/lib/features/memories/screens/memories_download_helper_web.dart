// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

import 'memories_download_helper.dart';

/// Creates the web-specific download helper
MemoriesDownloadHelper createDownloadHelper() => _WebDownloadHelper();

/// Web implementation using browser download
class _WebDownloadHelper implements MemoriesDownloadHelper {
  @override
  Future<bool> downloadMemory(List<int> bytes, String filename) async {
    try {
      final blob = html.Blob([Uint8List.fromList(bytes)], 'text/markdown');
      final url = html.Url.createObjectUrlFromBlob(blob);

      final anchor = html.AnchorElement()
        ..href = url
        ..download = filename
        ..style.display = 'none';

      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();

      html.Url.revokeObjectUrl(url);
      return true;
    } catch (e) {
      return false;
    }
  }
}
