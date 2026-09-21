import '../../core/config/research_invitation.dart';

enum ResearchInvitationAction {
  viewed('viewed'),
  dismissed('dismissed'),
  bookingLinkClicked('booking_link_clicked');

  const ResearchInvitationAction(this.apiValue);
  final String apiValue;
}

/// Server authority for one user's campaign. A revision belongs to one display
/// and must never be replaced with a newer revision when retrying its events.
class ResearchInvitationStatus {
  const ResearchInvitationStatus({
    required this.campaignId,
    required this.revision,
    required this.shouldSuppress,
    this.offer,
  });

  final String campaignId;
  final int revision;
  final bool shouldSuppress;
  final ResearchOffer? offer;

  factory ResearchInvitationStatus.fromJson(Map<String, dynamic> json) {
    final revision = json['revision'];
    final campaign = json['campaign_id'];
    final suppress = json['should_suppress'];
    if (campaign is! String ||
        revision is! int ||
        revision < 1 ||
        suppress is! bool) {
      throw const FormatException('Invalid research invitation status');
    }
    final offer = switch (json['variant']) {
      null => null,
      'unpaid' => ResearchOffer.unpaid,
      'amazon_10' => ResearchOffer.amazon10,
      _ => throw const FormatException('Unknown research invitation variant'),
    };
    return ResearchInvitationStatus(
      campaignId: campaign,
      revision: revision,
      shouldSuppress: suppress,
      offer: offer,
    );
  }
}
