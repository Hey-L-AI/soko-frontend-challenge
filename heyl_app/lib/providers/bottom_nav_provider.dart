import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provider to control bottom navigation visibility
/// Used to hide the nav when bottom sheets are open
final bottomNavVisibleProvider = StateProvider<bool>((ref) => true);

/// Holds the live [PersistentBottomSheetController] for the Create
/// menu (PROD-1952). Non-null means the sheet is currently mounted.
///
/// One source of truth across triggers (bottom nav's Criar button +
/// chat bar's "Add" pill + dismiss-overlay tap + nav-button auto-close):
/// every caller checks this value to decide whether to open or close,
/// and calling `.close()` on the controller drives the `.closed` future
/// that resets the provider back to null.
///
/// Consumers needing a plain bool can derive it:
/// `ref.watch(createMenuControllerProvider) != null`.
final createMenuControllerProvider =
    StateProvider<PersistentBottomSheetController?>((ref) => null);

/// Counter that increments each time the Lists tab is tapped.
/// Screens can listen to this to reset their state (e.g., clear filters).
final listsTabTapProvider = StateProvider<int>((ref) => 0);

/// Whether the Lists hub search scope is worldwide (true) or local (false).
/// Persists across filter navigation and list detail entry/exit.
final listsGlobalSearchProvider = StateProvider<bool>((ref) => false);
