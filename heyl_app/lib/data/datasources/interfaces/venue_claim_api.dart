import '../../models/business_portal.dart';
import '../../models/owner_gallery.dart';
import '../../models/venue_claim.dart';

abstract class IVenueClaimApi {
  Future<ClaimStateResponse> getClaimState(String venueId);
  Future<ClaimInitiateResponse> initiateInstagramClaim(String venueId);
  Future<void> confirmPendingVenueClaim(String pendingKey);
  Future<List<OwnedBusiness>> getMyBusinesses();

  /// The caller's claims across all states (pending / verified / rejected).
  /// Drives the "under approval" venues on the Business Home dashboard (T2.1).
  Future<List<ClaimSummary>> getMyClaims();
  Future<void> updateOwnedVenue(String venueId, OwnerVenueUpdate update);

  /// Remove the caller's ownership connection to [venueId] (self un-claim).
  Future<void> removeOwnedVenue(String venueId);

  /// Upload a cover photo for [venueId]; returns the client-ready image URL.
  /// Bytes work on web + native (image_picker `readAsBytes`).
  Future<String?> uploadOwnedVenuePhoto(
    String venueId, {
    required List<int> bytes,
    required String filename,
  });

  // ---- Business Connect portal (PROD-4040) ----

  /// T2.2: search claimable venues by name (local-only autocomplete). Optional
  /// [latitude]/[longitude] bias results; [limit] caps the result count.
  Future<PortalVenueSearchResponse> searchBusinessVenues(
    String query, {
    double? latitude,
    double? longitude,
    int? limit,
  });

  /// S5 (PROD-4270): transient Google name search for a venue not yet in our
  /// DB. Writes nothing server-side; each candidate carries a canonical
  /// `venue_id`/`claim_status` only when an active venue already holds that
  /// place id. [latitude]/[longitude] bias (never restrict) results; [region]
  /// is an ISO-3166-1 alpha-2 country code for country-level context; [language]
  /// is a BCP-47 tag localising names/addresses; [limit] caps the result count
  /// (Google returns at most 10).
  Future<PortalGoogleSearchResponse> searchBusinessVenuesGoogle(
    String query, {
    double? latitude,
    double? longitude,
    String? region,
    String? language,
    int? limit,
  });

  /// T2.2: resolve a pasted Google Maps place URL to a single claimable venue.
  Future<PortalVenueCandidate> resolveBusinessVenue(String url);

  /// S5 (PROD-4270): resolve a Google place id (selected from
  /// [searchBusinessVenuesGoogle]) to a single claimable venue — the same
  /// canonical resolution as [resolveBusinessVenue], reached by id instead of
  /// URL (200 existing venue / 201 minted via Google Places).
  Future<PortalVenueCandidate> resolveBusinessVenueByPlaceId(String placeId);

  /// T2.3: list the owner-curated gallery for a venue you own.
  Future<OwnerGalleryResponse> getOwnerVenueGallery(String venueId);

  /// T2.3: upload one or more gallery images (JPEG/PNG/WebP, ≤10MB each).
  /// Returns the full re-ordered gallery.
  Future<OwnerGalleryResponse> uploadOwnerVenueGalleryImages(
    String venueId,
    List<GalleryUpload> files,
  );

  /// T2.3: delete a single gallery image; returns the remaining gallery.
  Future<OwnerGalleryResponse> deleteOwnerVenueGalleryImage(
    String venueId,
    String imageId,
  );

  /// T2.3: reorder the gallery to [orderedImageIds]; returns the new gallery.
  Future<OwnerGalleryResponse> reorderOwnerVenueGallery(
    String venueId,
    List<String> orderedImageIds,
  );
}
