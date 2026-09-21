import 'memories_download_helper_stub.dart'
    if (dart.library.html) 'memories_download_helper_web.dart'
    if (dart.library.io) 'memories_download_helper_mobile.dart';

/// Platform-agnostic interface for downloading memory files
abstract class MemoriesDownloadHelper {
  /// Downloads the memory markdown file
  /// Returns true if successful, false otherwise
  Future<bool> downloadMemory(List<int> bytes, String filename);

  /// Factory constructor that returns the platform-specific implementation
  factory MemoriesDownloadHelper() => createDownloadHelper();
}
