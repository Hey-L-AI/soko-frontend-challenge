import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/social_proof.dart';
import '../../../data/models/venue_claim.dart';
import '../../../providers/api_provider.dart';

/// An owned venue in the profile shelf, retaining its parent business for a
/// fallback name when the venue-detail enrichment is unavailable.
class OwnedBusinessProfileEntry {
  const OwnedBusinessProfileEntry({
    required this.business,
    required this.venueId,
    this.venue,
  });

  final OwnedBusiness business;
  final String venueId;
  final VenueDetailResponse? venue;
}

/// Per-venue ownership state. The server is the source of truth for both
/// whether a venue is claimed and whether the current user owns it.
final venueClaimStateProvider = FutureProvider.autoDispose
    .family<ClaimStateResponse, String>((ref, venueId) async {
      return ref.watch(venueClaimApiProvider).getClaimState(venueId);
    });

/// Flattening this API response keeps the owner affordance independent from a
/// particular venue-detail response shape (T19).
final ownedVenueIdsProvider = FutureProvider.autoDispose<Set<String>>((
  ref,
) async {
  final businesses = await ref.watch(venueClaimApiProvider).getMyBusinesses();
  return {
    for (final business in businesses)
      for (final venue in business.venues) venue.venueId,
  };
});

/// Venues the signed-in user can manage from their profile.
///
/// `GET /me/businesses` deliberately carries only the ownership relation, so
/// each owned venue is enriched from its venue detail for the existing artwork
/// and destination. A failed detail fetch never hides a valid owned venue: the
/// card can still open that venue using [venueId].
final ownedBusinessProfileEntriesProvider =
    FutureProvider.autoDispose<List<OwnedBusinessProfileEntry>>((ref) async {
      final businesses = await ref
          .watch(venueClaimApiProvider)
          .getMyBusinesses();
      final detailApi = ref.watch(detailApiProvider);

      final entries = await Future.wait(
        businesses
            .expand((business) sync* {
              for (final venue in business.venues) {
                yield (business: business, venueId: venue.venueId);
              }
            })
            .map((entry) async {
              final venueId = entry.venueId;
              try {
                final venue = await detailApi.getVenueDetail(venueId);
                return OwnedBusinessProfileEntry(
                  business: entry.business,
                  venueId: venueId,
                  venue: venue,
                );
              } catch (_) {
                return OwnedBusinessProfileEntry(
                  business: entry.business,
                  venueId: venueId,
                );
              }
            }),
      );

      return entries;
    });

/// Local overlay carrying the owner's just-saved edit for a venue.
///
/// It is set the moment a save starts and, on success, is intentionally left in
/// place: the backing detail fetch ([_venueDetailFetchProvider]) is cached per
/// key and is NOT re-hit in-session after a save (a real refetch would flash the
/// detail screen's bare `AsyncValue.when` loading spinner), so this overlay is
/// the only in-session source of the new value until the user navigates away and
/// the fetch auto-disposes. A failed request clears the overlay so the UI
/// immediately returns to the server value.
final optimisticOwnerVenueEditsProvider = StateProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, venueId) => null);

/// A venue with any in-flight owner edit overlaid.
///
/// Every owner-editable surface — the name/tag block, the details grid (phone,
/// area, opening hours) and the edit-sheet entry points — must read THIS, not
/// the raw `snapshot.venue`, so a just-saved edit is visible immediately.
/// Because the detail fetch is not re-issued in-session (see
/// [optimisticOwnerVenueEditsProvider]), a surface that reads the raw venue
/// would keep showing the pre-edit value until a full reload — which reads as
/// "the edit didn't save" and, on re-opening the editor, as "it reset".
VenueDetailResponse ownerMergedVenue(WidgetRef ref, VenueDetailResponse venue) {
  final edits = ref.watch(optimisticOwnerVenueEditsProvider(venue.id));
  return edits == null ? venue : venue.withOwnerEdits(edits);
}
