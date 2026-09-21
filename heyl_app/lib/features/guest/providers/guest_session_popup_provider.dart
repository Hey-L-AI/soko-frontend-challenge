import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks whether the PROD-2072 guest popup ("Find more on Soko") has
/// already been shown this session. Per-session only — cold reload resets
/// to `false` so the popup nudges every fresh visit.
///
/// `DiscoveryShell` reads this in `addPostFrameCallback` on every build:
/// when the shell mounts for a guest on web and the flag is still `false`,
/// the shell opens the popup once and immediately sets the flag to `true`
/// to suppress further triggers for the rest of the session.
final guestSessionPopupShownProvider = StateProvider<bool>((ref) => false);
