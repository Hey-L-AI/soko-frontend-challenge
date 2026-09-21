import '../../../data/models/user_list.dart';
import '../../config/environment.dart';
import 'auth_context.dart';
import 'list_analytics_props.dart';

/// Resolved list facts, preserving unknown metadata instead of UI defaults.
/// Relationship is relative to the identity captured before the request.
Map<String, dynamic> listOpenAnalyticsProps(
  UserList? list, {
  required AnalyticsActionContext viewer,
}) {
  final guest = viewer.authState == AnalyticsAuthState.loggedOut;
  final signedIn =
      viewer.authState == AnalyticsAuthState.loggedIn && viewer.userId != null;
  final ownerKnown = list != null && list.ownerId.isNotEmpty;
  final bool? ownerIsSelf = guest
      ? false
      : signedIn && ownerKnown
      ? list.ownerId == viewer.userId
      : null;
  var role = 'unknown';
  if (guest) {
    role = 'guest';
  } else if (ownerIsSelf == true) {
    role = 'owner';
  } else if (signedIn && list != null) {
    if (list.userRole == 'collaborator' || list.userRole == 'follower') {
      role = list.userRole!;
    } else if (ownerIsSelf == false &&
        list.userRole == null &&
        list.knownContextFields.contains('user_role')) {
      role = 'viewer';
    }
  }
  final handleKnown = list?.ownerHandle?.isNotEmpty == true;
  final kindKnown =
      list != null &&
      (list.systemKind != null ||
          list.knownContextFields.contains('system_kind'));
  final typeKnown = list?.knownContextFields.contains('visibility') == true;
  final labelsKnown =
      list != null &&
      (list.editorPick || list.knownContextFields.contains('editor_pick')) &&
      (list.cityGuide || list.knownContextFields.contains('city_guide')) &&
      (list.verified || list.knownContextFields.contains('verified'));
  final complete =
      ownerKnown &&
      ownerIsSelf != null &&
      handleKnown &&
      kindKnown &&
      typeKnown &&
      labelsKnown &&
      role != 'unknown';
  final hasFacts =
      ownerKnown || handleKnown || kindKnown || typeKnown || labelsKnown;
  return {
    if (ownerKnown) 'owner_id': list.ownerId,
    if (ownerIsSelf != null) 'owner_is_self': ownerIsSelf,
    if (handleKnown)
      'is_soko': list!.ownerHandle == EnvironmentConfig.sokoHandle,
    if (kindKnown) 'system_kind': list.systemKind ?? kSystemKindUserCreated,
    if (typeKnown) 'list_type': list!.visibility.name,
    if (labelsKnown)
      'curation_labels': [
        if (list.editorPick) 'editor_pick',
        if (list.cityGuide) 'city_guide',
        if (list.verified) 'verified',
      ],
    'list_role': role,
    'list_context_status': complete
        ? 'complete'
        : hasFacts
        ? 'partial'
        : 'unknown',
  };
}
