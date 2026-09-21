import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../data/models/user_list.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bt_sq_ico.dart';

/// Icon for each visibility level — 🌍 Public · 👥 Followers · 🔒 Private.
IconData visibilityIcon(ListVisibility v) {
  switch (v) {
    case ListVisibility.public:
      return LucideIcons.globe;
    case ListVisibility.followers:
      return LucideIcons.users;
    case ListVisibility.private:
      return LucideIcons.lock;
  }
}

/// Localized short label for a visibility level.
String visibilityLabel(Lt l10n, ListVisibility v) {
  switch (v) {
    case ListVisibility.public:
      return l10n.listsVisibilityPublic;
    case ListVisibility.followers:
      return l10n.listsVisibilityFollowers;
    case ListVisibility.private:
      return l10n.listsVisibilityPrivate;
  }
}

/// Tap-to-toggle visibility selector for the owner's Zine Details screen
/// (Figma `Bt_Sq_Ico` `7660:28041`). A single light DS chip
/// ([BtSqIco] `normal`) showing the CURRENT state — 🔓 Público / 🔒 Privado —
/// that flips straight to the other option on tap (no menu, no chevron). The
/// icon + label cross-fade so the change reads as a state flip rather than a
/// silent relabel. Only Public↔Private is offered (Followers was retired —
/// public zines are gated by account privacy instead); the enum value is kept
/// for back-compat parsing but is never surfaced here.
///
/// [onSelect] receives the *target* visibility and drives the optimistic
/// update + revert-on-error in the screen handler, so a tap animates
/// immediately and rolls back if the PATCH fails.
class VisibilityMenuChip extends StatelessWidget {
  final ListVisibility visibility;
  final ValueChanged<ListVisibility> onSelect;

  const VisibilityMenuChip({
    super.key,
    required this.visibility,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isPublic = visibility == ListVisibility.public;
    // Anything not-public (private, or the retired followers value) toggles TO
    // public; public toggles to private.
    final next = isPublic ? ListVisibility.private : ListVisibility.public;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: BtSqIco(
        // Re-key on the state so the switcher animates the icon+label swap on
        // every toggle instead of mutating the chip in place.
        key: ValueKey(visibility),
        icon: isPublic ? LucideIcons.lock_open : LucideIcons.lock,
        label: visibilityLabel(l10n, visibility),
        variant: BtSqIcoVariant.normal,
        onTap: () => onSelect(next),
      ),
    );
  }
}
