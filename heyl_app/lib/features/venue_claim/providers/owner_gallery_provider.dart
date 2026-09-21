import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/datasources/interfaces/venue_claim_api.dart';
import '../../../data/models/owner_gallery.dart';
import '../../../providers/api_provider.dart';

/// Owner venue gallery (PROD-4040 T2.3). Owns the image list for one venue and
/// runs the upload / delete / reorder mutations, each of which the backend
/// answers with the full re-ordered [OwnerGalleryResponse] — so state is always
/// re-seeded from that single source of truth after a successful mutation.
///
/// Delete and reorder update the list optimistically for a snappy UI, then
/// reconcile with the server response (or reload on failure).
@immutable
class OwnerGalleryState {
  const OwnerGalleryState({
    this.images = const [],
    this.isLoading = true,
    this.isMutating = false,
    this.hasError = false,
  });

  /// Ordered gallery images (backend returns them in `sort_order`).
  final List<OwnerGalleryImage> images;

  /// The initial load is in flight.
  final bool isLoading;

  /// An upload / delete / reorder is in flight.
  final bool isMutating;

  /// The initial load failed.
  final bool hasError;

  bool get isEmpty => images.isEmpty;

  OwnerGalleryState copyWith({
    List<OwnerGalleryImage>? images,
    bool? isLoading,
    bool? isMutating,
    bool? hasError,
  }) {
    return OwnerGalleryState(
      images: images ?? this.images,
      isLoading: isLoading ?? this.isLoading,
      isMutating: isMutating ?? this.isMutating,
      hasError: hasError ?? this.hasError,
    );
  }
}

class OwnerGalleryController extends StateNotifier<OwnerGalleryState> {
  OwnerGalleryController(this._api, this.venueId)
    : super(const OwnerGalleryState()) {
    load();
  }

  final IVenueClaimApi _api;
  final String venueId;

  Future<void> load() async {
    state = state.copyWith(isLoading: true, hasError: false);
    try {
      final response = await _api.getOwnerVenueGallery(venueId);
      if (!mounted) return;
      state = OwnerGalleryState(images: response.images, isLoading: false);
    } catch (e) {
      debugPrint('[OwnerGallery] load failed: $e');
      if (!mounted) return;
      state = state.copyWith(isLoading: false, hasError: true);
    }
  }

  /// Uploads new images. Returns `true` on success.
  Future<bool> upload(List<GalleryUpload> files) async {
    if (files.isEmpty || state.isMutating) return false;
    state = state.copyWith(isMutating: true);
    try {
      final response = await _api.uploadOwnerVenueGalleryImages(venueId, files);
      if (!mounted) return true;
      state = state.copyWith(images: response.images, isMutating: false);
      return true;
    } catch (e) {
      debugPrint('[OwnerGallery] upload failed: $e');
      if (!mounted) return false;
      state = state.copyWith(isMutating: false);
      return false;
    }
  }

  /// Deletes one image (optimistically), reconciling with the server list.
  Future<bool> delete(String imageId) async {
    if (state.isMutating) return false;
    final previous = state.images;
    state = state.copyWith(
      images: previous.where((i) => i.id != imageId).toList(),
      isMutating: true,
    );
    try {
      final response = await _api.deleteOwnerVenueGalleryImage(
        venueId,
        imageId,
      );
      if (!mounted) return true;
      state = state.copyWith(images: response.images, isMutating: false);
      return true;
    } catch (e) {
      debugPrint('[OwnerGallery] delete failed: $e');
      if (!mounted) return false;
      state = state.copyWith(images: previous, isMutating: false);
      return false;
    }
  }

  /// Reorders the image at [oldIndex] to [newIndex] (optimistically).
  Future<bool> reorder(int oldIndex, int newIndex) async {
    if (state.isMutating) return false;
    final previous = state.images;
    if (oldIndex < 0 || oldIndex >= previous.length) return false;
    // ReorderableListView's newIndex is the slot *before* removal; adjust.
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= previous.length) target = previous.length - 1;
    if (target == oldIndex) return false;

    final reordered = List<OwnerGalleryImage>.of(previous);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(target, moved);
    state = state.copyWith(images: reordered, isMutating: true);

    try {
      final response = await _api.reorderOwnerVenueGallery(
        venueId,
        reordered.map((i) => i.id).toList(),
      );
      if (!mounted) return true;
      state = state.copyWith(images: response.images, isMutating: false);
      return true;
    } catch (e) {
      debugPrint('[OwnerGallery] reorder failed: $e');
      if (!mounted) return false;
      state = state.copyWith(images: previous, isMutating: false);
      return false;
    }
  }
}

/// Per-venue gallery controller. Auto-disposes when the edit sheet closes.
final ownerGalleryControllerProvider = StateNotifierProvider.autoDispose
    .family<OwnerGalleryController, OwnerGalleryState, String>((ref, venueId) {
      return OwnerGalleryController(ref.watch(venueClaimApiProvider), venueId);
    });
