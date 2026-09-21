import 'dart:typed_data' show Uint8List;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:heyl_app/data/models/share_asset.dart';
import 'package:heyl_app/features/share/providers/share_controller.dart'
    show ShareControllerKey;
import 'package:heyl_app/providers/api_provider.dart';

/// PROD-2785 — Prefetches the IG-Story `ShareAsset` for a given
/// `(shareContext, entityId)` so the preview tile in [SokoShareSheet] can
/// render the same backend-rendered PNG that the IG handoff will use, AND
/// the IG-Story tap is near-instant (the asset is already on disk).
///
/// Now that the backend renders synchronously in ~1 s (cached after that),
/// it's cheap enough to fire on every sheet open. The first user pays the
/// Playwright render; everyone else hits the GCS cache.
///
/// AutoDispose so the temp-file [ShareAsset] is released when the sheet
/// closes. Family keying mirrors [ShareControllerKey] so a single Riverpod
/// scope serves both the preview tile and the controller — no duplicate
/// fetch / download.
final instagramStoryAssetProvider = FutureProvider.autoDispose
    .family<ShareAsset, ShareControllerKey>((ref, key) async {
      final api = ref.watch(sharesApiProvider);
      return api.getInstagramStoryAsset(
        shareContext: key.shareContext,
        entityId: key.entityId,
      );
    });

/// Bytes-only IG-story card for in-app display (`Image.memory`). Unlike
/// [instagramStoryAssetProvider] it writes no temp file, so it works on web
/// too. Used to render the persona card (the `.ps-stack` PNG — transparent,
/// no share footer) inside the Memory / profile surfaces.
final igStoryBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, ShareControllerKey>((ref, key) async {
      final api = ref.watch(sharesApiProvider);
      return api.getInstagramStoryBytes(
        shareContext: key.shareContext,
        entityId: key.entityId,
      );
    });
