import '../../../data/models/user_list.dart';

/// Whether removing an item from a single [list] cascades — i.e. unsaves the
/// entity from EVERY list the owner holds it in, not just this one.
///
/// Mirrors the backend `cascades_on_removal` predicate (heyl-backend #2521): a
/// removal cascades only when it leaves one of the owner's AUTO-FILED save
/// lists — Saved Items / My Places / My Events (`isSavedCollection`). Removing
/// from a user-created zine (`system_kind: null`) or an auto-populated
/// collection removes just that row and leaves the save standing.
bool listRemovalCascades(UserList list) => list.isSavedCollection;

/// Whether committing a removal of [removedListIds] cascades, given the full set
/// of [containingLists] the entity currently sits in. True iff at least one
/// removed list is an auto-filed save list (see [listRemovalCascades]).
///
/// Drives both the cascade flag passed to the removal API and whether to show
/// the cascade-unsave confirmation.
bool removalCascades({
  required Iterable<UserList> containingLists,
  required Iterable<String> removedListIds,
}) {
  final cascadingIds = containingLists
      .where(listRemovalCascades)
      .map((l) => l.id)
      .toSet();
  return removedListIds.any(cascadingIds.contains);
}

/// The cascade-unsave confirmation decision for a committed removal.
///
/// - [cascades]: passed to the removal API as its `cascade` flag.
/// - [zineNamesToConfirm]: the user's curated zines the cascade will ALSO clear.
///   Non-empty ONLY when the removal cascades AND at least one zine is affected
///   — that is exactly when a confirmation dialog should be shown, naming these.
///   Empty means "remove silently" (a zine-only removal, or a cascade that
///   touches no curated zine — an item only in the auto save lists).
({bool cascades, List<String> zineNamesToConfirm}) unsaveConfirmDecision({
  required List<UserList> containingLists,
  required Iterable<String> removedListIds,
}) {
  final cascades = removalCascades(
    containingLists: containingLists,
    removedListIds: removedListIds,
  );
  if (!cascades) return (cascades: false, zineNamesToConfirm: const []);
  // Curated zines the cascade clears — owned, not auto-managed. The auto save
  // lists are implied and never named (the user never hand-filed into them).
  final zineNames = containingLists
      .where((l) => l.isOwner && !l.isSystemManaged)
      .map((l) => l.name)
      .toList();
  return (cascades: true, zineNamesToConfirm: zineNames);
}
