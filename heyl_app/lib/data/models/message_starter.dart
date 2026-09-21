/// Message starter model matching OpenAPI MessageStarter schema
class MessageStarter {
  final String id;
  final String text;

  const MessageStarter({
    required this.id,
    required this.text,
  });

  factory MessageStarter.fromJson(Map<String, dynamic> json) {
    return MessageStarter(
      id: json['id'] as String,
      text: json['text'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
    };
  }
}

/// Response model for message starters list
class MessageStartersResponse {
  final List<MessageStarter> items;

  const MessageStartersResponse({required this.items});

  factory MessageStartersResponse.fromJson(Map<String, dynamic> json) {
    return MessageStartersResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => MessageStarter.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
