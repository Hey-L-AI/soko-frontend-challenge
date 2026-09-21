import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/business_portal.dart';
import '../../../data/models/social_proof.dart';
import '../../../providers/api_provider.dart';
import 'business_search_area_providers.dart';

/// Minimum query length before we hit the search endpoint. Autocomplete is
/// local-only (Meilisearch, no Google fallback), so a 1-char query is noise.
const int kBusinessVenueSearchMinChars = 2;

/// Debounced venue search for the Business Connect claim flow (PROD-4040 T2.2).
///
/// Keyed by the already-debounced query string (the field widget owns the
/// debounce timer, mirroring the Discovery typeahead). Short/blank queries
/// resolve to an empty list without a request so keystrokes below the
/// threshold never spend a round-trip.
///
/// PROD-4268 (S3): watches [businessSearchAreaProvider] and forwards its
/// coordinates when a full pair is known, so the backend's sort-only geography
/// mode ranks nearby venues first (no radius cutoff). Watching means changing
/// the area invalidates in-flight results and re-runs local search; the area
/// seed is captured once so background GPS never reorders a focused list. Still
/// local-only — never calls Google.
final businessVenueSearchProvider = FutureProvider.autoDispose
    .family<List<PortalVenueCandidate>, String>((ref, query) async {
      final trimmed = query.trim();
      if (trimmed.length < kBusinessVenueSearchMinChars) {
        return const <PortalVenueCandidate>[];
      }
      final area = ref.watch(businessSearchAreaProvider);
      final response = await ref
          .watch(venueClaimApiProvider)
          .searchBusinessVenues(
            trimmed,
            latitude: area.hasCoordinates ? area.latitude : null,
            longitude: area.hasCoordinates ? area.longitude : null,
            limit: 8,
          );
      return response.results;
    });

/// A venue whose claim is awaiting manual approval, shown as "under approval"
/// on the Business Home dashboard.
class PendingClaimEntry {
  const PendingClaimEntry({required this.venueId, this.venue});

  final String venueId;
  final VenueDetailResponse? venue;
}

/// Pending (not-yet-approved) claims for the dashboard (PROD-4040 T2.1).
///
/// Verified claims already surface as owned venues via
/// `ownedBusinessProfileEntriesProvider`, so this keeps only `pending` ones to
/// avoid listing a venue twice. Each is enriched from venue detail for its name
/// and artwork; a failed detail fetch still yields a card keyed by [venueId].
final businessPendingClaimsProvider =
    FutureProvider.autoDispose<List<PendingClaimEntry>>((ref) async {
      final claims = await ref.watch(venueClaimApiProvider).getMyClaims();
      final pending = claims
          .where((claim) => claim.status == 'pending')
          .toList();
      final detailApi = ref.watch(detailApiProvider);

      return Future.wait(
        pending.map((claim) async {
          try {
            final venue = await detailApi.getVenueDetail(claim.venueId);
            return PendingClaimEntry(venueId: claim.venueId, venue: venue);
          } catch (_) {
            return PendingClaimEntry(venueId: claim.venueId);
          }
        }),
      );
    });
