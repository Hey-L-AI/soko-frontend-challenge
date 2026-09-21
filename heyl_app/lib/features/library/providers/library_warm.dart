import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/auth_provider.dart';
import 'library_filter_provider.dart';

/// Builds the `/library` landing feed early so the first visit paints from
/// cache instead of a spinner.
///
/// One `read` is the whole warm. The provider's factory fires page 1 itself,
/// and `cacheFor` holds the result for [kLibraryFeedCacheTtl] with zero
/// listeners — so the page is still there when the user finally taps the tab.
///
/// No-op for guests: `GET /users/me/library` 401s, and the factory skips the
/// fetch while signed out. Safe to call twice — the second read hits the live
/// provider and sends nothing.
void warmLibraryLanding(WidgetRef ref) {
  if (!ref.read(isAuthenticatedProvider)) return;
  ref.read(libraryFeedProvider);
}
