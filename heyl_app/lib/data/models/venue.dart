/// Venue model matching OpenAPI Venue schema
class Venue {
  final String id;
  final String name;
  final String? city;

  /// Additional fields for display
  final String? description;
  final String? imageUrl;
  final String? address;
  final String? neighborhood;
  final double? lat;
  final double? lon;
  final List<String> tags;

  const Venue({
    required this.id,
    required this.name,
    this.city,
    this.description,
    this.imageUrl,
    this.address,
    this.neighborhood,
    this.lat,
    this.lon,
    this.tags = const [],
  });

  factory Venue.fromJson(Map<String, dynamic> json) {
    return Venue(
      id: json['id'] as String,
      name: json['name'] as String,
      city: json['city'] as String?,
      description: json['description'] as String?,
      imageUrl: json['image_url'] as String?,
      address: json['address'] as String?,
      neighborhood: json['neighborhood'] as String?,
      lat: (json['lat'] as num?)?.toDouble(),
      lon: (json['lon'] as num?)?.toDouble(),
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (city != null) 'city': city,
      if (description != null) 'description': description,
      if (imageUrl != null) 'image_url': imageUrl,
      if (address != null) 'address': address,
      if (neighborhood != null) 'neighborhood': neighborhood,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
      if (tags.isNotEmpty) 'tags': tags,
    };
  }

  Venue copyWith({
    String? id,
    String? name,
    String? city,
    String? description,
    String? imageUrl,
    String? address,
    String? neighborhood,
    double? lat,
    double? lon,
    List<String>? tags,
  }) {
    return Venue(
      id: id ?? this.id,
      name: name ?? this.name,
      city: city ?? this.city,
      description: description ?? this.description,
      imageUrl: imageUrl ?? this.imageUrl,
      address: address ?? this.address,
      neighborhood: neighborhood ?? this.neighborhood,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      tags: tags ?? this.tags,
    );
  }
}

/// Response model for venue list
class VenueListResponse {
  final List<Venue> items;
  final String? nextCursor;

  const VenueListResponse({
    required this.items,
    this.nextCursor,
  });

  factory VenueListResponse.fromJson(Map<String, dynamic> json) {
    return VenueListResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => Venue.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: json['next_cursor'] as String?,
    );
  }

  bool get hasMore => nextCursor != null;
}
