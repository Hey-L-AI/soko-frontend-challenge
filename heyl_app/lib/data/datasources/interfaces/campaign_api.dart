import '../../models/campaign.dart';

/// Client for the fake-door campaign framework.
///
/// Campaign content is fully backend-authored and already personalized
/// (merge tags resolved server-side) — the client only fetches, renders,
/// and reports back user interactions. There is no client-side campaign
/// catalog (unlike `IFeatureSpotlightsApi`, where the Flutter binary owns
/// the catalog): the backend decides which campaigns are active for the
/// current user.
abstract class ICampaignApi {
  /// Fetch every campaign currently active for the signed-in user (or
  /// guest). Callers should treat an empty list as "nothing to show" —
  /// including when the endpoint 404s because it hasn't shipped yet.
  Future<List<Campaign>> getActiveCampaigns();

  /// Catalog / history read (`GET /campaigns`): every eligible campaign
  /// INCLUDING ones the caller already answered, each annotated with the
  /// caller's own [Campaign.response]. Used by the admin test box to list and
  /// re-open campaigns regardless of responded state. Tolerates 404 (empty).
  Future<List<Campaign>> getCampaignsForUser();

  /// Fetch a single campaign by its stable key.
  Future<Campaign> getCampaign(String key);

  /// Record a user interaction with campaign [key]. Fire-and-forget from
  /// the caller's perspective — implementations tolerate 404 (endpoint not
  /// yet deployed) by swallowing the error.
  Future<void> submitCampaignResponse(
    String key,
    CampaignResponseRequest request,
  );
}
