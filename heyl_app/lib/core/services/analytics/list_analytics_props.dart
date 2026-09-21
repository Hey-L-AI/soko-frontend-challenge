import '../../../data/models/user_list.dart';
import '../../config/environment.dart';

/// `system_kind` value for an ordinary, user-made list (one with no system kind).
///
/// The model stores `null` for these, but we must NOT send null: the PostHog
/// destination drops null properties, which would make an ordinary list
/// indistinguishable from an event emitted before this enrichment shipped
/// (both would simply have no `system_kind`). An explicit sentinel keeps the
/// two apart, so a filter for "a real user Zine" can never match historical
/// events. See PROD-3095.
const String kSystemKindUserCreated = 'user_created';

/// Builds the shared analytics properties for the `list_*` events.
///
/// Single source of truth: the four list events are emitted from nine call
/// sites across two providers, so deriving these values at each site would
/// guarantee drift. Property names are shared with the backend notification
/// events (see PROD-3035 § "one shared property vocabulary") so a Klaviyo or
/// PostHog filter written once works across all of them.
///
/// [currentUserId] is needed for `owner_is_self`; when null that property is
/// reported as false.
///
/// Set [includeFollowerCount] for the follow/unfollow events, and
/// [includeRole] for the item add/remove events.
///
/// [listSizeAfter] is the authoritative item count AFTER the mutation, and is
/// deliberately **supplied by the caller** rather than read off `list.itemCount`.
/// `itemCount` does not mean the same thing everywhere: in `ListsNotifier` it is
/// the list's true total, but in `UnifiedListNotifier` the remove paths overwrite
/// it with the number of *loaded* items — and items load progressively (first page
/// of 50, then a background tail, PROD-1967). Reading it blindly there reported 49
/// for a 100-item list. Only the caller knows whether its count is a total or a
/// page, so only the caller can supply this. When null, `list_size_after` is
/// omitted — Growth thresholds notifications on this number, so a wrong value is
/// worse than none.
Map<String, dynamic> listAnalyticsProps(
  UserList list, {
  String? currentUserId,
  bool includeFollowerCount = false,
  int? listSizeAfter,
  bool includeRole = false,
}) {
  return {
    'owner_id': list.ownerId,
    if (list.ownerHandle != null) 'owner_handle': list.ownerHandle,
    'is_soko': list.ownerHandle == EnvironmentConfig.sokoHandle,
    'owner_is_self': currentUserId != null && list.ownerId == currentUserId,
    'system_kind': list.systemKind ?? kSystemKindUserCreated,
    // Reuses the property PostHog already uses for visibility on `list_create`
    // and the legacy `save_to_list` — one name for one concept.
    'list_type': list.visibility.name,
    'curation_labels': [
      if (list.editorPick) 'editor_pick',
      if (list.cityGuide) 'city_guide',
      if (list.verified) 'verified',
    ],
    if (includeFollowerCount) 'follower_count': list.followerCount,
    if (listSizeAfter != null) 'list_size_after': listSizeAfter,
    if (includeRole && list.userRole != null) 'list_role': list.userRole,
  };
}
