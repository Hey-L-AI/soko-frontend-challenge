import 'package:flutter/widgets.dart';

/// Tracks whether any modal route (bottom sheet, dialog) is currently
/// on top of the app's navigation stack, so `SpotlightTrigger` can hold
/// back its 3-second pre-fire timer until the user is looking at a bare
/// screen again.
///
/// `showModalBottomSheet` (both directly and via
/// `showBottomSheetWithHiddenNav`) defaults to `useRootNavigator: true`
/// in this codebase, which pushes onto GoRouter's root Navigator. Wiring
/// this observer into `GoRouter.observers` catches those pushes.
///
/// Only `PopupRoute` pushes count — `ModalBottomSheetRoute` and
/// `DialogRoute` both extend `PopupRoute`. Regular GoRouter page
/// transitions are not popup routes and are ignored so navigating
/// between pages doesn't suppress the spotlight on the destination.
class SpotlightModalObserver extends NavigatorObserver {
  final ValueNotifier<int> activeModalCount = ValueNotifier<int>(0);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      activeModalCount.value = activeModalCount.value + 1;
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      final next = activeModalCount.value - 1;
      activeModalCount.value = next < 0 ? 0 : next;
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      final next = activeModalCount.value - 1;
      activeModalCount.value = next < 0 ? 0 : next;
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final oldWasPopup = oldRoute is PopupRoute;
    final newIsPopup = newRoute is PopupRoute;
    if (oldWasPopup && !newIsPopup) {
      final next = activeModalCount.value - 1;
      activeModalCount.value = next < 0 ? 0 : next;
    } else if (!oldWasPopup && newIsPopup) {
      activeModalCount.value = activeModalCount.value + 1;
    }
  }
}

/// Shared singleton — same instance used by the router and by every
/// `SpotlightTrigger`.
final SpotlightModalObserver spotlightModalObserver = SpotlightModalObserver();
