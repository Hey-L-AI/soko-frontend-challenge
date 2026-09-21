import 'package:flutter/material.dart';

import '../../../l10n/generated/l10n.dart';
import 'legal_page_scaffold.dart';

/// Privacy Policy screen implementing the legal content from the Lovable prototype.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return LegalPageScaffold(
      title: l10n.privacyPolicyTitle,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LegalMutedText(l10n.privacyPolicyLastUpdated),
          const SizedBox(height: 16),
          LegalParagraph(l10n.privacyPolicyIntro1),
          LegalParagraph(l10n.privacyPolicyIntro2),
          LegalParagraph(l10n.privacyPolicyIntro3),

          // Section 1: Data Controller
          LegalSectionTitle(l10n.privacyPolicySection1Title),
          LegalParagraph(
            '${l10n.privacyPolicySection1Content1}\n'
            '${l10n.privacyPolicySection1Content2}\n'
            '${l10n.privacyPolicySection1Content3}',
          ),
          LegalParagraph(l10n.privacyPolicySection1EmailContacts),
          LegalEmailLink(
            label: l10n.privacyPolicySection1Privacy,
            email: 'privacy@soko.fyi',
          ),
          LegalEmailLink(
            label: l10n.privacyPolicySection1Legal,
            email: 'legal@soko.fyi',
          ),
          LegalParagraph(l10n.privacyPolicySection1DataController),

          // Section 2: What Data We Collect
          LegalSectionTitle(l10n.privacyPolicySection2Title),
          LegalParagraph(l10n.privacyPolicySection2Intro),

          // Section 2.1: Data You Provide
          LegalSubsectionTitle(l10n.privacyPolicySection2S21Title),
          LegalParagraph(l10n.privacyPolicySection2S21Intro),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection2S21ItemName,
              l10n.privacyPolicySection2S21ItemPhone,
              l10n.privacyPolicySection2S21ItemLocation,
              l10n.privacyPolicySection2S21ItemInterests,
              l10n.privacyPolicySection2S21ItemMessages,
              l10n.privacyPolicySection2S21ItemFeedback,
            ],
          ),
          LegalParagraph(l10n.privacyPolicySection2S21Consent),

          // Section 2.2: Automatically Collected Data
          LegalSubsectionTitle(l10n.privacyPolicySection2S22Title),
          LegalParagraph(l10n.privacyPolicySection2S22Intro),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection2S22ItemChannel,
              l10n.privacyPolicySection2S22ItemTimestamps,
              l10n.privacyPolicySection2S22ItemDevice,
              l10n.privacyPolicySection2S22ItemAdvertisingId,
            ],
          ),
          LegalParagraph(l10n.privacyPolicySection2S22NoTracking),

          // Section 2.3: Sensitive Data
          LegalSubsectionTitle(l10n.privacyPolicySection2S23Title),
          LegalParagraph(l10n.privacyPolicySection2S23Content1),
          LegalParagraph(l10n.privacyPolicySection2S23Content2),

          // Section 3: Why We Process Your Data
          LegalSectionTitle(l10n.privacyPolicySection3Title),

          // Section 3.1: Providing the Service
          LegalSubsectionTitle(l10n.privacyPolicySection3S31Title),
          LegalParagraph(l10n.privacyPolicySection3S31Purpose),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection3S31PurposeRespond,
              l10n.privacyPolicySection3S31PurposeRecommendations,
              l10n.privacyPolicySection3S31PurposePersonalize,
              l10n.privacyPolicySection3S31PurposeMemory,
            ],
          ),
          LegalParagraph(l10n.privacyPolicySection3S31LegalBasis),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection3S31LegalPerformance,
              l10n.privacyPolicySection3S31LegalConsent,
            ],
          ),

          // Section 3.2: Improving and Securing Soko
          LegalSubsectionTitle(l10n.privacyPolicySection3S32Title),
          LegalParagraph(l10n.privacyPolicySection3S32Purpose),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection3S32PurposeImprove,
              l10n.privacyPolicySection3S32PurposeDebug,
              l10n.privacyPolicySection3S32PurposePrevent,
            ],
          ),
          LegalParagraph(l10n.privacyPolicySection3S32LegalBasis),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection3S32LegalLegitimate,
              l10n.privacyPolicySection3S32LegalCompliance,
            ],
          ),
          LegalParagraph(l10n.privacyPolicySection3S32Anonymized),

          // Section 3.3: Communications
          LegalSubsectionTitle(l10n.privacyPolicySection3S33Title),
          LegalParagraph(l10n.privacyPolicySection3S33Purpose),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection3S33PurposeRespond,
              l10n.privacyPolicySection3S33PurposeCommunicate,
            ],
          ),
          LegalParagraph(l10n.privacyPolicySection3S33LegalBasis),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection3S33LegalLegitimate,
              l10n.privacyPolicySection3S33LegalObligation,
            ],
          ),
          LegalParagraph(l10n.privacyPolicySection3S33NoMarketing),

          // Section 3.4: Marketing Measurement
          LegalSubsectionTitle(l10n.privacyPolicySection3S34Title),
          LegalParagraph(l10n.privacyPolicySection3S34Purpose),
          LegalBulletList(items: [l10n.privacyPolicySection3S34PurposeMeasure]),
          LegalParagraph(l10n.privacyPolicySection3S34LegalBasis),
          LegalBulletList(items: [l10n.privacyPolicySection3S34LegalConsent]),
          LegalParagraph(l10n.privacyPolicySection3S34NoConsent),

          // Section 4: AI Processing and Human Review
          LegalSectionTitle(l10n.privacyPolicySection4Title),
          LegalParagraph(l10n.privacyPolicySection4Intro),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection4ItemAi,
              l10n.privacyPolicySection4ItemData,
              l10n.privacyPolicySection4ItemNeverShared,
              l10n.privacyPolicySection4ItemHuman,
              l10n.privacyPolicySection4ItemNoTraining,
            ],
          ),

          // Section 5: Who We Share Data With
          LegalSectionTitle(l10n.privacyPolicySection5Title),
          LegalParagraph(l10n.privacyPolicySection5NoSell),
          LegalParagraph(l10n.privacyPolicySection5ShareWith),

          // Section 5.1: Service Providers
          LegalSubsectionTitle(l10n.privacyPolicySection5S51Title),
          LegalParagraph(l10n.privacyPolicySection5S51Intro),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection5S51ItemMessaging,
              l10n.privacyPolicySection5S51ItemAi,
              l10n.privacyPolicySection5S51ItemWeather,
              l10n.privacyPolicySection5S51ItemBackgroundAi,
              l10n.privacyPolicySection5S51ItemCloud,
              l10n.privacyPolicySection5S51ItemAdvertising,
            ],
          ),
          LegalParagraph(l10n.privacyPolicySection5S51Instructions),
          LegalParagraph(l10n.privacyPolicySection5S51AdvertisingNote),

          // Section 5.2: Legal and Safety Obligations
          LegalSubsectionTitle(l10n.privacyPolicySection5S52Title),
          LegalParagraph(l10n.privacyPolicySection5S52Intro),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection5S52ItemComply,
              l10n.privacyPolicySection5S52ItemRespond,
              l10n.privacyPolicySection5S52ItemProtect,
            ],
          ),

          // Section 5.3: Business Transfers
          LegalSubsectionTitle(l10n.privacyPolicySection5S53Title),
          LegalParagraph(l10n.privacyPolicySection5S53Content),

          // Section 6: International Data Transfers
          LegalSectionTitle(l10n.privacyPolicySection6Title),
          LegalParagraph(l10n.privacyPolicySection6Content1),
          LegalParagraph(l10n.privacyPolicySection6Content2),

          // Section 7: Data Retention
          LegalSectionTitle(l10n.privacyPolicySection7Title),
          LegalParagraph(l10n.privacyPolicySection7Intro),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection7ItemActive,
              l10n.privacyPolicySection7ItemInactive,
              l10n.privacyPolicySection7ItemDeletion,
            ],
          ),

          // Section 8: Your Rights
          LegalSectionTitle(l10n.privacyPolicySection8Title),

          // Section 8.1: EU (GDPR)
          LegalSubsectionTitle(l10n.privacyPolicySection8S81Title),
          LegalParagraph(l10n.privacyPolicySection8S81Intro),
          LegalBulletList(
            items: [
              l10n.privacyPolicySection8S81ItemAccess,
              l10n.privacyPolicySection8S81ItemCorrect,
              l10n.privacyPolicySection8S81ItemDelete,
              l10n.privacyPolicySection8S81ItemRestrict,
              l10n.privacyPolicySection8S81ItemPortability,
              l10n.privacyPolicySection8S81ItemWithdraw,
            ],
          ),
          LegalEmailLink(
            label: l10n.privacyPolicySection8S81Requests,
            email: 'privacy@soko.fyi',
          ),
          LegalParagraph(l10n.privacyPolicySection8S81Complaint),

          // Section 8.2: Other Jurisdictions
          LegalSubsectionTitle(l10n.privacyPolicySection8S82Title),
          LegalParagraph(l10n.privacyPolicySection8S82Content),

          // Section 9: Cookies and Tracking
          LegalSectionTitle(l10n.privacyPolicySection9Title),
          LegalParagraph(l10n.privacyPolicySection9Content1),
          LegalParagraph(l10n.privacyPolicySection9Content2),

          // Section 9.1: Mobile App Tracking (iOS)
          LegalSubsectionTitle(l10n.privacyPolicySection9S91Title),
          LegalParagraph(l10n.privacyPolicySection9S91Content1),
          LegalParagraph(l10n.privacyPolicySection9S91Content2),
          LegalParagraph(l10n.privacyPolicySection9S91Content3),

          // Section 10: Minors
          LegalSectionTitle(l10n.privacyPolicySection10Title),
          LegalParagraph(l10n.privacyPolicySection10Content1),
          LegalParagraph(l10n.privacyPolicySection10Content2),

          // Section 11: Security
          LegalSectionTitle(l10n.privacyPolicySection11Title),
          LegalParagraph(l10n.privacyPolicySection11Content),

          // Section 12: Changes to This Policy
          LegalSectionTitle(l10n.privacyPolicySection12Title),
          LegalParagraph(l10n.privacyPolicySection12Content1),
          LegalParagraph(l10n.privacyPolicySection12Content2),

          // Section 13: Contact
          LegalSectionTitle(l10n.privacyPolicySection13Title),
          LegalEmailLink(
            label: l10n.privacyPolicySection13Privacy,
            email: 'privacy@soko.fyi',
          ),
          LegalEmailLink(
            label: l10n.privacyPolicySection13Legal,
            email: 'legal@soko.fyi',
          ),

          // Summary Section
          const LegalDivider(),
          LegalSectionTitle(l10n.privacyPolicySummaryTitle),
          LegalBulletList(
            items: [
              l10n.privacyPolicySummaryCollect,
              l10n.privacyPolicySummaryNoSell,
              l10n.privacyPolicySummaryAi,
              l10n.privacyPolicySummaryControl,
              l10n.privacyPolicySummaryAds,
              l10n.privacyPolicySummaryEu,
            ],
          ),
        ],
      ),
    );
  }
}
