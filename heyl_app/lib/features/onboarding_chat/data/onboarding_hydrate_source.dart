import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/api_constants.dart';
import '../../../data/datasources/api/api_client.dart';
import '../../../data/datasources/api/interceptors/retry_interceptor.dart';
import '../../../data/models/entity_signal.dart';
import '../../../data/models/vibe_candidate.dart';
import '../../../providers/api_provider.dart';

/// A reference to one onboarding entity to re-hydrate on resume: its [type]
/// (`place` | `event`, matching the backend contract) and its UUID [id].
class OnboardingEntityRef {
  const OnboardingEntityRef({required this.type, required this.id});

  final String type;
  final String id;

  Map<String, dynamic> toJson() => {'type': type, 'id': id};
}

/// One hydrated onboarding card: the rebuilt [candidate] plus the caller's own
/// persisted thumb ([sentiment]), so both the card AND its 👍/👎 can be
/// re-painted exactly as they were left on resume.
class OnboardingHydratedEntity {
  const OnboardingHydratedEntity({
    required this.candidate,
    required this.sentiment,
  });

  final VibeCandidate candidate;
  final SignalTaste sentiment;
}

/// Bulk-hydrates previously-shown onboarding entities (vibe carousel cards +
/// search picks) so a returning user resumes the SAME state. Kept as an
/// interface for test fakes, mirroring [IOnboardingVibeApi]/[IOnboardingZinesApi].
abstract interface class IOnboardingHydrateApi {
  /// Returns cards in request order; missing/inactive entities are dropped.
  Future<List<OnboardingHydratedEntity>> hydrate(
    List<OnboardingEntityRef> refs,
  );
}

/// Production [IOnboardingHydrateApi] backed by
/// `POST /api/v1/app/onboarding/entities/hydrate`.
class OnboardingHydrateApi implements IOnboardingHydrateApi {
  OnboardingHydrateApi({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  @override
  Future<List<OnboardingHydratedEntity>> hydrate(
    List<OnboardingEntityRef> refs,
  ) async {
    if (refs.isEmpty) return const [];

    final response = await _apiClient.dio.post(
      ApiConstants.onboardingEntitiesHydrate,
      data: {
        'items': [for (final r in refs) r.toJson()],
      },
      // Bulk entity re-hydrate is a read — safe to replay — and can be slow, so
      // it gets the longer content timeout and opts into retry.
      options: Options(
        receiveTimeout: ApiConstants.onboardingContentTimeout,
        extra: const {RetryInterceptor.idempotentRetryKey: true},
      ),
    );

    final items = ((response.data as Map<String, dynamic>)['items'] as List?)
        ?.whereType<Map<String, dynamic>>();
    if (items == null) return const [];

    return [
      for (final json in items)
        OnboardingHydratedEntity(
          candidate: VibeCandidate.fromHydratedEntity(json),
          sentiment: SignalTaste.fromWire(json['sentiment'] as String?),
        ),
    ].where((h) => h.candidate.entityId.isNotEmpty).toList(growable: false);
  }
}

/// Live provider — the Dio client resolves lazily, so nothing touches the
/// network until a resume path first reads it.
final onboardingHydrateApiProvider = Provider<IOnboardingHydrateApi>(
  (ref) => OnboardingHydrateApi(apiClient: ref.read(apiClientProvider)),
);
