import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/auth_gating.dart';
import '../../../../data/models/models.dart';
import '../../../../providers/providers.dart';
import '../guest_list_gate_overlay.dart';
import 'list_view_item_row.dart';

/// PROD-1979 — guest cap rule. ≤ 2 items: show everything (a CTA over a
/// single blurred row reads as broken). ≥ 3: surface ⌈N/3⌉ rows and blur
/// the rest under a sign-in CTA.
int guestVisibleItemCount(int total) => total <= 2 ? total : (total / 3).ceil();

/// "Sítios" / "Eventos" section: header (Mobile/B1 Bold = 18 px, Soko/Ink)
/// followed by a column of [ListViewItemRow]s. Used by [ListViewModeBody]
/// per § 8.1 of `docs/designs/list-page-redesign.md`.
///
/// Two call shapes coexist:
/// - **Authenticated read mode** (PROD-1977): callers use
///   [buildListViewSectionSlivers] to emit slivers directly into the
///   shell's `CustomScrollView`. This is the viewport-culling path —
///   off-screen rows stay unbuilt.
/// - **Guest read mode + edit mode**: callers use this [ListViewSection]
///   widget which emits a `Column`. Guest mode needs the [GuestListGateOverlay]
///   blur around hidden items (PROD-1979) and is short by design, so
///   per-row culling isn't applicable. Edit mode uses a
///   `ReorderableListView.builder` upstream — same reason.
class ListViewSection extends ConsumerWidget {
  final String title;
  final List<UserListItem> items;
  final void Function(UserListItem item)? onItemTap;
  final void Function(UserListItem item)? onItemBookmarkTap;

  /// PROD-2785 — when supplied, each row renders a per-item share chip
  /// (`shareContext: 'list-item'`). Null hides the chip (legacy call
  /// sites that don't have a list id in scope).
  final String? listId;

  /// Optional control docked to the right of the section title — see
  /// [_sectionHeader]. Only the first rendered section is given one.
  final Widget? trailing;

  const ListViewSection({
    super.key,
    required this.title,
    required this.items,
    this.onItemTap,
    this.onItemBookmarkTap,
    this.listId,
    this.trailing,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) return const SizedBox.shrink();

    final isGuest = !ref.watch(isAuthenticatedProvider);
    final visibleCount = isGuest
        ? guestVisibleItemCount(items.length)
        : items.length;
    final visibleItems = items.take(visibleCount).toList();
    final hiddenItems = items.skip(visibleCount).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: _sectionHeader(title, trailing),
          ),
          // Non-sliver shape kept available for edit-mode and any other
          // caller that doesn't have a CustomScrollView host. The
          // viewport-culling path uses [buildListViewSectionSlivers].
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: visibleItems.length,
            itemBuilder: (context, i) => _buildRow(visibleItems[i], i),
          ),
          if (hiddenItems.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: GuestListGateOverlay(
                onSignIn: () => navigateToLoginPreservingReturn(
                  context,
                  ref,
                  referrer: AuthReferrer.guestListBlurCta,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < hiddenItems.length; i++)
                      _buildRow(hiddenItems[i], i),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRow(UserListItem item, int positionWithinGroup) => Padding(
    key: ValueKey('list-view-row-${item.id}'),
    padding: EdgeInsets.only(top: positionWithinGroup == 0 ? 0 : 6),
    child: RepaintBoundary(
      child: ListViewItemRow(
        item: item,
        listId: listId,
        onTap: onItemTap == null ? null : () => onItemTap!(item),
        onBookmarkTap: onItemBookmarkTap == null
            ? null
            : () => onItemBookmarkTap!(item),
      ),
    ),
  );
}

/// Section header: title left, optional control right.
///
/// The [trailing] slot exists so the sort chip can ride the FIRST section's
/// header instead of owning a full-width row above it. That row cost a whole
/// band of vertical space to hold one right-aligned chip, and on desktop the
/// emptiness beside it was the widest thing on the page.
Widget _sectionHeader(String title, Widget? trailing) {
  final label = Text(title, style: _kSectionTitleStyle);
  if (trailing == null) return label;
  return Row(
    children: [
      // Expanded, not Spacer: a long section title must ellipsize rather than
      // shove the control off the right edge.
      Expanded(child: label),
      trailing,
    ],
  );
}

const TextStyle _kSectionTitleStyle = TextStyle(
  // Mobile/B1 Bold per design tokens: Zalando Sans Medium, 18 px,
  // line-height 1, letterSpacing -0.36 px.
  fontSize: 18,
  fontWeight: FontWeight.w500,
  height: 1.0,
  letterSpacing: -0.36,
  color: AppColors.sokoInk,
);

/// PROD-1977: sliver-emitting counterpart of [ListViewSection], used by
/// `ListViewModeBody.buildSlivers` to participate in the shell's
/// viewport culling. Emits a [SliverPadding]-wrapped header followed by
/// a [SliverPadding]-wrapped `SliverList.builder` — off-screen rows are
/// never instantiated.
///
/// Returns an empty list when [items] is empty so callers can splice the
/// result directly into a sliver array with no conditional wrapping.
List<Widget> buildListViewSectionSlivers({
  required String title,
  required List<UserListItem> items,
  void Function(UserListItem item)? onItemTap,
  void Function(UserListItem item)? onItemBookmarkTap,
  // PROD-2785 — see [ListViewSection.listId].
  String? listId,
  // See [ListViewSection.trailing].
  Widget? trailing,
}) {
  if (items.isEmpty) return const <Widget>[];
  return [
    SliverPadding(
      padding: const EdgeInsets.only(left: 15, right: 15, bottom: 20),
      sliver: SliverToBoxAdapter(child: _sectionHeader(title, trailing)),
    ),
    SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 15),
      sliver: SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          return Padding(
            key: ValueKey('list-view-row-${item.id}'),
            padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
            child: RepaintBoundary(
              child: ListViewItemRow(
                item: item,
                listId: listId,
                onTap: onItemTap == null ? null : () => onItemTap(item),
                onBookmarkTap: onItemBookmarkTap == null
                    ? null
                    : () => onItemBookmarkTap(item),
              ),
            ),
          );
        },
      ),
    ),
  ];
}
