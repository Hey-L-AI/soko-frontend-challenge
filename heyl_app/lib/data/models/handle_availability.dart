/// Response from handle availability check API
class HandleAvailabilityResponse {
  final String handle;
  final bool available;
  final String? message;

  const HandleAvailabilityResponse({
    required this.handle,
    required this.available,
    this.message,
  });

  factory HandleAvailabilityResponse.fromJson(Map<String, dynamic> json) {
    return HandleAvailabilityResponse(
      handle: json['handle'] as String,
      available: json['available'] as bool,
      message: json['message'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'handle': handle,
      'available': available,
      if (message != null) 'message': message,
    };
  }
}
