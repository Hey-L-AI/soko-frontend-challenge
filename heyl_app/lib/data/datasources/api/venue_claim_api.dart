import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/business_portal.dart';
import '../../models/owner_gallery.dart';
import '../../models/venue_claim.dart';
import '../interfaces/venue_claim_api.dart';
import 'api_client.dart';

class VenueClaimApi implements IVenueClaimApi {
  VenueClaimApi({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;
  Dio get _dio => _apiClient.dio;

  @override
  Future<ClaimStateResponse> getClaimState(String venueId) async {
    final response = await _dio.get(ApiConstants.venueClaimState(venueId));
    return ClaimStateResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<ClaimInitiateResponse> initiateInstagramClaim(String venueId) async {
    final response = await _dio.post(ApiConstants.venueClaimInstagram(venueId));
    return ClaimInitiateResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<void> confirmPendingVenueClaim(String pendingKey) async {
    await _dio.post(ApiConstants.confirmPendingVenueClaim(pendingKey));
  }

  @override
  Future<List<OwnedBusiness>> getMyBusinesses() async {
    final response = await _dio.get(ApiConstants.myBusinesses);
    final data = response.data as Map<String, dynamic>;
    return (data['businesses'] as List<dynamic>)
        .map((item) => OwnedBusiness.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<ClaimSummary>> getMyClaims() async {
    final response = await _dio.get(ApiConstants.myClaims);
    final data = response.data as Map<String, dynamic>;
    final claims = data['claims'];
    return claims is List
        ? claims
              .whereType<Map<String, dynamic>>()
              .map(ClaimSummary.fromJson)
              .toList()
        : <ClaimSummary>[];
  }

  @override
  Future<void> updateOwnedVenue(String venueId, OwnerVenueUpdate update) async {
    await _dio.patch(ApiConstants.ownerVenue(venueId), data: update.fields);
  }

  @override
  Future<void> removeOwnedVenue(String venueId) async {
    await _dio.delete(ApiConstants.ownerVenue(venueId));
  }

  @override
  Future<String?> uploadOwnedVenuePhoto(
    String venueId, {
    required List<int> bytes,
    required String filename,
  }) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    final response = await _dio.post(
      ApiConstants.ownerVenuePhoto(venueId),
      data: formData,
    );
    final data = response.data as Map<String, dynamic>?;
    return data?['image_url'] as String?;
  }

  @override
  Future<PortalVenueSearchResponse> searchBusinessVenues(
    String query, {
    double? latitude,
    double? longitude,
    int? limit,
  }) async {
    final response = await _dio.get(
      ApiConstants.businessVenuesSearch,
      queryParameters: <String, dynamic>{
        'q': query,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (limit != null) 'limit': limit,
      },
    );
    return PortalVenueSearchResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<PortalGoogleSearchResponse> searchBusinessVenuesGoogle(
    String query, {
    double? latitude,
    double? longitude,
    String? region,
    String? language,
    int? limit,
  }) async {
    final response = await _dio.get(
      ApiConstants.businessVenuesSearchGoogle,
      queryParameters: <String, dynamic>{
        'q': query,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (region != null) 'region_code': region,
        if (language != null) 'language': language,
        if (limit != null) 'limit': limit,
      },
    );
    return PortalGoogleSearchResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<PortalVenueCandidate> resolveBusinessVenue(String url) async {
    final response = await _dio.post(
      ApiConstants.businessVenuesResolve,
      data: <String, dynamic>{'url': url},
    );
    return PortalVenueCandidate.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<PortalVenueCandidate> resolveBusinessVenueByPlaceId(
    String placeId,
  ) async {
    // The resolve endpoint takes exactly one of url / google_place_id; send
    // only the place id here (S4 contract).
    final response = await _dio.post(
      ApiConstants.businessVenuesResolve,
      data: <String, dynamic>{'google_place_id': placeId},
    );
    return PortalVenueCandidate.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<OwnerGalleryResponse> getOwnerVenueGallery(String venueId) async {
    final response = await _dio.get(ApiConstants.ownerVenueImages(venueId));
    return OwnerGalleryResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<OwnerGalleryResponse> uploadOwnerVenueGalleryImages(
    String venueId,
    List<GalleryUpload> files,
  ) async {
    final formData = FormData();
    for (final file in files) {
      formData.files.add(
        MapEntry(
          'files',
          MultipartFile.fromBytes(
            file.bytes,
            filename: file.filename,
            contentType: file.contentType != null
                ? DioMediaType.parse(file.contentType!)
                : null,
          ),
        ),
      );
    }
    final response = await _dio.post(
      ApiConstants.ownerVenueImages(venueId),
      data: formData,
      // Gallery uploads can be several images at once; match the cover-photo
      // upload's timeouts + explicit content-type (see uploadListCover).
      options: Options(
        contentType: 'multipart/form-data',
        sendTimeout: ApiConstants.uploadTimeout,
        receiveTimeout: ApiConstants.uploadTimeout,
      ),
    );
    return OwnerGalleryResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<OwnerGalleryResponse> deleteOwnerVenueGalleryImage(
    String venueId,
    String imageId,
  ) async {
    final response = await _dio.delete(
      ApiConstants.ownerVenueImage(venueId, imageId),
    );
    return OwnerGalleryResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<OwnerGalleryResponse> reorderOwnerVenueGallery(
    String venueId,
    List<String> orderedImageIds,
  ) async {
    final response = await _dio.patch(
      ApiConstants.ownerVenueImagesOrder(venueId),
      data: <String, dynamic>{'ordered_ids': orderedImageIds},
    );
    return OwnerGalleryResponse.fromJson(response.data as Map<String, dynamic>);
  }
}
