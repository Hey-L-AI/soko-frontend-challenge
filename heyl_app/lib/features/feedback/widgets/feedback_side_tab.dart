import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/session_provider.dart';
import '../../../shared/providers/shell_stray_tap_provider.dart';
import '../feedback_area_resolver.dart';
import 'app_feedback_sheet.dart';

/// Always-there feedback affordance: a semi-transparent tab pinned to the
/// right edge of every shell page. Tapping it opens the app-wide feedback
/// sheet scoped to the current page (PROD-2911). (Shake-to-open is a
/// fast-follow.)
///
/// Returns a [Positioned], so add it directly to the shell's body `Stack`.
class FeedbackSideTab extends ConsumerWidget {
  const FeedbackSideTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final height = MediaQuery.sizeOf(context).height;

    return Positioned(
      right: 0,
      top: height * 0.4,
      child: Opacity(
        opacity: 0.62,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              // PROD-3627 — this tab floats above every page's own chrome, so
              // a page-local overlay cannot scrim it. If one is up, a tap here
              // is a stray tap: it DISMISSES and does nothing else. A second
              // tap opens feedback normally. Honour the return value — a
              // registration left behind by a disposed page reports false.
              final dismiss = ref.read(shellStrayTapDismissProvider);
              if (dismiss != null && dismiss()) return;
              final area = resolveFeedbackArea(context, ref);
              final sessionId = ref.read(activeSessionIdProvider);
              showAppFeedbackSheet(
                context,
                ref,
                currentArea: area,
                sessionId: sessionId,
              );
            },
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(10),
              bottomLeft: Radius.circular(10),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.sokoPink,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(10),
                  bottomLeft: Radius.circular(10),
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.sokoInk.withValues(alpha: 0.15),
                    blurRadius: 8,
                    offset: const Offset(-2, 0),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    LucideIcons.megaphone,
                    size: 14,
                    color: AppColors.sokoInk,
                  ),
                  const SizedBox(height: 6),
                  RotatedBox(
                    quarterTurns: 3,
                    child: Text(
                      l10n.appFeedbackTabLabel,
                      style: const TextStyle(
                        fontFamily: 'Zalando Sans',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                        color: AppColors.sokoInk,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
