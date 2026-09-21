import 'package:flutter/material.dart';

import '../../../l10n/generated/l10n.dart';
import 'legal_page_scaffold.dart';

/// Account Deletion page for Google Play Store compliance.
/// Explains how users can request account deletion and what data is affected.
class AccountDeletionScreen extends StatelessWidget {
  const AccountDeletionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return LegalPageScaffold(
      title: l10n.accountDeletionTitle,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LegalParagraph(l10n.accountDeletionIntro),

          // Section 1: How to Request Account Deletion
          LegalSectionTitle(l10n.accountDeletionSection1Title),
          LegalParagraph(l10n.accountDeletionSection1Intro),
          LegalNumberedList(items: [
            l10n.accountDeletionSection1Step1,
            l10n.accountDeletionSection1Step2,
            l10n.accountDeletionSection1Step3,
            l10n.accountDeletionSection1Step4,
          ]),
          LegalParagraph(l10n.accountDeletionSection1Alternative),
          LegalEmailLink(
            label: l10n.accountDeletionSection1EmailLabel,
            email: 'privacy@soko.fyi',
          ),

          // Section 2: Data That Will Be Deleted
          LegalSectionTitle(l10n.accountDeletionSection2Title),
          LegalParagraph(l10n.accountDeletionSection2Intro),
          LegalBulletList(items: [
            l10n.accountDeletionSection2ItemProfile,
            l10n.accountDeletionSection2ItemConversations,
            l10n.accountDeletionSection2ItemMemories,
            l10n.accountDeletionSection2ItemSaved,
            l10n.accountDeletionSection2ItemLists,
            l10n.accountDeletionSection2ItemLocation,
          ]),

          // Section 3: Data That May Be Retained
          LegalSectionTitle(l10n.accountDeletionSection3Title),
          LegalParagraph(l10n.accountDeletionSection3Intro),
          LegalBulletList(items: [
            l10n.accountDeletionSection3ItemAnonymized,
            l10n.accountDeletionSection3ItemLegal,
            l10n.accountDeletionSection3ItemBackups,
          ]),

          // Section 4: Retention Period
          LegalSectionTitle(l10n.accountDeletionSection4Title),
          LegalParagraph(l10n.accountDeletionSection4Content),

          // Section 5: What Happens After Deletion
          LegalSectionTitle(l10n.accountDeletionSection5Title),
          LegalBulletList(items: [
            l10n.accountDeletionSection5ItemAccess,
            l10n.accountDeletionSection5ItemRecovery,
            l10n.accountDeletionSection5ItemNewAccount,
          ]),

          // Section 6: Contact
          LegalSectionTitle(l10n.accountDeletionSection6Title),
          LegalParagraph(l10n.accountDeletionSection6Content),
          LegalEmailLink(
            label: l10n.accountDeletionSection6Privacy,
            email: 'privacy@soko.fyi',
          ),
        ],
      ),
    );
  }
}

/// A numbered list in legal content
class LegalNumberedList extends StatelessWidget {
  const LegalNumberedList({
    super.key,
    required this.items,
  });

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: items
            .asMap()
            .entries
            .map((entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 24,
                        child: Text(
                          '${entry.key + 1}.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          entry.value,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }
}
