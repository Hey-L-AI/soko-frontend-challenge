// PROD-4005 — the feed's page content wrapper.
//
// The margin itself is `kSokoPageMargin`, promoted to `core/theme/page_layout.dart`
// in PROD-4101 so `SokoPinnedHeaderBlock` can share it (`shared/` cannot depend on
// a feature). The rationale for the number moved with it.
//
// **Why 15, and why it belongs here rather than in each widget.** Figma's feed
// frames (`7304-23416`, `7304-23430`, `7304-24495`) are all **400 px wide
// against a 430 px mobile viewport** — the 400 is the CONTENT column, and the
// missing 30 is this margin, 15 a side. Every element in those frames is laid
// out against x0…x400, so once the page supplies the margin no feed widget
// should add horizontal padding of its own.
//
// Before this existed the margin was spelled `16` inside four separate widgets
// and `0` in the scallop, so the rule read as "16 px, except the wavy line,
// which is full-bleed". Now there is one number and one place to change it.

import 'package:flutter/material.dart';

import '../../../../core/theme/page_layout.dart';

/// Vertical rhythm between the feed's chrome blocks — scallop → next element,
/// pinned bar → filter row, and chrome → page content. Figma `7304-23416`
/// (Zé, 2026-08-26).
const double kFeedPageBlockGap = 30;

/// [PageContent] plus the feed's horizontal page margin. Every sliver on the
/// feed page goes through this — including the pinned-header overlay, which is
/// not a sliver but has to line up with the content underneath it.
class FeedPageContent extends StatelessWidget {
  final Widget child;

  const FeedPageContent({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return PageContent(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kSokoPageMargin),
        child: child,
      ),
    );
  }
}
