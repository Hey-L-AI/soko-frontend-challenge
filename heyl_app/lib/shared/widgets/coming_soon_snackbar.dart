import 'package:flutter/material.dart';

import '../notifications/heyl_notification.dart';
import '../notifications/notification_state.dart';

/// Show a short floating "Coming soon" notification at the top of the
/// viewport. Delegates to the unified HeyL notification system
/// (`showSokoFromContext`) so it floats above every route,
/// dialog, and modal sheet.
///
/// Pass a localised string — callers are responsible for localisation.
void showComingSoonSnackBar(BuildContext context, String message) {
  showSokoFromContext(
    context,
    message: message,
    variant: SokoVariant.info,
    duration: const Duration(seconds: 3),
  );
}
