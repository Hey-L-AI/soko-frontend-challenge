/// Owner gallery DTOs (PROD-4039 / PROD-4040).
///
/// The venue owner curates a multi-image gallery (distinct from the single
/// cover photo). All gallery mutations — list, upload, delete, reorder —
/// return the full, re-ordered [OwnerGalleryResponse] so the edit UI can
/// re-render from a single source of truth. Owner- and flag-gated server-side.
library;

/// A single image to upload to the owner gallery. Bytes work on web + native
/// (image_picker `readAsBytes`), mirroring the cover-photo upload signature.
class GalleryUpload {
  const GalleryUpload({
    required this.bytes,
    required this.filename,
    this.contentType,
  });

  final List<int> bytes;
  final String filename;

  /// MIME type (e.g. `image/jpeg`) from the picker, so the multipart part
  /// carries the right content-type. Null lets Dio/the backend infer it.
  final String? contentType;
}

class OwnerGalleryImage {
  const OwnerGalleryImage({
    required this.id,
    required this.url,
    required this.sortOrder,
    this.createdAt,
  });

  final String id;

  /// Client-ready proxied image URL.
  final String url;
  final int sortOrder;
  final DateTime? createdAt;

  factory OwnerGalleryImage.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final url = json['url'];
    final sortOrder = json['sort_order'];
    final createdAt = json['created_at'];
    return OwnerGalleryImage(
      id: id is String ? id : '',
      url: url is String ? url : '',
      sortOrder: sortOrder is int ? sortOrder : 0,
      createdAt: createdAt is String ? DateTime.tryParse(createdAt) : null,
    );
  }
}

class OwnerGalleryResponse {
  const OwnerGalleryResponse({required this.venueId, required this.images});

  final String venueId;
  final List<OwnerGalleryImage> images;

  factory OwnerGalleryResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['images'];
    final images = raw is List
        ? raw
              .whereType<Map<String, dynamic>>()
              .map(OwnerGalleryImage.fromJson)
              .toList()
        : <OwnerGalleryImage>[];
    final venueId = json['venue_id'];
    return OwnerGalleryResponse(
      venueId: venueId is String ? venueId : '',
      images: images,
    );
  }
}
