import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/datasources/api/detail_api.dart';
import '../data/models/social_proof.dart';
import 'api_provider.dart';

/// In-memory cache + fetcher for social proof data.
/// Cards call `getSocialProof(id, type)` which returns cached data
/// or fetches from the detail API.
class SocialProofNotifier extends StateNotifier<Map<String, SocialProof>> {
  final DetailApi _detailApi;
  final Set<String> _fetching = {};

  SocialProofNotifier(this._detailApi) : super({});

  /// Get cached social proof, or fetch it if not cached.
  /// Returns null while loading. Listeners will be notified when data arrives.
  SocialProof? getSocialProof(String id, String type) {
    if (state.containsKey(id)) return state[id];
    _fetchIfNeeded(id, type);
    return null;
  }

  /// Pre-populate cache (e.g., from search results that already include social proof)
  void cache(String id, SocialProof proof) {
    state = {...state, id: proof};
  }

  Future<void> _fetchIfNeeded(String id, String type) async {
    if (_fetching.contains(id)) return;
    _fetching.add(id);

    try {
      final SocialProof proof;
      if (type == 'place') {
        final detail = await _detailApi.getVenueDetail(id);
        proof = detail.socialProof;
      } else {
        final detail = await _detailApi.getEventDetail(id);
        proof = detail.socialProof;
      }
      state = {...state, id: proof};
    } catch (e) {
      debugPrint('Failed to fetch social proof for $id: $e');
    } finally {
      _fetching.remove(id);
    }
  }
}

final socialProofProvider =
    StateNotifierProvider<SocialProofNotifier, Map<String, SocialProof>>(
  (ref) => SocialProofNotifier(ref.watch(detailApiProvider)),
);
