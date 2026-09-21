import '../../models/feature_spotlight.dart';
import '../interfaces/feature_spotlights_api.dart';

/// In-memory mock of [IFeatureSpotlightsApi] for offline/test runs.
class MockFeatureSpotlightsApi implements IFeatureSpotlightsApi {
  final Set<String> _seen = {};

  @override
  Future<FeatureSpotlightsState> fetchState() async =>
      FeatureSpotlightsState(seen: Set.unmodifiable(_seen), disabled: const {});

  @override
  Future<void> markSeen(
    String featureId, {
    FeatureSpotlightSeenReason? reason,
  }) async {
    _seen.add(featureId);
  }
}
