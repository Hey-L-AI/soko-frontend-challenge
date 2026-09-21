import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/expert_badge.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/person_dot.dart';
import '../../../shared/widgets/dropdown/ds_dropdown_menu.dart';
import '../../discovery/utils/attribution_prefix.dart';
import '../../moderation/widgets/moderation_menu_button.dart';
import '../providers/current_zine_page_provider.dart';
import '../providers/unified_list_provider.dart';
import 'list_followers_inline.dart';
import 'list_visibility_toggle.dart';
import 'visibility_menu_chip.dart';
import 'system_list_badge.dart';
import 'zine_lista_toggle.dart';
import 'zine_reminder_bell_button.dart';

/// List-page metadata block — stats line (curator avatar + attribution +
/// page count + save count) and action row (Zine/Lista toggle + per-
/// variant actions). Mounted at the top of the list page body, AFTER
/// the shell-level `PinnedPageChrome` (back arrow + 42 px H1 list name)
/// — the chrome owns the title; this widget owns the metadata that
/// should scroll with the page.
///
/// **Action row variants:**
///   - Owner: Share + Edit
///   - Non-owner: Seguir (labelled Bt_Sq_Ico) + Share + Flag (Report/Block)
///
/// **Bell button is intentionally hidden on both variants in v1** (§ 7.1,
/// § 9.2 #1) — there is no BE flow for "subscribe to list updates" yet.
/// Re-add it when the BE surface lands.
class ListPageHeader extends StatelessWidget {
  final UnifiedListState state;
  final ValueChanged<ListViewMode> onModeChanged;
  final VoidCallback onShare;
  final VoidCallback onEdit; // owner only — "Editar zine" dropdown action
  final VoidCallback onAdd; // owner only — opens AddItemsToListSheet
  final ValueChanged<ListVisibility>
  onSetVisibility; // owner only — visibility menu chip (edit + non-edit)
  final VoidCallback onDelete; // owner only — dropdown action
  final VoidCallback onFollow; // non-owner only — Seguir + Bookmark share this
  // PROD-1953: weekly-bundle CTA — duplicates the auto-managed
  // `system_kind=weekly_bundle` list into a user-owned zine. Only
  // invoked from the `_ActionRow` variant that replaces Add/Share/Edit
  // for weekly_bundle lists.
  final VoidCallback onSaveAsOwnZine;

  const ListPageHeader({
    super.key,
    required this.state,
    required this.onModeChanged,
    required this.onShare,
    required this.onEdit,
    required this.onAdd,
    required this.onSetVisibility,
    required this.onDelete,
    required this.onFollow,
    required this.onSaveAsOwnZine,
  });

  @override
  Widget build(BuildContext context) {
    final list = state.list;
    final l10n = Lt.of(context);
    if (list == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 0, 15, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Owner-only public/private toggle. Visible in edit mode at
          // the top of the body, directly under the shell-level title —
          // pairs with the editable name above and the action-row's
          // collapse so visibility lives next to the other things the
          // owner is changing. In non-edit mode it collapses into a
          // read-only chip next to the Zine/Lista toggle (see
          // [_VisibilityChip] in [_ActionRow]).
          if (state.isOwner && state.editMode) ...[
            Center(
              child: ListVisibilityToggle(
                selected: list.visibility,
                enabled: true,
                onSelect: onSetVisibility,
              ),
            ),
            const SizedBox(height: 16),
          ],
          // PROD-1783: the system badge + stats line ("Por ti · N págs.
          // · save_count") are read-only metadata; hide them while the
          // page is in edit mode so the action row sits closer to the
          // (now-editable) title and the surface focuses on what the
          // owner can actually change.
          if (!state.editMode) ...[
            // Auto-managed badge — shown on any list the backend marks
            // via `system_kind` (IG share, onboarding seed, saved items,
            // weekly bundle, …). Sits above the stats so it reads as a
            // list-level attribute rather than a stat. PROD-1741 / 1953.
            if (list.isSystemManaged) ...[
              Center(
                child: SystemListBadge(
                  label: l10n.systemListBadgeAuto,
                  tooltip: l10n.systemListBadgeTooltip,
                  systemKind: list.systemKind,
                ),
              ),
              const SizedBox(height: 8),
            ],
            // Stats line — centred under the (shell-mounted) list name.
            _StatsLine(state: state, l10n: l10n, onBookmarkTap: onFollow),
            const SizedBox(height: 16),
          ],
          // ── Action row ────────────────────────────────────────────
          // PROD-1783: in edit mode the action row collapses entirely —
          // Done now lives in the pinned chrome (see [_DoneButton] in
          // `pinned_page_chrome.dart`) so it stays visible while the
          // user scrolls the editable body.
          if (!state.editMode)
            _ActionRow(
              isOwner: state.isOwner,
              isFollowing: state.isFollowing,
              currentMode: state.viewMode,
              currentVisibility: list.visibility,
              isSystemManaged: list.isSystemManaged,
              systemKind: list.systemKind,
              listId: list.id,
              authorUserId: list.ownerId,
              authorDisplayLabel: list.ownerName ?? list.ownerHandle,
              // Empty zines have nothing meaningful to share — hide the
              // share button until at least one item lands.
              hasItems: state.items.isNotEmpty,
              onModeChanged: onModeChanged,
              onShare: onShare,
              onEdit: onEdit,
              onAdd: onAdd,
              onSetVisibility: onSetVisibility,
              onDelete: onDelete,
              onFollow: onFollow,
              onSaveAsOwnZine: onSaveAsOwnZine,
            ),
        ],
      ),
    );
  }
}

class _StatsLine extends ConsumerWidget {
  final UnifiedListState state;
  final Lt l10n;
  final VoidCallback onBookmarkTap;

  const _StatsLine({
    required this.state,
    required this.l10n,
    required this.onBookmarkTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = state.list!;
    // Count items only — the cover isn't a "page" in the user-facing
    // sense (zero items = "0 pages", 3 items = "3 pages"). PROD-1955.
    final pageCount = state.items.length;

    // On someone else's zine, the curator (avatar + username, no @) links to
    // their social profile. Open to everyone now that public profiles are live
    // (was an admin-only rollout pilot, un-gated once the profile route shipped
    // to all users).
    final ownerHandle = list.ownerHandle;
    final canLinkProfile =
        !state.isOwner && ownerHandle != null && ownerHandle.isNotEmpty;

    final attributionText = state.isOwner
        ? l10n.discoveryShelfYoursAttribution
        : canLinkProfile
        // The curator's display NAME (matching the shelf cards' bolinha
        // cluster) — the bare username only when they have no name set.
        ? ((list.ownerName != null && list.ownerName!.isNotEmpty)
              ? list.ownerName!
              : ownerHandle)
        : '${attributionPrefixFor(l10n, list.ownerHandle)}'
                  '${list.ownerName ?? ''}'
              .trim();

    // Curator cluster (avatar + attribution). Tappable → profile for admins.
    // The 16 px "bolinha" shows the curator's photo, or their initial on
    // their seeded colour when they haven't uploaded one — same fallback as
    // the Discovery shelf cards.
    final hasDot =
        (list.ownerAvatarUrl?.isNotEmpty ?? false) ||
        ((list.ownerName ?? list.ownerHandle)?.isNotEmpty ?? false);
    Widget curator = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasDot) ...[
          PersonDot(
            url: list.ownerAvatarUrl,
            name: list.ownerName ?? list.ownerHandle,
            seed: list.ownerId,
            size: 16,
          ),
          const SizedBox(width: 6),
        ],
        Text(attributionText, style: _statsTextStyle),
        if (list.ownerIsExpert && !state.isOwner) ...[
          const SizedBox(width: 4),
          const ExpertBadge(compact: true),
        ],
      ],
    );
    if (canLinkProfile) {
      curator = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.push(AppRoutes.publicProfilePath(ownerHandle)),
          child: curator,
        ),
      );
    }

    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          curator,
          const _StatsDot(),
          Text(l10n.listPageStatsPages(pageCount), style: _statsTextStyle),
          // Follower count (next to the bookmark) hides at zero — "· 0" says
          // nothing and reads as noise on a fresh zine. Tapping it opens the
          // zine's followers list (public zines viewable by anyone).
          if (list.followerCount > 0) ...[
            const _StatsDot(),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => context.push(
                  AppRoutes.listFollowersPath(list.id),
                  extra: list.name,
                ),
                child: Text('${list.followerCount}', style: _statsTextStyle),
              ),
            ),
          ],
          // Bookmark icon — HIDDEN on owner's own list (§ 7.1: user can't
          // follow their own list). On non-owner it toggles list-follow.
          if (!state.isOwner) ...[
            const SizedBox(width: 6),
            _StatsBookmark(
              isFollowing: state.isFollowing,
              onTap: onBookmarkTap,
              semanticLabel: state.isFollowing
                  ? l10n.listActionSavedZine
                  : l10n.listActionSaveZine,
            ),
          ],
          // Non-owner followers cluster inline in the subtitle (Figma
          // `7660:28322` — "… 45 🔖 · [avatars] JJ +3 seguem"). Reuses the
          // below-card social-proof widget at a smaller avatar size + the
          // stats text style so it reads as part of the metadata run. Owner
          // keeps the followers cluster only below the card.
          if (!state.isOwner && list.followerCount > 0) ...[
            const _StatsDot(),
            ListFollowersInline(
              listId: list.id,
              listName: list.name,
              followerCount: list.followerCount,
              size: 16,
              textStyle: _statsTextStyle,
            ),
          ],
        ],
      ),
    );
  }
}

const _statsTextStyle = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w300,
  color: AppColors.sokoInk,
);

class _StatsDot extends StatelessWidget {
  const _StatsDot();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 6),
      child: Text('·', style: _statsTextStyle),
    );
  }
}

class _StatsBookmark extends StatelessWidget {
  final bool isFollowing;
  final VoidCallback onTap;
  final String semanticLabel;

  const _StatsBookmark({
    required this.isFollowing,
    required this.onTap,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(
              // Material filled bookmark (Icons.bookmark) when
              // following, Lucide outline (LucideIcons.bookmark)
              // when idle — matches the action-row Seguir button's
              // filled/outline pair so the page reads consistently.
              isFollowing ? Icons.bookmark : LucideIcons.bookmark,
              size: 16,
              color: AppColors.sokoInk,
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends ConsumerWidget {
  final bool isOwner;
  final bool isFollowing;
  final ListViewMode currentMode;
  final ListVisibility currentVisibility;
  final bool isSystemManaged;
  final String? systemKind;
  // PROD-2264 — list metadata used by the non-owner flag/moderation
  // popup (Report + Block). [authorUserId] is the list owner, used to
  // gate the Block menu item; [authorDisplayLabel] names the user
  // being blocked in the confirmation dialog.
  final String listId;
  final String? authorUserId;
  final String? authorDisplayLabel;
  final ValueChanged<ListViewMode> onModeChanged;
  final VoidCallback onShare;
  final VoidCallback onEdit;
  final VoidCallback onAdd;
  final ValueChanged<ListVisibility> onSetVisibility;
  final VoidCallback onDelete;
  final VoidCallback onFollow;
  final VoidCallback onSaveAsOwnZine;

  /// Whether the zine has at least one item. The share button is hidden
  /// when false — empty zines render a "Coro/Daily Drop"-style card with
  /// no meaningful content to share.
  final bool hasItems;

  const _ActionRow({
    required this.isOwner,
    required this.isFollowing,
    required this.currentMode,
    required this.currentVisibility,
    required this.isSystemManaged,
    required this.systemKind,
    required this.listId,
    required this.authorUserId,
    required this.authorDisplayLabel,
    required this.hasItems,
    required this.onModeChanged,
    required this.onShare,
    required this.onEdit,
    required this.onAdd,
    required this.onSetVisibility,
    required this.onDelete,
    required this.onFollow,
    required this.onSaveAsOwnZine,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);

    // PROD-1953: weekly-bundle lists are auto-managed mirrors of the
    // user's weekly recommendations. Add / Remove / Share / Edit don't
    // make sense (the BE rewrites the list each week from the cron),
    // so collapse the action row to a single "Save as my own zine" CTA
    // that lets the user fork the bundle into a real, editable zine.
    if (systemKind == 'weekly_bundle') {
      return Row(
        children: [
          ZineListaToggle(
            currentMode: currentMode,
            onModeChanged: onModeChanged,
          ),
          const Spacer(),
          BtSqIco(
            icon: LucideIcons.bookmark_plus,
            label: l10n.listActionSaveAsOwnZine,
            variant: BtSqIcoVariant.selected,
            onTap: onSaveAsOwnZine,
          ),
        ],
      );
    }

    // Contextual reminder bell (non-owner, zine mode only): show when the
    // foregrounded pager page is an upcoming event. The current page is
    // published to [currentZinePageItemProvider] by the zine view; only
    // watch it in the case that can render the bell so the owner header
    // doesn't rebuild on every page settle.
    final currentPageItem = (!isOwner && currentMode == ListViewMode.zine)
        ? ref.watch(currentZinePageItemProvider(listId))
        : null;
    final now = DateTime.now();
    final bellItem =
        (currentPageItem != null &&
            currentPageItem.itemType == SavedItemType.event &&
            (currentPageItem.eventId?.isNotEmpty ?? false) &&
            currentPageItem.eventDate != null &&
            !currentPageItem.eventDate!.isBefore(
              DateTime(now.year, now.month, now.day),
            ))
        ? currentPageItem
        : null;

    // The share affordance is hidden on the auto-filed typed lists
    // (PROD-3873) — private by contract, never shareable.
    final showShare =
        hasItems &&
        systemKind != 'saved_places' &&
        systemKind != 'saved_events';

    return Row(
      children: [
        ZineListaToggle(currentMode: currentMode, onModeChanged: onModeChanged),
        const Spacer(),
        // ── Right action cluster ─────────────────────────────────────
        // Owner:  [Público] [+ Add] [Share?] [edit-menu]
        // Viewer: [Seguir]  [Bell?] [Share?] [flag]
        if (isOwner) ...[
          // Owner public/private selector — flips straight between Public and
          // Private (animated) via [onSetVisibility]; optimistic update +
          // revert-on-error live in the screen handler.
          VisibilityMenuChip(
            visibility: currentVisibility,
            onSelect: onSetVisibility,
          ),
          const SizedBox(width: 8),
          // Owner-only "Adicionar" affordance (PROD-1783) — opens
          // [AddItemsToListSheet] as a bottom sheet over the list page.
          _HeaderActionButton(
            icon: LucideIcons.plus,
            onTap: onAdd,
            semanticLabel: l10n.listActionAdd,
          ),
          const SizedBox(width: 8),
        ] else ...[
          // Seguir / A seguir — Soko/Shade5 idle with the Lucide outline
          // bookmark; Soko/Pink (`selected`) with Material's filled bookmark
          // when following.
          BtSqIco(
            icon: isFollowing ? Icons.bookmark : LucideIcons.bookmark,
            label: isFollowing
                ? l10n.listActionSavedZine
                : l10n.listActionSaveZine,
            variant: isFollowing
                ? BtSqIcoVariant.selected
                : BtSqIcoVariant.shade5,
            onTap: onFollow,
          ),
          const SizedBox(width: 8),
          // Reminder bell — only for upcoming-event pages. Animates its width
          // + opacity in/out as the viewer pages onto / off an event so it
          // doesn't pop the row.
          _ReminderBellSlot(item: bellItem),
        ],
        if (showShare) ...[
          _HeaderActionButton(
            icon: LucideIcons.share,
            onTap: onShare,
            semanticLabel: l10n.listActionShare,
          ),
          const SizedBox(width: 8),
        ],
        if (isOwner)
          _OwnerEditMenu(
            isSystemManaged: isSystemManaged,
            onEdit: onEdit,
            onDelete: onDelete,
          )
        else
          // PROD-2264 — the flag chrome opens the moderation popup
          // (Report + Block). Same Soko/Shade5 chip visual as the share /
          // owner-edit triggers so the row reads as a single action group.
          Semantics(
            label: l10n.listActionReport,
            button: true,
            child: ModerationMenuButton(
              targetType: ReportTargetType.list,
              targetId: listId,
              authorUserId: authorUserId,
              authorDisplayLabel: authorDisplayLabel,
              child: const _HeaderActionButtonChrome(icon: LucideIcons.flag),
            ),
          ),
      ],
    );
  }
}

/// Animated in/out slot for the contextual reminder bell. Renders the bell +
/// its trailing 8 px gap when [item] is non-null (an upcoming event page),
/// and collapses to zero width otherwise — the width + opacity animate so the
/// bell slides in as the viewer pages onto an event and slides out again on
/// the cover / a venue page.
class _ReminderBellSlot extends StatelessWidget {
  final UserListItem? item;

  const _ReminderBellSlot({required this.item});

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => SizeTransition(
        axis: Axis.horizontal,
        axisAlignment: -1,
        sizeFactor: animation,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: item == null
          ? const SizedBox.shrink()
          : Padding(
              // Re-key on the event id so paging event→event still cross-fades
              // (and keeps the bell's own hydration on the right event).
              key: ValueKey(item.eventId),
              padding: const EdgeInsets.only(right: 8),
              child: ZineReminderBellButton(item: item),
            ),
    );
  }
}

enum _OwnerEditAction { editZine, delete }

/// Owner-only dropdown anchored to the pencil chrome on the right side of
/// the action row. Surfaces three Figma `6353:31749` items (Edit zine,
/// Make/unmake zine public, Delete). The popup primitive's right-side
/// auto-alignment (see `glassmorphic_popup_menu.dart:117-126`) snaps the
/// panel to the trigger's right edge, matching Figma.
///
/// Delete is hidden on any system-managed list (`list.isSystemManaged`)
/// — `listsProvider.deleteList()` short-circuits for these (PROD-1741,
/// extended in PROD-1953), so the UI should not present an action that
/// always fails.
class _OwnerEditMenu extends StatelessWidget {
  final bool isSystemManaged;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _OwnerEditMenu({
    required this.isSystemManaged,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    // Visibility is no longer a pencil-menu action — it moved to the
    // dedicated [VisibilityMenuChip], a tap-to-toggle Public↔Private chip.
    return DSDropdownMenu<_OwnerEditAction>(
      semanticLabel: l10n.listActionEditMenu,
      items: [
        DSDropdownMenuItem(
          value: _OwnerEditAction.editZine,
          icon: LucideIcons.pencil_line,
          label: l10n.listActionEditZine,
        ),
        if (!isSystemManaged)
          DSDropdownMenuItem(
            value: _OwnerEditAction.delete,
            icon: LucideIcons.trash_2,
            label: l10n.listActionDeleteList,
            destructive: true,
          ),
      ],
      onSelected: (value) {
        switch (value) {
          case _OwnerEditAction.editZine:
            onEdit();
          case _OwnerEditAction.delete:
            onDelete();
        }
      },
      // Frame 9222 — Icon/Edit (`square_pen`) on the trigger chrome,
      // matching the share button's glyph family.
      child: const _HeaderActionButtonChrome(icon: LucideIcons.square_pen),
    );
  }
}

/// 40×40 circular chrome only (no gesture handling) — used as the visual
/// child of a `DSDropdownMenu` trigger which owns its own gesture
/// detector. Mirrors [_HeaderActionButton]'s look minus the press-scale
/// animation (the popup menu doesn't expose tap-down for that).
class _HeaderActionButtonChrome extends StatelessWidget {
  final IconData icon;

  const _HeaderActionButtonChrome({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.sokoShade5,
      ),
      child: Center(child: Icon(icon, size: 14, color: AppColors.sokoInk)),
    );
  }
}

/// 40×40 circular header action button — Soko/Shade5 fill, 14 px icon.
/// Visual matches Figma frame 9221 (share) / 9222 (pencil) — a round
/// chip in Soko/Shade5 (#F1E5E6) with the design-system glyph centred.
/// Bg changed from Soko/Ink @ 6 % to Soko/Shade5 so the chrome reads
/// as a deliberate chip rather than a neutral surface.
class _HeaderActionButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String semanticLabel;

  const _HeaderActionButton({
    required this.icon,
    required this.onTap,
    required this.semanticLabel,
  });

  @override
  State<_HeaderActionButton> createState() => _HeaderActionButtonState();
}

class _HeaderActionButtonState extends State<_HeaderActionButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticLabel,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) {
            setState(() => _isPressed = false);
            widget.onTap();
          },
          onTapCancel: () => setState(() => _isPressed = false),
          child: AnimatedScale(
            scale: _isPressed ? 0.95 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sokoShade5,
              ),
              child: Center(
                child: Icon(widget.icon, size: 14, color: AppColors.sokoInk),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
