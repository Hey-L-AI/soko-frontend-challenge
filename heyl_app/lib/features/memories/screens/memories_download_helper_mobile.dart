import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'memories_download_helper.dart';

/// Creates the mobile-specific download helper
MemoriesDownloadHelper createDownloadHelper() => _MobileDownloadHelper();

/// Mobile implementation using share sheet
class _MobileDownloadHelper implements MemoriesDownloadHelper {
  @override
  Future<bool> downloadMemory(List<int> bytes, String filename) async {
    try {
      // Get temp directory to store the file
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$filename');

      // Write bytes to file
      await file.writeAsBytes(Uint8List.fromList(bytes));

      // Share the file using native share sheet
      final result = await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'My Memory Profile',
      );

      // Clean up temp file after sharing
      if (await file.exists()) {
        await file.delete();
      }

      return result.status == ShareResultStatus.success ||
          result.status == ShareResultStatus.dismissed;
    } catch (e) {
      return false;
    }
  }
}
