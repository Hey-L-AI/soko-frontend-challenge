import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/page_layout.dart';
import '../../providers/bottom_nav_provider.dart';
// ignore: unused_import — referenced in doc comments below
import '../widgets/bottom_sheet/ds_sheet_shell.dart';

/// Shows a modal bottom sheet and hides the bottom navigation while it's open.
///
/// Wrapper around [showModalBottomSheet] that manages the
/// [bottomNavVisibleProvider] state to hide the floating bottom nav pill
/// when sheets are displayed.
///
/// **Wrap your content in [DSSheetShell]** to get the standard design-system
/// chrome (sokoPaper bg, top-radius 20, drag handle, soft shadow) and the
/// header/body/footer layout with a pinned sticky footer. The wrapper itself
/// stays passthrough — height, snap behavior, and content all live with the
/// caller.
///
/// Height patterns:
/// - **Sized to content** (default): let the shell's body size itself; the
///   shell caps at 92 % of viewport height.
/// - **Fixed height**: wrap the body in a `SizedBox(height: ...)`.
/// - **Draggable / snap points**: use [showDraggableSheetWithHiddenNav]
///   instead and pass the `scrollController` to your body.
///
/// Note: this used to wrap `showCupertinoModalBottomSheet` (modal_bottom_sheet
/// package) for iOS-style stacked sheets, but the package's stacking math
/// (10 % parent scale-back + opaque-black backdrop) didn't deliver the
/// "see the underlying page" transparency we wanted. Reverted to Material
/// `showModalBottomSheet`. Sheets that need to overlay a *parent* sheet
/// while still showing the underlying page should pop the parent first.
///
/// `useRootNavigator` defaults to **`true`** so sheets always mount on the
/// app's root Overlay. The shell ([DiscoveryShell]) uses a nested Navigator
/// inside the Scaffold body, which means with `false` a sheet would be
/// bounded to the body's render box — and the body excludes the
/// `bottomNavigationBar` slot. Combined with the 250 ms `AnimatedSize` that
/// collapses the nav, the sheet's bottom edge ends up floating ~60 px
/// above the viewport bottom (PROD-1860). `true` bypasses that entirely.
///
/// Example:
/// ```dart
/// await showBottomSheetWithHiddenNav(
///   context: context,
///   ref: ref,
///   builder: (context) => DSSheetShell(
///     header: const _Title('Save'),
///     body: ListView(...),
///     footer: _SaveButton(),
///   ),
/// );
/// ```
Future<T?> showBottomSheetWithHiddenNav<T>({
  required BuildContext context,
  required WidgetRef ref,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  Color? backgroundColor = Colors.transparent,
  // Soko/Ink 30 % scrim (PROD-1866). Override per-call when a sheet
  // needs the legacy black54 (e.g. above a media surface).
  Color? barrierColor = AppColors.sokoInkSecondary,
  ShapeBorder? shape,
  bool useRootNavigator = true,
  bool isDismissible = true,
  bool enableDrag = true,
  RouteSettings? routeSettings,
  AnimationController? transitionAnimationController,
  Offset? anchorPoint,
  bool useSafeArea = false,
}) async {
  // Hide bottom nav before showing sheet.
  // Capture the notifier so the finally block can restore visibility even if
  // the calling widget's context is no longer mounted (e.g. Daily Drop overlay
  // that pops before the sheet closes — PROD-801).
  final navNotifier = ref.read(bottomNavVisibleProvider.notifier);
  navNotifier.state = false;

  try {
    final result = await showModalBottomSheet<T>(
      context: context,
      builder: builder,
      isScrollControlled: isScrollControlled,
      // Cap to the app's content column and centre on desktop, so sheets line
      // up with the 480px page body instead of spanning the full viewport. A
      // no-op on phones (screen ≤ 480 → the constraint never binds).
      constraints: const BoxConstraints(
        maxWidth: PageLayout.desktopContentMaxWidth,
      ),
      backgroundColor: backgroundColor,
      barrierColor: barrierColor,
      shape: shape,
      useRootNavigator: useRootNavigator,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      routeSettings: routeSettings,
      transitionAnimationController: transitionAnimationController,
      anchorPoint: anchorPoint,
      useSafeArea: useSafeArea,
    );
    return result;
  } finally {
    // Always restore bottom nav when sheet closes (even if dismissed by gesture).
    // The notifier is app-scoped so it remains valid after widget disposal.
    navNotifier.state = true;
  }
}

/// Shows a draggable scrollable bottom sheet with hidden bottom navigation.
///
/// This is a convenience wrapper that combines [showBottomSheetWithHiddenNav]
/// with [DraggableScrollableSheet] for sheets that need drag-to-resize.
///
/// Example:
/// ```dart
/// await showDraggableSheetWithHiddenNav(
///   context: context,
///   ref: ref,
///   initialChildSize: 0.6,
///   builder: (context, scrollController) => MySheet(
///     scrollController: scrollController,
///   ),
/// );
/// ```
Future<T?> showDraggableSheetWithHiddenNav<T>({
  required BuildContext context,
  required WidgetRef ref,
  required Widget Function(BuildContext, ScrollController) builder,
  double initialChildSize = 0.5,
  double minChildSize = 0.25,
  double maxChildSize = 0.95,
  bool expand = true,
  bool snap = false,
  List<double>? snapSizes,
  bool useRootNavigator = true,
  bool isDismissible = true,
  bool enableDrag = true,
  // Defaults to the standard 30 % Soko/Ink scrim. Pass `Colors.transparent`
  // for a peek sheet that must NOT dim the page behind it (PROD-3873).
  Color? barrierColor = AppColors.sokoInkSecondary,
  // Pass one in when the sheet body needs to drive its own extent (e.g. grow
  // itself when the user stages a change — PROD-3983).
  DraggableScrollableController? controller,
}) {
  return showBottomSheetWithHiddenNav<T>(
    context: context,
    ref: ref,
    barrierColor: barrierColor,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    builder: (context) => DraggableScrollableSheet(
      controller: controller,
      initialChildSize: initialChildSize,
      minChildSize: minChildSize,
      maxChildSize: maxChildSize,
      expand: expand,
      snap: snap,
      snapSizes: snapSizes,
      builder: builder,
    ),
  );
}
