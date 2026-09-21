/// In-session membership staging for [AddToListSheet].
///
/// [selected] is what the chips show. [initial] is "was this item in the list
/// when the sheet opened?" so Save can diff adds vs removes.
///
/// PROD-4185 — async preselect (`contains_*`, optimistic auto-lists, local
/// cache) must not overwrite a tap that landed while that work was in flight.
/// [userToggled] records those taps; [applyKnownMembership] skips [selected]
/// for those IDs but still fills [initial] so Save still stages a removal.
class ListMembershipStaging {
  final Set<String> selected = {};
  final Set<String> initial = {};
  final Set<String> userToggled = {};

  /// Server/cache says [id] already contains the item.
  ///
  /// Always records [id] in [initial]. Ticks [selected] only when the user
  /// has not already expressed intent for that row.
  ///
  /// Returns true when [id] was newly added to [initial].
  bool applyKnownMembership(String id) {
    final wasNew = initial.add(id);
    if (!userToggled.contains(id)) {
      selected.add(id);
    }
    return wasNew;
  }

  /// Per-row (or cascade-group) chip tap.
  void toggleGroup({
    required bool wasSelected,
    required Iterable<String> group,
  }) {
    userToggled.addAll(group);
    if (wasSelected) {
      selected.removeAll(group);
    } else {
      selected.addAll(group);
    }
  }

  /// "Clear all" — every currently ticked row is a user decision.
  void clearAll() {
    if (selected.isEmpty) return;
    userToggled.addAll(selected);
    selected.clear();
  }

  /// New-item path: tick [defaultId] only when the user has not staged
  /// anything. Never writes [initial] — ticking default must count as an add.
  /// Skips system-managed defaults (removal-only on this sheet).
  void maybeSelectDefault(String? defaultId, {required bool isSystemManaged}) {
    if (selected.isNotEmpty || userToggled.isNotEmpty) return;
    if (defaultId == null || isSystemManaged) return;
    selected.add(defaultId);
  }

  List<String> get addedIds => selected.difference(initial).toList();

  List<String> get removedIds => initial.difference(selected).toList();
}
