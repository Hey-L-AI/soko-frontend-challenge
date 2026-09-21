import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/bottom_nav_provider.dart';
import 'app_feedback_area.dart';

/// Resolve the "this page" feedback area for the current surface.
///
/// The Create menu is a bottom sheet — it doesn't change the route — so
/// [areaForRoute] alone would still report the underlying page (e.g. Home).
/// Detect the open create menu explicitly so feedback opened over it is scoped
/// to `create` (PROD-2911 polish).
AppFeedbackArea resolveFeedbackArea(BuildContext context, WidgetRef ref) {
  if (ref.read(createMenuControllerProvider) != null) {
    return AppFeedbackArea.create;
  }
  return areaForRoute(GoRouterState.of(context).matchedLocation);
}
