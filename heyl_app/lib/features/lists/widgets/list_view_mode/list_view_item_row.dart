import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../data/models/models.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/lists_provider.dart' show isItemSavedProvider;
import '../../../../shared/widgets/clickable.dart';
import '../../../../shared/widgets/press_pop.dart';
import '../../../../shared/widgets/soko_card_image.dart';
import '../../../event_detail/utils/event_share.dart';
import '../../../share/widgets/soko_share_sheet.dart';
import '../../../venue_detail/utils/venue_share.dart';
import '../list_item_note.dart';

/// Compact row used by the new List view (mode 2) — § 8.1 of
/// `docs/designs/list-page-redesign.md`. 50×63 thumbnail, name, sub-line,
/// trailing 30×30 Bookmark chip.
///
/// When [editMode] is true (PROD-1783 page-level edit mode), the row
/// renders edit-mode affordances instead of the bookmark chip:
///   - a leading drag handle ([leadingDragHandle], passed by the parent
///     [ReorderableListView] so the row stays agnostic to its own index);
///   - a trailing red delete button wired to [onRemove];
///   - an auto-expanded [ListItemNote] below the row (when [listId] is
///     supplied), so owners can edit notes inline.
///
/// This is a deliberate fork of the legacy `ListItemRow`; only the
/// affordances we explicitly need are ported — there is no expand / cover-
/// badge / per-row editor-toggle here.
class ListViewItemRow extends StatelessWidget {
  final UserListItem item;
  final VoidCallback? onTap;
  final VoidCallback? onBookmarkTap;

  /// True when the host body is in page-level edit mode. Swaps the
  /// bookmark chip for the delete button, drops the row tap target, and
  /// reveals the inline note editor below the row.
  final bool editMode;

  /// Slot for a [ReorderableDragStartListener] painted before the row's
  /// thumbnail. The parent supplies it so the row doesn't have to know
  /// its own position inside the [ReorderableListView].
  final Widget? leadingDragHandle;

  /// Tap handler for the delete button shown in edit mode.
  final VoidCallback? onRemove;

  /// List id — required for the inline [ListItemNote] in edit mode.
  final String? listId;

  /// Whether the current user owns the list — gates the inline note
  /// editor's editable state.
  final bool isOwner;

  const ListViewItemRow({
    super.key,
    required this.item,
    this.onTap,
    this.onBookmarkTap,
    this.editMode = false,
    this.leadingDragHandle,
    this.onRemove,
    this.listId,
    this.isOwner = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final title = item.title ?? l10n.listDetailItemTitleFallback;
    final subtitle = _buildSubtitle(context);

    final rowContent = SizedBox(
      height: 63,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (editMode && leadingDragHandle != null) ...[
            SizedBox(
              width: 24,
              height: 63,
              child: Center(child: leadingDragHandle!),
            ),
            const SizedBox(width: 6),
          ],
          _Thumbnail(item: item),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: AppTheme.mobileB2Reg(color: AppColors.sokoShade4),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (editMode)
            _DeleteButton(onTap: onRemove)
          else ...[
            // PROD-2785 — per-item share. Gated on `listId` being
            // threaded (read-mode callers in `list_view_section.dart`
            // pass it; legacy callers that don't will simply omit the
            // chip).
            if (listId != null) ...[
              _ShareChip(item: item, listId: listId!),
              const SizedBox(width: 6),
            ],
            BookmarkChip(
              onTap: onBookmarkTap,
              eventId: item.eventId,
              venueId: item.venueId,
              googlePlaceId: item.googlePlaceId,
            ),
          ],
        ],
      ),
    );

    // In edit mode the row itself is no longer tap-navigable (clicks
    // belong to the drag handle / delete / note); outside edit mode the
    // row keeps its existing tap-to-open behaviour.
    final tappableRow = editMode
        ? rowContent
        : Clickable(onTap: onTap, child: rowContent);

    if (!editMode || listId == null) return tappableRow;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tappableRow,
        const SizedBox(height: 8),
        Padding(
          // Indent so the editor lines up with the row text (drag handle
          // 24 + 6 gap + thumb 50 + 10 gap = 90 px), keeping the
          // affordance visually attached to its row.
          padding: const EdgeInsets.only(left: 90, bottom: 8),
          child: ListItemNote(
            listId: listId!,
            listElementId: item.id,
            tip: item.tip,
            canEdit: isOwner,
            autoExpand: true,
            itemName: item.title,
          ),
        ),
      ],
    );
  }

  String _buildSubtitle(BuildContext context) {
    final parts = <String>[];

    if (item.itemType == SavedItemType.event) {
      final date = item.eventDate;
      if (date != null) {
        final locale = Localizations.localeOf(context).toString();
        parts.add(DateFormat('d MMM', locale).format(date));
      }
      final venueName = item.venueName;
      if (venueName != null && venueName.isNotEmpty) {
        parts.add(venueName);
      }
      if (item.city != null && item.city!.isNotEmpty) {
        parts.add(item.city!);
      }
    } else {
      // Place: prefer the LLM-curated `description_short` (matches Figma
      // `6197:5954` § Sítios — "Bar de vinhos naturais", "Pizzaria
      // artesanal"). Fall back to a sentence-cased Google Place category
      // (`korean_restaurant` → `Korean restaurant`) for legacy rows where
      // `description_short` hasn't been generated yet.
      final short = item.descriptionShort;
      final hasShort = short != null && short.trim().isNotEmpty;
      if (hasShort) {
        parts.add(short.trim());
      } else {
        final category = _prettyCategory(item.category);
        if (category != null) parts.add(category);
      }
      if (item.city != null && item.city!.isNotEmpty) {
        parts.add(item.city!);
      }
    }

    return parts.join(' · ');
  }

  /// Sentence-case fallback when `description_short` is missing — Google
  /// Place categories arrive as `snake_case` (e.g. `korean_restaurant`),
  /// so strip underscores and capitalize the first letter.
  static String? _prettyCategory(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final cleaned = raw.replaceAll('_', ' ').trim();
    if (cleaned.isEmpty) return null;
    return cleaned[0].toUpperCase() + cleaned.substring(1);
  }
}

/// 50×63 image, radius 2, over a type-aware brand floor + texture.
class _Thumbnail extends StatelessWidget {
  final UserListItem item;

  const _Thumbnail({required this.item});

  @override
  Widget build(BuildContext context) {
    return SokoCardImage(
      imageUrl: item.imageUrl,
      seed: item.venueId ?? item.eventId ?? item.id,
      kind: SokoEntityKind.fromSavedType(item.itemType),
      width: 50,
      height: 63,
      borderRadius: BorderRadius.circular(2),
    );
  }
}

/// Default-state bg for the chip pair — Soko/Ink @ 6 % per Figma's
/// design-system masters (`Frame9236` / `4032:4008` for bookmark,
/// `Frame9235` / `4032:3998` for plus-circle). The page-level instances
/// on `6197:5954` show 8 % alpha but that's a designer override on the
/// instance — the canonical chip chrome is 6 %, matching every other
/// 40 px / 30 px Soko/Ink chip in the codebase (header action buttons,
/// stats line, etc.).
final Color _chipDefaultBg = AppColors.sokoInk.withValues(alpha: 0.06);

/// Hover-state bg per Figma — Soko/Pink (`#FFB8CB`).
const Color _chipHoverBg = AppColors.sokoPink;

/// 30×30 circular Bookmark chip (Figma design-system component
/// `4032:4009`). Default = Soko/Ink @ 6 %; hover = Soko/Pink. Used on
/// item rows (§ 8.1 of `list-page-redesign.md`) and as the "save to one
/// of my lists" affordance on Sugerido rows (§ 8.3).
///
/// When ids are provided, the chip watches `isItemSavedProvider` and
/// swaps the outlined `LucideIcons.bookmark` glyph for `bookmark_check`
/// while the item is already in any of the viewer's owned lists
/// (PROD-2092). Tap behavior is unchanged so users can still open the
/// add-to-list sheet to manage memberships from a saved row. Watching
/// `isItemSavedProvider` instantiates `listsProvider`, whose creation
/// hook (`lists_provider.dart:1476-1479`) fires `loadAllOwnedItems()`
/// for authenticated users — so deep-linked entries to someone else's
/// zine hydrate the saved-cache without any extra plumbing.
class BookmarkChip extends ConsumerStatefulWidget {
  final VoidCallback? onTap;
  final String? eventId;
  final String? venueId;
  final String? googlePlaceId;

  const BookmarkChip({
    super.key,
    this.onTap,
    this.eventId,
    this.venueId,
    this.googlePlaceId,
  });

  @override
  ConsumerState<BookmarkChip> createState() => _BookmarkChipState();
}

class _BookmarkChipState extends ConsumerState<BookmarkChip> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isSaved = ref.watch(isItemSavedProvider)(
      eventId: widget.eventId,
      venueId: widget.venueId,
      googlePlaceId: widget.googlePlaceId,
    );
    return Semantics(
      label: isSaved ? l10n.listActionSaveItemSaved : l10n.listActionSaveItem,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Builder(
          builder: (context) {
            final circle = AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isHovered ? _chipHoverBg : _chipDefaultBg,
              ),
              child: Center(
                child: Icon(
                  isSaved ? LucideIcons.bookmark_check : LucideIcons.bookmark,
                  size: 14,
                  color: AppColors.sokoInk,
                ),
              ),
            );
            if (widget.onTap == null) return circle;
            // PressPop → same tap pop as the save/like/dislike controls.
            return PressPop(onTap: widget.onTap!, child: circle);
          },
        ),
      ),
    );
  }
}

/// 30×30 circular share chip (PROD-2785) — Soko/Ink @ 6 % bg, share
/// glyph. Opens the unified [SokoShareSheet] for the saved-item using
/// `shareContext: 'list-item'` + `entityId: item.id` (the saved-item
/// id, NOT the underlying event/venue id). `shareUrl` is the underlying
/// entity's webapp URL with the list id appended.
class _ShareChip extends ConsumerWidget {
  final UserListItem item;
  final String listId;

  const _ShareChip({required this.item, required this.listId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    return Semantics(
      label: l10n.listActionShare,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _handleShare(context, ref),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _chipDefaultBg,
            ),
            child: const Center(
              child: Icon(
                LucideIcons.share,
                size: 14,
                color: AppColors.sokoInk,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handleShare(BuildContext context, WidgetRef ref) {
    final String localUrl;
    if (item.itemType == SavedItemType.event && item.eventId != null) {
      localUrl = buildEventShareUrl(
        eventIdentifier: item.eventId!,
        listIdentifier: listId,
      );
    } else if (item.venueId != null) {
      localUrl = buildVenueShareUrl(
        venueIdentifier: item.venueId!,
        listIdentifier: listId,
      );
    } else {
      return;
    }

    // The entity is the list ITEM (not the underlying event/venue), which is
    // what preserves the in-zine framing for the recipient. The short,
    // previewable link is swapped in by showSokoShareSheet (PROD-4388).
    showSokoShareSheet(
      context: context,
      ref: ref,
      shareContext: 'list-item',
      entityId: item.id,
      shareUrl: localUrl,
    );
  }
}

/// 30×30 circular delete button used in edit mode (PROD-1783) — Soko/Ink
/// @ 6 % bg matching every other 30 px chip on the page, but with a red
/// trash glyph instead of the Bookmark mark so the affordance reads as
/// destructive without forcing the row into a separate visual rail.
class _DeleteButton extends StatelessWidget {
  final VoidCallback? onTap;

  const _DeleteButton({this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: Lt.of(context).listActionRemoveItem,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.sokoInk.withValues(alpha: 0.06),
            ),
            child: const Center(
              child: Icon(
                LucideIcons.trash_2,
                size: 14,
                color: AppColors.error,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 30×30 circular Plus-circle chip (Figma design-system component
/// `4032:3999`). Same chrome rules as [BookmarkChip] — default Soko/Ink
/// @ 6 %, hover Soko/Pink. Used on owner-side Sugerido rows (§ 8.3) as
/// "Add to this list".
///
/// [isSaved] dims the icon (not the bg) when the suggestion is already
/// in the list. The design system doesn't define a "saved/disabled"
/// state for plus-circle (only Default + Hover), so we keep the chrome
/// uniform with the bookmark sibling and signal disabled via icon alpha.
/// See [`docs/ui/design-decisions.md` § D77].
class PlusCircleChip extends StatefulWidget {
  final VoidCallback? onTap;

  final bool isSaved;

  const PlusCircleChip({super.key, this.onTap, this.isSaved = false});

  @override
  State<PlusCircleChip> createState() => _PlusCircleChipState();
}

class _PlusCircleChipState extends State<PlusCircleChip> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final iconColor = widget.isSaved
        ? AppColors.sokoInk.withValues(alpha: 0.3)
        : AppColors.sokoInk;

    return Semantics(
      label: Lt.of(context).listActionAdd,
      button: true,
      child: MouseRegion(
        cursor: widget.isSaved
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Builder(
          builder: (context) {
            final circle = AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (_isHovered && !widget.isSaved)
                    ? _chipHoverBg
                    : _chipDefaultBg,
              ),
              child: Center(
                child: Icon(
                  LucideIcons.circle_plus,
                  size: 14,
                  color: iconColor,
                ),
              ),
            );
            // Already-saved (or no action) is a passive/disabled state.
            if (widget.isSaved || widget.onTap == null) return circle;
            // PressPop → same tap pop as the save/like/dislike controls.
            return PressPop(onTap: widget.onTap!, child: circle);
          },
        ),
      ),
    );
  }
}
