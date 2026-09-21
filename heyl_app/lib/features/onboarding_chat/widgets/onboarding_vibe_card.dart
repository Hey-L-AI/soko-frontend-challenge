import 'package:flutter/material.dart';

import '../../../core/utils/event_timing_chip.dart';
import '../../../data/models/entity_signal.dart';
import '../../../data/models/vibe_candidate.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../../../shared/widgets/soko_entity_card.dart';

/// One thumbs-able card in the onboarding vibe carousels (Sítios / Eventos).
///
/// A thin adapter over the shared [SokoEntityCard] — it maps a [VibeCandidate]
/// to the shared card's primitive props so onboarding and the main chat render
/// the same portrait poster with 👍/👎.
class OnboardingVibeCard extends StatelessWidget {
  const OnboardingVibeCard({
    super.key,
    required this.candidate,
    required this.taste,
    required this.onLike,
    required this.onDislike,
    this.onTap,
    this.width = 105,
    this.imageHeight = 140,
    this.highlightLike = false,
  });

  final VibeCandidate candidate;
  final SignalTaste taste;
  final VoidCallback onLike;
  final VoidCallback onDislike;

  /// When true, the card's 👍 button breathes with a soft glow — the gated-step
  /// nudge. Set by the shelf for the one randomly-chosen, on-screen card.
  final bool highlightLike;

  /// Opens the candidate's (sandboxed) detail. The 👍/👎 buttons have their own
  /// gesture handlers, so they win taps within their bounds; a tap anywhere else
  /// on the card fires this.
  final VoidCallback? onTap;
  final double width;
  final double imageHeight;

  @override
  Widget build(BuildContext context) {
    return SokoEntityCard(
      name: candidate.name,
      subtitle: candidate.subtitle,
      imageUrl: candidate.imageUrl,
      seed: candidate.entityId,
      kind: candidate.type == VibeCandidateType.event
          ? SokoEntityKind.event
          : SokoEntityKind.venue,
      dateChip: candidate.type == VibeCandidateType.event
          ? chipForSingleStart(context, candidate.startsAt)
          : null,
      taste: taste,
      onLike: onLike,
      onDislike: onDislike,
      onTap: onTap,
      width: width,
      imageHeight: imageHeight,
      highlightLike: highlightLike,
    );
  }
}
