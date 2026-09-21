import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/exceptions/api_exceptions.dart';
import '../../../data/datasources/api/api_client.dart';
import '../../../data/datasources/interfaces/api_interfaces.dart';
import '../../../data/models/user_list.dart';
import '../../../providers/api_provider.dart';
import '../../discovery/providers/near_you_context_provider.dart';
import 'onboarding_zine.dart';

/// Reads + saves the onboarding "zines" step's generated zine (PROD-3883).
/// Kept as an interface for test fakes, mirroring [IOnboardingVibeApi].
abstract interface class IOnboardingZinesApi {
  /// Generate (or regenerate in place) the hidden preliminary zines for the
  /// user's onboarding city — one themed zine per picked interest. NOT
  /// auto-saved. Throws [ZinesNotReadyException] (409) when the user's
  /// interests are not persisted yet, so the caller can retry.
  Future<List<OnboardingPreliminaryZine>> fetch();

  /// Copy the preliminary zine [listId] into a new owned list. Returns the
  /// reference the caller must pass back to [unsave] to reverse it — the NEW
  /// owned list's id for the copy batch, or the followed list's id for the
  /// most-followed batch.
  Future<String> save(String listId, {String? name});

  /// Reverse a [save]. [listId] is the preliminary zine id (as keyed in state);
  /// [savedListId] is the reference [save] returned. The copy batch deletes the
  /// owned list it created (needs [savedListId]); the follow batch unfollows
  /// (works from [listId] alone, so it survives a resume with no stored ref).
  Future<void> unsave(String listId, {String? savedListId});
}

/// Production [IOnboardingZinesApi] backed by the dedicated onboarding
/// preliminary-zines endpoints:
/// - `GET  /api/v1/app/onboarding/preliminary-zines`
/// - `POST /api/v1/app/onboarding/preliminary-zines/{list_id}/save`
class OnboardingZinesApi implements IOnboardingZinesApi {
  OnboardingZinesApi({
    required ApiClient apiClient,
    required IListsApi listsApi,
  }) : _apiClient = apiClient,
       _listsApi = listsApi;

  final ApiClient _apiClient;

  /// Used only by [unsave] — deleting the owned list a copy created is a normal
  /// list delete, not an onboarding-specific route.
  final IListsApi _listsApi;

  @override
  Future<List<OnboardingPreliminaryZine>> fetch() async {
    try {
      final response = await _apiClient.dio.get(
        ApiConstants.onboardingPreliminaryZines,
        // Preliminary-zine generation is LLM-backed — give it the longer
        // content timeout. GET is already retried by RetryInterceptor.
        options: Options(receiveTimeout: ApiConstants.onboardingContentTimeout),
      );
      return OnboardingPreliminaryZine.listFromResponse(
        response.data as Map<String, dynamic>,
      );
    } on DioException catch (err) {
      // PROD-4394 F4: the ErrorInterceptor rejects with the typed exception
      // INSIDE DioException.error — throw the typed one so the controller's
      // `on NotReadyException` poll loop actually runs in production. Before
      // this, the loop was dead in prod (one attempt, then terminal) while the
      // fake-API unit tests — which throw the bare typed exception — passed.
      final unwrapped = unwrapApiError(err);
      if (identical(unwrapped, err)) rethrow;
      // ignore: only_throw_errors — unwrapped is always an ApiException here.
      throw unwrapped;
    }
  }

  @override
  Future<String> save(String listId, {String? name}) async {
    final response = await _apiClient.dio.post(
      ApiConstants.onboardingPreliminaryZineSave(listId),
      data: name == null ? null : {'name': name},
    );
    // 201 → SavePreliminaryZineResponse. The new owned list id is what `unsave`
    // deletes; fall back to the preliminary id only if the body is unexpectedly
    // shaped (older backend), which keeps save working even if unsave can't.
    final data = response.data;
    final savedId = data is Map<String, dynamic>
        ? data['list_id'] as String?
        : null;
    return savedId ?? listId;
  }

  @override
  Future<void> unsave(String listId, {String? savedListId}) async {
    // The copy created a NEW owned list; reversing it deletes that list. Without
    // the created id (e.g. resumed session) there's nothing safe to delete — a
    // guess could delete the wrong list — so surface it rather than acting.
    if (savedListId == null) {
      throw StateError('Cannot unsave a copied zine without its saved list id');
    }
    await _listsApi.deleteList(savedListId);
  }
}

/// Live provider — the Dio client resolves lazily, so nothing touches the
/// network until the zines shelf first reads it.
final onboardingZinesApiProvider = Provider<IOnboardingZinesApi>(
  (ref) => OnboardingZinesApi(
    apiClient: ref.read(apiClientProvider),
    listsApi: ref.read(listsApiProvider),
  ),
);

/// The "most-followed" onboarding zines batch (the second row on step 3 —
/// "E estas são algumas que podes gostar"). Unlike [OnboardingZinesApi] these
/// are real PUBLIC zines authored by other users, so it reuses the same
/// [IOnboardingZinesApi] contract but sources them from the public-lists
/// discovery endpoint and "saves" by FOLLOWING (a public list can't be copied
/// via the onboarding endpoint). Reusing the interface lets the whole zines
/// stack (controller/shelf/card/reader) render this batch unchanged.
///
/// - `fetch()` → `GET /api/v1/app/lists/public?sort=popular` (all-time follower
///   count DESC; the caller's own lists are excluded server-side), geo-scoped
///   to the onboarding location so the row is relevant to the picked city.
/// - `save(listId)` → `POST /api/v1/app/lists/{list_id}/follow`. One-way here
///   (the card's quick-save is one-way); followed lists are excluded from the
///   next fetch, so resume stays clean without seeding.
class OnboardingSuggestedZinesApi implements IOnboardingZinesApi {
  OnboardingSuggestedZinesApi({
    required IListsApi listsApi,
    required this.resolveContext,
    this.limit = 10,
    this.radiusKm = 100,
  }) : _listsApi = listsApi;

  final IListsApi _listsApi;
  final Future<NearYouContext?> Function() resolveContext;
  final int limit;
  final double radiusKm;

  @override
  Future<List<OnboardingPreliminaryZine>> fetch() async {
    final ctx = await resolveContext();
    final response = await _listsApi.listPublicLists(
      sort: 'popular',
      limit: limit,
      // Scope to the onboarding location when we have one; without coords the
      // endpoint applies no geo filter (still returns the globally most-followed
      // public zines) — an acceptable fallback rather than an empty row.
      latitude: ctx?.latitude,
      longitude: ctx?.longitude,
      radiusKm: ctx == null ? null : radiusKm,
    );
    return response.items
        .map(_zineFromList)
        .where((z) => z.listId.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<String> save(String listId, {String? name}) async {
    await _listsApi.followList(listId);
    // Unfollow keys off the same public list id, so the ref IS the list id.
    return listId;
  }

  @override
  Future<void> unsave(String listId, {String? savedListId}) =>
      // A public zine is "saved" by following; reverse with unfollow. Keyed off
      // the public list id (== [listId]), so this works even on resume with no
      // stored ref.
      _listsApi.unfollowList(listId);

  /// Map a public [UserList] onto the preliminary-zine view model the carousel
  /// renders. The cover recipe + name drive the artwork; the description +
  /// owner attribution feed the redesigned card's editor row and bottom line
  /// (PROD-4? — new zine card). [OnboardingPreliminaryZine.items] stays empty
  /// because the reader hydrates a tapped zine's pages from
  /// `unifiedListProvider(listId)`.
  static OnboardingPreliminaryZine _zineFromList(UserList list) =>
      OnboardingPreliminaryZine(
        listId: list.id,
        name: list.name,
        itemCount: list.itemCount,
        items: const [],
        coverType: list.coverType,
        coverColor: list.coverColor,
        coverTexture: list.coverTexture,
        coverTextColor: list.coverTextColor,
        coverImageUrl: list.coverImageUrl,
        coverItemImageUrl: list.coverItemImageUrl,
        coverShowTitle: list.coverShowTitle,
        coverShowTexture: list.coverShowTexture,
        coverShowLogo: list.coverShowLogo,
        ownerHandle: list.ownerHandle,
        description: list.description,
        ownerName: list.ownerName,
        ownerId: list.ownerId,
        ownerAvatarUrl: list.ownerAvatarUrl,
        ownerIsExpert: list.ownerIsExpert,
      );
}

/// Live provider for the "most-followed" batch — dependencies resolve lazily
/// inside the body, so nothing hits the network until that shelf first reads it.
final onboardingSuggestedZinesApiProvider = Provider<IOnboardingZinesApi>(
  (ref) => OnboardingSuggestedZinesApi(
    listsApi: ref.read(listsApiProvider),
    resolveContext: () => ref.read(nearYouContextProvider.future),
  ),
);
