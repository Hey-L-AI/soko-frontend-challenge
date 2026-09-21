import 'dart:convert';

enum ResearchOffer {
  unpaid('unpaid'),
  amazon10('amazon_10');

  const ResearchOffer(this.flagValue);
  final String flagValue;
}

/// Reviewed campaign terms live in the app; PostHog controls audience and expiry.
class ResearchInvitation {
  static const flagKey = 'research-invitation';
  static const stagingFlagKey = 'research-invitation-staging';

  /// Staging recruitment must never enable customer recruitment in production.
  static String? flagKeyFor(String environment) => switch (environment) {
    'prod' => flagKey,
    'staging' => stagingFlagKey,
    _ => null,
  };
  static const campaign = 'research-2026-09-v1';
  static const destination =
      'https://calendly.com/joaograca-heyl/soko-user-feedback';

  const ResearchInvitation({
    required this.offer,
    required this.endsAt,
    required this.distinctId,
  });

  final ResearchOffer offer;
  final DateTime endsAt;
  final String distinctId;

  bool isActive(DateTime now) => now.isBefore(endsAt);

  Uri get bookingUri => Uri.parse(destination).replace(
    queryParameters: {
      'utm_source': 'soko',
      'utm_medium': 'in_app',
      'utm_campaign': campaign,
      'utm_content': offer.flagValue,
    },
  );

  static ResearchInvitation? parse({
    required String? variant,
    required Object? payload,
    required String distinctId,
  }) {
    final offer = switch (variant) {
      'unpaid' => ResearchOffer.unpaid,
      'amazon_10' => ResearchOffer.amazon10,
      _ => null,
    };
    if (offer == null || distinctId.isEmpty) return null;
    try {
      final data = payload is String ? jsonDecode(payload) : payload;
      if (data is! Map ||
          data['campaign_id'] != campaign ||
          data['calendly_url'] != destination) {
        return null;
      }
      final expiry = data['ends_at'];
      // Require an explicit timezone: campaign expiry must not vary by device.
      if (expiry is! String ||
          !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(expiry)) {
        return null;
      }
      final endsAt = DateTime.tryParse(expiry);
      if (endsAt == null) return null;
      return ResearchInvitation(
        offer: offer,
        endsAt: endsAt.toUtc(),
        distinctId: distinctId,
      );
    } on FormatException {
      return null;
    }
  }
}
