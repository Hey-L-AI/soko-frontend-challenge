import 'user_list.dart';

/// `{id, name}` pair the backend echoes on city-scoped Discovery feeds. Same
/// shape across `/feed/highlighted` and `/feed/venues-with-events` (the
/// `FedCity` schema in the OpenAPI).
class DiscoveryFeedCity {
  final String id;
  final String name;
  const DiscoveryFeedCity({required this.id, required this.name});

  factory DiscoveryFeedCity.fromJson(Map<String, dynamic> json) =>
      DiscoveryFeedCity(id: json['id'] as String, name: json['name'] as String);
}

/// One card on the Em destaque (highlighted) shelf. Wraps the standard
/// `UserListOut` payload — identical to what `/lists/public` items return.
/// Per PROD-1986 the BE returns a marketing-curated ordered set (1–10 cards
/// per scope) via the resolution chain `city → country → hide`; the FE
/// slices to the first 2 in `highlighted_shelf_provider.dart`.
class HighlightedCard {
  final UserList list;
  const HighlightedCard({required this.list});

  factory HighlightedCard.fromJson(Map<String, dynamic> json) =>
      HighlightedCard(
        list: UserList.fromJson(json['list'] as Map<String, dynamic>),
      );
}

/// `/api/v1/app/feed/highlighted` response (PROD-1554 → PROD-1986).
///
/// `cards` is 0–10 long — a marketing-curated ordered selection resolved
/// server-side via `city → country → hide`: BE first tries the per-city
/// scope, falls back to the user's country scope if empty, otherwise
/// returns `cards: []` and the FE hides the shelf entirely. The FE slices
/// to the first 2 in `highlighted_shelf_provider.dart`.
class HighlightedFeedResponse {
  final List<HighlightedCard> cards;
  final DiscoveryFeedCity city;

  const HighlightedFeedResponse({required this.cards, required this.city});

  factory HighlightedFeedResponse.fromJson(Map<String, dynamic> json) {
    return HighlightedFeedResponse(
      cards: (json['cards'] as List<dynamic>)
          .map((e) => HighlightedCard.fromJson(e as Map<String, dynamic>))
          .toList(),
      city: DiscoveryFeedCity.fromJson(json['city'] as Map<String, dynamic>),
    );
  }
}
