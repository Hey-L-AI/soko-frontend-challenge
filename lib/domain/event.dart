class Event {
  const Event({
    required this.id,
    required this.title,
    required this.category,
    required this.neighbourhood,
    required this.venue,
    required this.startsAt,
    required this.priceEuros,
    required this.description,
    required this.accessibility,
    required this.bookingRequired,
    required this.artwork,
  });

  factory Event.fromJson(Map<String, dynamic> json) => Event(
    id: json['id'] as String,
    title: json['title'] as String,
    category: json['category'] as String,
    neighbourhood: json['neighbourhood'] as String,
    venue: json['venue'] as String,
    startsAt: DateTime.parse(json['startsAt'] as String),
    priceEuros: (json['priceEuros'] as num?)?.toDouble(),
    description: json['description'] as String,
    accessibility: json['accessibility'] as String,
    bookingRequired: json['bookingRequired'] as bool,
    artwork: json['artwork'] as int,
  );

  final String id;
  final String title;
  final String category;
  final String neighbourhood;
  final String venue;

  /// Fixture wall-clock time in Lisbon, independent of the browser's timezone.
  final DateTime startsAt;
  final double? priceEuros;
  final String description;
  final String accessibility;
  final bool bookingRequired;
  final int artwork;

  bool matches(String query) {
    final search = query.trim().toLowerCase();
    return [
      title,
      category,
      neighbourhood,
      venue,
    ].any((value) => value.toLowerCase().contains(search));
  }
}
