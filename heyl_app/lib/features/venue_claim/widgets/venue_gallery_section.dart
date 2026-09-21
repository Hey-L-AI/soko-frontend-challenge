import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/owner_gallery.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/cached_image.dart';
import '../../contributions/widgets/photo_contribution_image_picker.dart';
import '../providers/owner_gallery_provider.dart';

/// Owner gallery editor (PROD-4040 T2.3): a strip of the venue's gallery images
/// with add (multi-pick, validated), delete, and drag-to-reorder — alongside
/// the single cover photo. Reads/writes via [ownerGalleryControllerProvider].
class VenueGallerySection extends ConsumerWidget {
  const VenueGallerySection({super.key, required this.venueId});

  final String venueId;

  static const double _tileSize = 88;

  Future<void> _addPhotos(BuildContext context, WidgetRef ref) async {
    final l10n = Lt.of(context);
    final controller = ref.read(
      ownerGalleryControllerProvider(venueId).notifier,
    );
    final picker = ContributionImagePicker();

    List<XFile> files;
    try {
      files = await ImagePicker().pickMultiImage();
    } catch (_) {
      files = const [];
    }
    if (files.isEmpty) return;

    // Validate each pick through the shared pipeline (JPEG/PNG/WebP, ≤10MB).
    final uploads = <GalleryUpload>[];
    for (final file in files) {
      final result = await picker.processXFile(file);
      final image = result.image;
      if (image != null) {
        uploads.add(
          GalleryUpload(
            bytes: image.bytes,
            filename: image.filename,
            contentType: image.contentType,
          ),
        );
      }
    }
    if (uploads.isEmpty) {
      if (context.mounted) {
        showSoko(
          ref,
          message: l10n.businessOwnershipGalleryUploadFailed,
          variant: SokoVariant.error,
        );
      }
      return;
    }

    final ok = await controller.upload(uploads);
    if (!ok && context.mounted) {
      showSoko(
        ref,
        message: l10n.businessOwnershipGalleryUploadFailed,
        variant: SokoVariant.error,
      );
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, String id) async {
    final ok = await ref
        .read(ownerGalleryControllerProvider(venueId).notifier)
        .delete(id);
    if (!ok && context.mounted) {
      showSoko(
        ref,
        message: Lt.of(context).businessOwnershipGalleryDeleteFailed,
        variant: SokoVariant.error,
      );
    }
  }

  Future<void> _reorder(
    BuildContext context,
    WidgetRef ref,
    int oldIndex,
    int newIndex,
  ) async {
    final ok = await ref
        .read(ownerGalleryControllerProvider(venueId).notifier)
        .reorder(oldIndex, newIndex);
    if (!ok && context.mounted) {
      showSoko(
        ref,
        message: Lt.of(context).businessOwnershipGalleryReorderFailed,
        variant: SokoVariant.error,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final state = ref.watch(ownerGalleryControllerProvider(venueId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l10n.businessOwnershipGalleryLabel,
              style: const TextStyle(fontSize: 13, color: AppColors.sokoShade3),
            ),
            const SizedBox(width: 8),
            if (state.isMutating)
              const SizedBox(
                height: 14,
                width: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.sokoPink,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (state.isLoading)
          const SizedBox(
            height: _tileSize,
            child: Center(
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.sokoPink,
                ),
              ),
            ),
          )
        else if (state.hasError)
          _GalleryMessage(
            text: l10n.businessOwnershipGalleryLoadFailed,
            onRetry: () => ref
                .read(ownerGalleryControllerProvider(venueId).notifier)
                .load(),
            retryLabel: MaterialLocalizations.of(
              context,
            ).refreshIndicatorSemanticLabel,
          )
        else if (state.isEmpty)
          _AddTile(
            expanded: true,
            label: l10n.businessOwnershipGalleryAdd,
            onTap: state.isMutating ? null : () => _addPhotos(context, ref),
          )
        else
          SizedBox(
            height: _tileSize,
            child: Row(
              children: [
                Expanded(
                  child: ReorderableListView.builder(
                    scrollDirection: Axis.horizontal,
                    buildDefaultDragHandles: false,
                    onReorder: (o, n) => _reorder(context, ref, o, n),
                    itemCount: state.images.length,
                    itemBuilder: (ctx, i) {
                      final image = state.images[i];
                      return Padding(
                        key: ValueKey(image.id),
                        padding: const EdgeInsets.only(right: 8),
                        child: ReorderableDelayedDragStartListener(
                          index: i,
                          child: _Thumb(
                            url: image.url,
                            size: _tileSize,
                            enabled: !state.isMutating,
                            deleteLabel: l10n.businessOwnershipGalleryDelete,
                            onDelete: () => _delete(context, ref, image.id),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                _AddTile(
                  label: l10n.businessOwnershipGalleryAdd,
                  onTap: state.isMutating
                      ? null
                      : () => _addPhotos(context, ref),
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Text(
          l10n.businessOwnershipGalleryHint,
          style: const TextStyle(fontSize: 12, color: AppColors.sokoShade3),
        ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.url,
    required this.size,
    required this.enabled,
    required this.onDelete,
    required this.deleteLabel,
  });

  final String url;
  final double size;
  final bool enabled;
  final VoidCallback onDelete;
  final String deleteLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CachedImage(
            imageUrl: url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            borderRadius: BorderRadius.circular(10),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: Semantics(
              button: true,
              label: deleteLabel,
              child: GestureDetector(
                onTap: enabled ? onDelete : null,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                    color: AppColors.sokoInk,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    LucideIcons.x,
                    size: 13,
                    color: AppColors.sokoPaper,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({
    required this.label,
    required this.onTap,
    this.expanded = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final tile = GestureDetector(
      onTap: onTap,
      child: Container(
        height: 88,
        width: expanded ? double.infinity : 88,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.sokoInk8, width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              LucideIcons.image_plus,
              size: 20,
              color: onTap == null
                  ? AppColors.sokoShade4
                  : AppColors.sokoShade3,
            ),
            if (expanded) ...[
              const SizedBox(height: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.sokoShade3,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return expanded ? tile : SizedBox(width: 88, child: tile);
  }
}

class _GalleryMessage extends StatelessWidget {
  const _GalleryMessage({
    required this.text,
    required this.onRetry,
    required this.retryLabel,
  });

  final String text;
  final VoidCallback onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, color: AppColors.sokoShade3),
          ),
        ),
        TextButton(
          onPressed: onRetry,
          style: TextButton.styleFrom(foregroundColor: AppColors.sokoInk),
          child: Text(retryLabel),
        ),
      ],
    );
  }
}
