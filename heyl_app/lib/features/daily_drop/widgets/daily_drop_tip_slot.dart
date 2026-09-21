import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';

/// PROD-3950 — the **tip slot** on the Daily Drop detail page (element 4 of
/// the v1 structure).
///
/// The tip feature itself doesn't exist yet. This is its slot, and v1 fills it
/// with the drop's personalised recommendation `reason` — the rationale the
/// curation agent already writes and which, until now, had no surface: the
/// block built for it on venue/event detail (PROD-3232) was hard-paused from
/// the day it was written and never rendered anything; PROD-3952 deleted it.
///
/// **Why a slot and not just a reason block.** The real tip lands here as a
/// *content* swap, not a re-layout — so the page's vertical rhythm is settled
/// once, now, rather than shifting under users when the tip ships. That is also
/// why this takes the reason as a plain `String?` the page already holds in
/// memory, with no provider of its own: the drop is passed to the page as
/// GoRouter `extra`, so `drop.reason` is there on the first frame and the slot
/// paints with the rest of the above-the-fold content instead of popping in
/// after a fetch.
///
/// Collapses to nothing — its own top margin included — when there is no
/// reason, so the neighbouring rhythm closes up cleanly rather than leaving a
/// gap. The pink-card + `soko-ai-icon` treatment was lifted from the deleted
/// reason block deliberately: it is the established "this is Soko's reasoning"
/// language from the chat cards, and reusing it avoids inventing a third
/// visual for the same idea.
class DailyDropTipSlot extends StatelessWidget {
  /// The drop's `recommendation.reason`. Null/blank collapses the slot.
  final String? reason;

  const DailyDropTipSlot({super.key, required this.reason});

  @override
  Widget build(BuildContext context) {
    final text = reason?.trim() ?? '';
    if (text.isEmpty) return const SizedBox.shrink();

    final l10n = Lt.of(context);
    return Container(
      width: double.infinity,
      // Top margin lives inside the widget so the whole slot — spacing
      // included — collapses when there is no reason.
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.sokoPink,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // The asset is drawn in sokoPink — the card's own colour — so
              // untinted it vanishes and the heading reads as indented by 28px.
              // Tint to ink to match the heading text.
              Image.asset(
                'assets/images/soko-ai-icon.png',
                width: 20,
                height: 20,
                color: AppColors.sokoInk,
                filterQuality: FilterQuality.medium,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.dailyDropReasonHeading,
                  style: const TextStyle(
                    fontFamily: 'ZalandoSans',
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                    letterSpacing: -0.13,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontWeight: FontWeight.w300,
              fontSize: 14,
              height: 1.4,
              letterSpacing: -0.14,
              color: AppColors.sokoInk,
            ),
          ),
        ],
      ),
    );
  }
}
