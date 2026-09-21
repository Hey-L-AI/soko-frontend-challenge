import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/environment.dart';
import '../../../core/services/experiment_service.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/utils/single_flight.dart';
import '../../map/screens/map_location_picker_screen.dart';
import '../models/search_scope.dart';
import 'location_scope_sheet.dart';

/// Opens the location-scope picker and returns the picked [SearchScope] (a
/// `SearchScopeArea`), or `null` if the user cancelled/dismissed.
///
/// Every location surface — the action-bar pill, add-to-list, contribution and
/// profiling — routes through here, so the picker choice is made in one place.
///
/// **Flag-gated rollout.** The redesigned map-based **bottom sheet**
/// ([LocationScopeSheet]) ships behind the admin-targeted PostHog flag
/// `location-scope-sheet` ([ExperimentState.enableLocationScopeSheet], or the
/// `LOCATION_SCOPE_SHEET` dart-define for local dev). While the flag is off,
/// everyone keeps the legacy full-screen [MapLocationPickerScreen]. Both return
/// the same `SearchScopeArea`, so callers are identical either way.
///
/// **Waits for [ExperimentState.flagsConfirmed] before branching.** This gate
/// runs once, on a tap, so it gets exactly one read — and [ExperimentState]
/// carries the PostHog **defaults** until the post-identify reload lands
/// (`loaded` flips true on that first default-valued pass, which is why it is
/// not the signal to use — PROD-3888 follow-up). Reading during that window
/// sent an admin to the legacy picker for that open, with no way to retry
/// short of closing and reopening. The wait is bounded and effectively free:
/// flags confirm within seconds of app start, long before a picker can be
/// reached, and a timeout falls back to the current state — i.e. exactly the
/// old behaviour.
/// Guards against a second tap opening a second picker.
///
/// Every path into the picker awaits before it shows anything — the callers in
/// `openSearchLocationPicker` await three futures, two of them network-backed,
/// and this function awaits flag confirmation. Without a latch, two taps inside
/// that window each open a picker and the second stacks on the first. Held for
/// the whole call, so it also covers the time the picker is on screen.
///
/// Deliberately module-level: only one picker can be open app-wide (it is a
/// modal sheet or a pushed full-screen route), so one latch is the correct
/// scope — a per-widget latch would let two different hosts each open one.
final _pickerFlight = SingleFlight();

Future<SearchScope?> showLocationScopePicker(
  BuildContext context,
  WidgetRef ref, {
  required SearchScope? currentScope,
}) => _pickerFlight.run(
  () => _showLocationScopePicker(context, ref, currentScope: currentScope),
);

Future<SearchScope?> _showLocationScopePicker(
  BuildContext context,
  WidgetRef ref, {
  required SearchScope? currentScope,
}) async {
  // Short-circuit first: the dart-define is a local-dev force and must not pay
  // for a wait, nor depend on PostHog being reachable at all.
  final useSheet =
      EnvironmentConfig.locationScopeSheetEnabled ||
      (await ref.read(experimentServiceProvider.notifier).whenFlagsConfirmed())
          .enableLocationScopeSheet;

  // The await above yields, so the caller's element may be gone (the sheet that
  // hosts the pill dismissed, the route popped) by the time we resume.
  if (!context.mounted) return null;

  if (useSheet) {
    // `enableDrag: false` stops a vertical map pan being read as a sheet drag;
    // the map owns all gestures.
    return showBottomSheetWithHiddenNav<SearchScope>(
      context: context,
      ref: ref,
      enableDrag: false,
      isDismissible: true,
      builder: (_) => LocationScopeSheet(initialScope: currentScope),
    );
  }

  return Navigator.of(context).push<SearchScope>(
    MaterialPageRoute(
      builder: (_) => MapLocationPickerScreen(initialScope: currentScope),
    ),
  );
}
