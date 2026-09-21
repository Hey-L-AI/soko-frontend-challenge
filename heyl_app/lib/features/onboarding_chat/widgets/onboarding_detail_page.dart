import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/vibe_candidate.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../event_detail/providers/event_detail_provider.dart';
import '../../event_detail/widgets/event_detail_body.dart';
import '../../venue_detail/providers/venue_detail_provider.dart';
import '../../venue_detail/widgets/venue_detail_body.dart';

/// Full-screen, read-only ("sandbox") detail for an onboarding vibe card.
///
/// Pushed on the ROOT navigator (over the onboarding gate) so it presents as a
/// normal page with a back button and pops straight back to onboarding — while
/// the sandboxed body suppresses every external link / cross-screen nav.
class OnboardingDetailPage extends ConsumerWidget {
  const OnboardingDetailPage({
    super.key,
    required this.type,
    required this.entityId,
  });

  final VibeCandidateType type;
  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isEvent = type == VibeCandidateType.event;
    // Match the standalone detail-page surfaces (venue = blue, event = green).
    final bg = isEvent ? AppColors.sokoEvent : AppColors.sokoVenue;

    final Widget content = isEvent
        ? ref
              .watch(eventDetailProvider(EventDetailKey(eventId: entityId)))
              .when(
                data: (snapshot) => EventDetailBody(
                  snapshot: snapshot,
                  embedded: true,
                  sandbox: true,
                  // Full-screen sandbox page — a set 👍/👎 closes it back to
                  // the vibe carousel (which re-syncs the card's taste).
                  closeOnSignal: true,
                ),
                loading: () => const _Loading(),
                error: (_, __) =>
                    _Error(message: Lt.of(context).eventDetailErrorLoading),
              )
        : ref
              .watch(venueDetailProvider(VenueDetailKey(venueId: entityId)))
              .when(
                data: (snapshot) => VenueDetailBody(
                  snapshot: snapshot,
                  embedded: true,
                  sandbox: true,
                  // Full-screen sandbox page — a set 👍/👎 closes it back to
                  // the vibe carousel (which re-syncs the card's taste).
                  closeOnSignal: true,
                ),
                loading: () => const _Loading(),
                error: (_, __) =>
                    _Error(message: Lt.of(context).venueDetailErrorLoading),
              );

    return Scaffold(
      backgroundColor: bg,
      // No AppBar: the back button lives INSIDE the PageContent column (like
      // every other detail/list page) so on desktop it aligns with the centered
      // 480-px body instead of floating at the viewport's left edge. SafeArea
      // now owns the top inset the AppBar used to consume.
      body: SafeArea(
        child: PageContent(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
                child: Row(
                  children: [
                    SokoBackButton(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              Expanded(child: SingleChildScrollView(child: content)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 80),
    child: Center(child: CircularProgressIndicator(color: AppColors.sokoInk)),
  );
}

class _Error extends StatelessWidget {
  const _Error({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 60),
    child: Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: AppTheme.body(fontSize: 16, color: AppColors.sokoInk),
      ),
    ),
  );
}
