/// Minimal saved item for merge preview display
class SavedItemPreview {
  final String id;
  final String itemType; // "event" or "place"
  final String title;
  final String? subtitle;
  final String? imageUrl;

  const SavedItemPreview({
    required this.id,
    required this.itemType,
    required this.title,
    this.subtitle,
    this.imageUrl,
  });

  factory SavedItemPreview.fromJson(Map<String, dynamic> json) {
    return SavedItemPreview(
      id: json['id'] as String,
      itemType: json['item_type'] as String,
      title: json['title'] as String,
      subtitle: json['subtitle'] as String?,
      imageUrl: json['image_url'] as String?,
    );
  }

  bool get isEvent => itemType == 'event';
  bool get isPlace => itemType == 'place';
}
