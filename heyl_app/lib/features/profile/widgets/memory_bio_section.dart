import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../providers/public_profile_providers.dart';
import '../utils/profile_style.dart';

/// The LLM memory-bio prose, shown inside the "What you like" card (below the
/// taste chips). Privacy-gating is done server-side, so the text passed here is
/// already what this viewer is allowed to see — this widget just renders it.
///
/// There is deliberately no refresh/regenerate button — the bio updates itself
/// as the user's memory grows; forcing a reroll would feel gimmicky and cost
/// money. When a regenerated version is pending, the owner sees a separate
/// [MemoryBioPendingBanner].
class MemoryBioProse extends StatelessWidget {
  final String text;
  const MemoryBioProse({super.key, required this.text});

  /// Paragraphs, split on blank lines. The design sets the bio as a couple of
  /// short paragraphs with air between them; a single [Text] collapses that to
  /// one block whatever the source contains, because `\n\n` only costs a line
  /// break, not a paragraph gap.
  static List<String> paragraphs(String raw) => raw
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim())
      .where((p) => p.isNotEmpty)
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final parts = paragraphs(text);
    // Same ink as the rest of the profile/app body text (tabs, cards…), not a
    // muted grey.
    final style = Pt.b2.copyWith(height: 1.4, color: AppColors.sokoInk);
    if (parts.length <= 1) {
      return Text(parts.isEmpty ? text : parts.first, style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          Text(parts[i], style: style),
        ],
      ],
    );
  }
}

/// Owner-only "your bio evolved" banner (propose-not-overwrite): a freshly
/// regenerated bio awaiting the owner's acceptance. Accepting promotes it to the
/// public bio. Shown below the "What you like" content.
class MemoryBioPendingBanner extends ConsumerStatefulWidget {
  final String handle;
  final String pending;
  const MemoryBioPendingBanner({
    super.key,
    required this.handle,
    required this.pending,
  });

  @override
  ConsumerState<MemoryBioPendingBanner> createState() =>
      _MemoryBioPendingBannerState();
}

class _MemoryBioPendingBannerState
    extends ConsumerState<MemoryBioPendingBanner> {
  bool _busy = false;

  Future<void> _accept() => _run((api) => api.acceptMemoryBio());

  Future<void> _reject() => _run((api) => api.rejectMemoryBio());

  Future<void> _run(Future<void> Function(dynamic api) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final l10n = Lt.of(context);
    try {
      await action(ref.read(socialProfileApiProvider));
      ref.invalidate(publicProfileProvider(widget.handle));
    } catch (_) {
      if (mounted) {
        showSoko(
          ref,
          message: l10n.memoryBioActionError,
          variant: SokoVariant.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        // Same lilac tokens as the "conta-nos sobre ti" entry point on the
        // Memory page (fill @22%, hairline @40%) so the two memory-authoring
        // surfaces read as one family.
        color: AppColors.sokoLilac.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.sokoLilac.withValues(alpha: 0.40)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                LucideIcons.sparkles,
                size: 18,
                color: AppColors.sokoInk,
              ),
              const SizedBox(width: 8),
              // b1Bold (18) rather than b2Bold (14): the title has to out-rank
              // the proposed-bio prose it sits above, which is b2.
              Expanded(
                child: Text(l10n.memoryBioPendingTitle, style: Pt.b1Bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(widget.pending, style: Pt.b2.copyWith(height: 1.35)),
          const SizedBox(height: 10),
          // Canonical DS pair (Bt_Sq_Ico): quiet outlined "keep", filled lilac
          // "use this one" — same shape/height as every other confirm row.
          IgnorePointer(
            ignoring: _busy,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Keep the current bio, discarding the proposed version.
                Opacity(
                  opacity: _busy ? 0.4 : 1,
                  child: BtSqIco(
                    icon: null,
                    label: l10n.memoryBioKeep,
                    variant: BtSqIcoVariant.idle,
                    onTap: _reject,
                  ),
                ),
                const SizedBox(width: 8),
                // The spinner overlays the button so its width never shifts
                // mid-flight.
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(
                      opacity: _busy ? 0.4 : 1,
                      child: BtSqIco(
                        icon: null,
                        label: l10n.memoryBioAccept,
                        variant: BtSqIcoVariant.lilac,
                        onTap: _accept,
                      ),
                    ),
                    if (_busy)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.sokoInk,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
