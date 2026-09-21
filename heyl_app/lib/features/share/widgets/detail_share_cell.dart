import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/detail_action_button.dart';
import 'soko_share_sheet.dart';

/// The captioned **Partilha** cell of a detail-page action row (PROD-2939's
/// full-width `Guarda · Lembrete · Partilha · 👍 · 👎`).
///
/// PROD-3950 — extracted because the Daily Drop detail page needs this cell and
/// the only implementations were `_ShareIconButton`, private to
/// `venue_detail_body.dart` and duplicated in `event_detail_body.dart`. Both of
/// those bind the share params to their own snapshot type; this takes them
/// directly, which is what lets a third surface — one whose share target is a
/// *recommendation*, not the entity — reuse the same cell.
///
/// The cell is purely presentational plus the tap: deciding **what** is shared
/// stays with the caller, and on the drop page that decision is load-bearing.
/// An entity-backed drop must share the venue/event's own URL (attributed as
/// `daily-drop` + the recommendation id); only an entity-less drop shares
/// `externalUrl ?? /drop`. Sending `/drop` for an entity-backed drop would open
/// the *recipient's own* drop instead of the pick — which is why the URL is a
/// required parameter here rather than something this widget derives.
class DetailShareCell extends ConsumerWidget {
  /// Attribution bucket recorded on the share (`venue` / `event` /
  /// `daily-drop`).
  final String shareContext;

  /// The id [shareContext] refers to — the entity's uuid, or the recommendation
  /// id for a `daily-drop` share.
  final String entityId;

  /// The public URL actually sent. See the class doc: never derived here.
  ///
  /// PROD-4388 — this is the **fallback**. `showSokoShareSheet` swaps in the
  /// short, previewable link for `{shareContext, entityId}`, and falls back to
  /// this value when that lookup fails or runs long.
  final String shareUrl;

  const DetailShareCell({
    super.key,
    required this.shareContext,
    required this.entityId,
    required this.shareUrl,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DetailActionButton(
      label: Lt.of(context).detailActionShare,
      icon: SvgPicture.asset(
        'assets/images/icons/detail/send.svg',
        width: 26,
        height: 26,
        colorFilter: const ColorFilter.mode(AppColors.sokoInk, BlendMode.srcIn),
      ),
      onTap: () => showSokoShareSheet(
        context: context,
        ref: ref,
        shareContext: shareContext,
        entityId: entityId,
        shareUrl: shareUrl,
      ),
      popOnTap: true,
    );
  }
}
