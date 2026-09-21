import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/api_constants.dart';
import '../../../data/datasources/api/api_client.dart';
import '../../../data/datasources/api/interceptors/retry_interceptor.dart';
import '../../../data/models/vibe_candidate.dart';
import '../../../providers/api_provider.dart';
import '../../discovery/providers/near_you_context_provider.dart';

/// Reads one shelf of the vibe step (venues *or* events). Each carousel calls
/// this on its own with its [VibeCandidateType], so *Sítios* and *Eventos* are
/// two independent discovery requests. Kept as an interface for test fakes.
abstract interface class IOnboardingVibeApi {
  Future<List<VibeCandidate>> fetch({
    required VibeCandidateType type,
    int limit,
  });
}

/// Production [IOnboardingVibeApi] backed by the unified discovery endpoint
/// (`POST /api/v1/app/discovery`). One call per shelf: `entity_types: venues`
/// for *Sítios*, `entity_types: events` for *Eventos*. Location comes from
/// [nearYouContextProvider] (the picker city / GPS coordinate).
class DiscoveryVibeApi implements IOnboardingVibeApi {
  DiscoveryVibeApi({required ApiClient apiClient, required this.resolveContext})
    : _apiClient = apiClient;

  final ApiClient _apiClient;
  final Future<NearYouContext?> Function() resolveContext;

  @override
  Future<List<VibeCandidate>> fetch({
    required VibeCandidateType type,
    int limit = 12,
  }) async {
    final ctx = await resolveContext();
    if (ctx == null) return const [];

    final response = await _apiClient.dio.post(
      ApiConstants.discovery,
      data: {
        'latitude': ctx.latitude,
        'longitude': ctx.longitude,
        'entity_types': type == VibeCandidateType.event ? 'events' : 'venues',
        'num_results': limit,
        // Cold-start onboarding: `newcomer` is `for_you` + a strong social-proof
        // boost (entities saved by many users), so first-timers see broadly-loved
        // places/events rather than a personalization-thin result. Requires the
        // backend `newcomer` objective (spec 1.94.0) — ships backend-first.
        'objective': 'newcomer',
      },
      // Discovery is a read-only ranking (LLM/multi-query pipeline) — safe to
      // replay and legitimately slow on a cold container, so give it the longer
      // content timeout and let RetryInterceptor recover a transient failure.
      options: Options(
        receiveTimeout: ApiConstants.onboardingContentTimeout,
        extra: const {RetryInterceptor.idempotentRetryKey: true},
      ),
    );

    return ((response.data as Map<String, dynamic>)['items'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(VibeCandidate.fromDiscoveryItem)
            .where((c) => c.entityId.isNotEmpty && (c.type == type))
            .toList(growable: false) ??
        const <VibeCandidate>[];
  }
}

/// Live provider — dependencies resolve lazily inside the body, so nothing
/// touches the network until a carousel first reads it.
final onboardingVibeApiProvider = Provider<IOnboardingVibeApi>(
  (ref) => DiscoveryVibeApi(
    apiClient: ref.read(apiClientProvider),
    resolveContext: () => ref.read(nearYouContextProvider.future),
  ),
);
