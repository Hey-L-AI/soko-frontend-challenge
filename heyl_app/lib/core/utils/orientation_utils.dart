import 'package:flutter/widgets.dart';

/// Utility class for handling orientation-aware layouts
/// Helps adapt UI elements for landscape vs portrait orientations
class OrientationUtils {
  /// Returns true if the device is in landscape orientation
  static bool isLandscape(BuildContext context) {
    return MediaQuery.of(context).orientation == Orientation.landscape;
  }

  /// Returns true if the device is in portrait orientation
  static bool isPortrait(BuildContext context) {
    return MediaQuery.of(context).orientation == Orientation.portrait;
  }

  /// Get safe top padding that accounts for landscape reduction
  /// In landscape, additional padding is reduced to preserve vertical space
  static double safeTop(BuildContext context, {double additionalPadding = 0}) {
    final mediaQuery = MediaQuery.of(context);
    final basePadding = mediaQuery.padding.top;

    if (isLandscape(context)) {
      // In landscape, reduce additional padding as vertical space is limited
      return basePadding + (additionalPadding * 0.5);
    }
    return basePadding + additionalPadding;
  }

  /// Get bottom nav clearance that accounts for landscape
  /// In landscape, the nav is smaller so less clearance is needed
  static double bottomNavClearance(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final basePadding = mediaQuery.padding.bottom;

    if (isLandscape(context)) {
      // In landscape, bottom nav is smaller
      return basePadding + 50;
    }
    return basePadding + 80; // Portrait with floating nav
  }

  /// Scale a fixed height for landscape orientation
  /// Reduces heights proportionally to fit limited vertical space
  static double responsiveHeight(
    BuildContext context,
    double portraitHeight, {
    double landscapeRatio = 0.6,
  }) {
    if (isLandscape(context)) {
      return portraitHeight * landscapeRatio;
    }
    return portraitHeight;
  }

  /// Get screen height minus safe areas
  /// Useful for calculating available content space
  static double availableHeight(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return mediaQuery.size.height -
        mediaQuery.padding.top -
        mediaQuery.padding.bottom;
  }

  /// Returns the appropriate bottom nav height based on orientation
  static double bottomNavHeight(BuildContext context) {
    if (isLandscape(context)) {
      return 48; // Compact nav in landscape
    }
    return 56; // Standard nav in portrait
  }
}
