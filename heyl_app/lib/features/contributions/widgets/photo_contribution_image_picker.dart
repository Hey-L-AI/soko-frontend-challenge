import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// Result of a successful pick — bytes + filename + mime, ready to hand to
/// `ContributionsApi.submitContribution`.
class PickedContributionImage {
  final Uint8List bytes;
  final String filename;
  final String contentType;
  final int sizeBytes;

  const PickedContributionImage({
    required this.bytes,
    required this.filename,
    required this.contentType,
    required this.sizeBytes,
  });
}

/// Why a pick failed. The widget layer maps each to an ARB key.
enum ContributionPickFailure {
  /// User dismissed the picker.
  dismissed,

  /// File > [ContributionImagePicker.maxBytes].
  tooLarge,

  /// MIME not in [ContributionImagePicker.allowedMimes].
  unsupportedType,

  /// Anything else (camera access denied, etc.) — bucket for the generic
  /// error path. The original exception is available in [error].
  unknown,
}

/// Picker outcome — either a [PickedContributionImage] or a failure reason.
class ContributionPickResult {
  final PickedContributionImage? image;
  final ContributionPickFailure? failure;
  final Object? error;

  const ContributionPickResult.success(this.image)
    : failure = null,
      error = null;

  const ContributionPickResult.failure(this.failure, [this.error])
    : image = null;

  bool get isSuccess => image != null;
}

/// Pick + validate a photo for submission to the contribution endpoint.
///
/// Mirrors the backend's contract:
///   - JPEG / PNG / WebP only (magic-byte sniff, same as `lists_api.dart`
///     `uploadListCover`).
///   - ≤ 10 MB.
///
/// Web: `XFile.readAsBytes()` already handles the blob path. Native: same
/// call reads the file directly. So this wrapper is platform-agnostic.
class ContributionImagePicker {
  static const int maxBytes = 10 * 1024 * 1024; // 10 MB
  static const Set<String> allowedMimes = {
    'image/jpeg',
    'image/png',
    'image/webp',
  };

  final ImagePicker _picker;

  ContributionImagePicker({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  Future<ContributionPickResult> pickFromCamera() => _pick(ImageSource.camera);

  Future<ContributionPickResult> pickFromGallery() =>
      _pick(ImageSource.gallery);

  Future<ContributionPickResult> _pick(ImageSource source) async {
    final XFile? file;
    try {
      file = await _picker.pickImage(source: source);
    } catch (e) {
      return ContributionPickResult.failure(ContributionPickFailure.unknown, e);
    }
    if (file == null) {
      return const ContributionPickResult.failure(
        ContributionPickFailure.dismissed,
      );
    }
    return processXFile(file);
  }

  /// Validate + load an `XFile` from any source (image_picker, drag-drop,
  /// share extension). Public so the chat / share-intent flows can reuse
  /// the same validation pipeline.
  Future<ContributionPickResult> processXFile(XFile file) async {
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      return ContributionPickResult.failure(ContributionPickFailure.unknown, e);
    }

    if (bytes.length > maxBytes) {
      return const ContributionPickResult.failure(
        ContributionPickFailure.tooLarge,
      );
    }

    final mime = _detectMime(bytes, fallback: file.mimeType);
    if (mime == null || !allowedMimes.contains(mime)) {
      return const ContributionPickResult.failure(
        ContributionPickFailure.unsupportedType,
      );
    }

    final extension = _extensionFor(mime);
    final originalName = file.name.isNotEmpty ? file.name : 'contribution';
    final filename = _withExtension(originalName, extension);

    return ContributionPickResult.success(
      PickedContributionImage(
        bytes: bytes,
        filename: filename,
        contentType: mime,
        sizeBytes: bytes.length,
      ),
    );
  }

  /// Magic-byte sniff — mirrors the `lists_api.dart:uploadListCover` pattern.
  /// Falls back to [fallback] (the platform-reported mime) when the bytes
  /// don't match any known signature.
  static String? _detectMime(Uint8List bytes, {String? fallback}) {
    if (bytes.length < 4) return fallback;

    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    // WebP: 52 49 46 46 ... 57 45 42 50 (RIFF....WEBP)
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return fallback;
  }

  static String _extensionFor(String mime) {
    switch (mime) {
      case 'image/jpeg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/webp':
        return 'webp';
      default:
        return 'jpg';
    }
  }

  static String _withExtension(String name, String extension) {
    final dot = name.lastIndexOf('.');
    final base = dot < 0 ? name : name.substring(0, dot);
    return '$base.$extension';
  }
}
