import 'package:flutter/material.dart';

import '../../../l10n/generated/l10n.dart';
import 'legal_page_scaffold.dart';

/// Terms of Service screen implementing the legal content from the Lovable prototype.
class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return LegalPageScaffold(
      title: l10n.termsOfServiceTitle,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LegalMutedText(l10n.termsOfServiceLastUpdated),
          const SizedBox(height: 16),
          LegalParagraph(l10n.termsOfServiceIntro1),
          LegalParagraph(l10n.termsOfServiceIntro2),

          // Section 1: Company Information
          LegalSectionTitle(l10n.termsOfServiceSection1Title),
          LegalParagraph(
            '${l10n.termsOfServiceSection1Content1}\n'
            '${l10n.termsOfServiceSection1Content2}\n'
            '${l10n.termsOfServiceSection1Content3}',
          ),
          LegalEmailLink(
            label: l10n.termsOfServiceSection1Contact,
            email: 'legal@soko.fyi',
          ),

          // Section 2: Definitions
          LegalSectionTitle(l10n.termsOfServiceSection2Title),
          LegalDefinitionList(
            items: [
              (
                l10n.termsOfServiceSection2Service,
                l10n.termsOfServiceSection2ServiceDesc,
              ),
              (
                l10n.termsOfServiceSection2User,
                l10n.termsOfServiceSection2UserDesc,
              ),
              (
                l10n.termsOfServiceSection2UserContent,
                l10n.termsOfServiceSection2UserContentDesc,
              ),
              (
                l10n.termsOfServiceSection2ThirdParty,
                l10n.termsOfServiceSection2ThirdPartyDesc,
              ),
              (
                l10n.termsOfServiceSection2LocalContent,
                l10n.termsOfServiceSection2LocalContentDesc,
              ),
            ],
          ),

          // Section 3: Description of the Service
          LegalSectionTitle(l10n.termsOfServiceSection3Title),
          LegalParagraph(l10n.termsOfServiceSection3Intro),
          LegalParagraph(l10n.termsOfServiceSection3NotIntro),
          LegalBulletList(
            items: [
              l10n.termsOfServiceSection3NotBooking,
              l10n.termsOfServiceSection3NotMarketplace,
              l10n.termsOfServiceSection3NotEmergency,
              l10n.termsOfServiceSection3NotAdvisor,
            ],
          ),
          LegalParagraph(l10n.termsOfServiceSection3Informational),
          LegalParagraph(l10n.termsOfServiceSection3ThirdPartyAi),

          // Section 4: Eligibility
          LegalSectionTitle(l10n.termsOfServiceSection4Title),
          LegalParagraph(l10n.termsOfServiceSection4Content1),
          LegalParagraph(l10n.termsOfServiceSection4Content2),

          // Section 5: Access and Use
          LegalSectionTitle(l10n.termsOfServiceSection5Title),
          LegalParagraph(l10n.termsOfServiceSection5Content1),
          LegalParagraph(l10n.termsOfServiceSection5Content2),
          LegalParagraph(l10n.termsOfServiceSection5Content3),

          // Section 6: Acceptable Use
          LegalSectionTitle(l10n.termsOfServiceSection6Title),
          LegalParagraph(l10n.termsOfServiceSection6Intro),
          LegalBulletList(
            items: [
              l10n.termsOfServiceSection6ItemIllegal,
              l10n.termsOfServiceSection6ItemMinors,
              l10n.termsOfServiceSection6ItemViolence,
              l10n.termsOfServiceSection6ItemHarass,
              l10n.termsOfServiceSection6ItemJailbreak,
              l10n.termsOfServiceSection6ItemImpersonate,
            ],
          ),
          LegalParagraph(l10n.termsOfServiceSection6Violation),

          // PROD-2264 — Community Guidelines & EULA. Apple Guideline 1.2
          // requires the zero-tolerance language + 24h review SLA to be
          // surfaced inline. Slotted here so the section sits next to the
          // existing Acceptable Use rules.
          LegalSectionTitle(l10n.termsOfServiceCommunityGuidelinesTitle),
          LegalParagraph(l10n.termsOfServiceCommunityGuidelinesIntro),
          LegalParagraph(l10n.termsOfServiceCommunityGuidelinesProhibitedIntro),
          LegalBulletList(
            items: [
              l10n.termsOfServiceCommunityGuidelinesHate,
              l10n.termsOfServiceCommunityGuidelinesHarass,
              l10n.termsOfServiceCommunityGuidelinesExplicit,
              l10n.termsOfServiceCommunityGuidelinesViolence,
              l10n.termsOfServiceCommunityGuidelinesDoxxing,
              l10n.termsOfServiceCommunityGuidelinesSpam,
              l10n.termsOfServiceCommunityGuidelinesImpersonation,
            ],
          ),
          LegalParagraph(l10n.termsOfServiceCommunityGuidelinesEnforcement),
          LegalParagraph(l10n.termsOfServiceCommunityGuidelinesReporting),
          LegalParagraph(l10n.termsOfServiceCommunityGuidelinesReportHow),

          // Section 7: AI Limitations and No Guarantees
          LegalSectionTitle(l10n.termsOfServiceSection7Title),
          LegalParagraph(l10n.termsOfServiceSection7Intro),
          LegalParagraph(l10n.termsOfServiceSection7AgreeIntro),
          LegalBulletList(
            items: [
              l10n.termsOfServiceSection7AgreeJudgment,
              l10n.termsOfServiceSection7AgreeVerify,
              l10n.termsOfServiceSection7AgreeNoEmergency,
            ],
          ),
          LegalParagraph(l10n.termsOfServiceSection7NoGuarantee),

          // Section 8: Third-Party Recommendations
          LegalSectionTitle(l10n.termsOfServiceSection8Title),
          LegalParagraph(l10n.termsOfServiceSection8Content1),
          LegalParagraph(l10n.termsOfServiceSection8Content2),

          // Section 9: Personalization and Memory
          LegalSectionTitle(l10n.termsOfServiceSection9Title),
          LegalParagraph(l10n.termsOfServiceSection9Content1),
          LegalParagraph(l10n.termsOfServiceSection9Content2),

          // Section 10: Intellectual Property
          LegalSectionTitle(l10n.termsOfServiceSection10Title),
          LegalParagraph(l10n.termsOfServiceSection10Content1),
          LegalParagraph(l10n.termsOfServiceSection10Content2),

          // Section 11: User Content
          LegalSectionTitle(l10n.termsOfServiceSection11Title),
          LegalParagraph(l10n.termsOfServiceSection11Content1),
          LegalParagraph(l10n.termsOfServiceSection11Content2),

          // Section 12: Feedback
          LegalSectionTitle(l10n.termsOfServiceSection12Title),
          LegalParagraph(l10n.termsOfServiceSection12Content),

          // Section 13: Availability and Changes
          LegalSectionTitle(l10n.termsOfServiceSection13Title),
          LegalParagraph(l10n.termsOfServiceSection13Content1),
          LegalParagraph(l10n.termsOfServiceSection13Content2),

          // Section 14: Fees
          LegalSectionTitle(l10n.termsOfServiceSection14Title),
          LegalParagraph(l10n.termsOfServiceSection14Content1),
          LegalParagraph(l10n.termsOfServiceSection14Content2),

          // Section 15: Disclaimer
          LegalSectionTitle(l10n.termsOfServiceSection15Title),
          LegalParagraph(l10n.termsOfServiceSection15Content),

          // Section 16: Limitation of Liability
          LegalSectionTitle(l10n.termsOfServiceSection16Title),
          LegalParagraph(l10n.termsOfServiceSection16Content),

          // Section 17: Termination
          LegalSectionTitle(l10n.termsOfServiceSection17Title),
          LegalParagraph(l10n.termsOfServiceSection17Content1),
          LegalParagraph(l10n.termsOfServiceSection17Content2),

          // Section 18: Territorial Availability
          LegalSectionTitle(l10n.termsOfServiceSection18Title),
          LegalParagraph(l10n.termsOfServiceSection18Content),

          // Section 19: Language
          LegalSectionTitle(l10n.termsOfServiceSection19Title),
          LegalParagraph(l10n.termsOfServiceSection19Content),

          // Section 20: Governing Law
          LegalSectionTitle(l10n.termsOfServiceSection20Title),
          LegalParagraph(l10n.termsOfServiceSection20Content1),
          LegalParagraph(l10n.termsOfServiceSection20Content2),

          // Section 21: Contact
          LegalSectionTitle(l10n.termsOfServiceSection21Title),
          LegalEmailLink(
            label: l10n.termsOfServiceSection21Legal,
            email: 'legal@soko.fyi',
          ),
          LegalEmailLink(
            label: l10n.termsOfServiceSection21Privacy,
            email: 'privacy@soko.fyi',
          ),

          // Summary Section
          const LegalDivider(),
          LegalSectionTitle(l10n.termsOfServiceSummaryTitle),
          LegalBulletList(
            items: [
              l10n.termsOfServiceSummaryCompanion,
              l10n.termsOfServiceSummaryAge,
              l10n.termsOfServiceSummaryLawful,
              l10n.termsOfServiceSummaryVerify,
              l10n.termsOfServiceSummaryNoGuarantee,
              l10n.termsOfServiceSummaryDataRights,
            ],
          ),
        ],
      ),
    );
  }
}
