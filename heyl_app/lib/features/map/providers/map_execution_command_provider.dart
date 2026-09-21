import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/map_query.dart';
import '../utils/map_highlight_geometry.dart' show LatLngBounds;

/// PROD-3498 — a one-shot request from the search executor to the map screen.
///
/// The executor is a plain Riverpod object: it owns *what* should happen when a
/// suggestion is selected, and is unit-testable because of that. But three of
/// the five outcomes need things only the screen has — the imperative camera
/// (`_easeCameraTo` + its token), the map box size, and a `BuildContext` to put
/// a detail sheet up. So the executor writes a command here and
/// `map_screen.dart` listens and performs it.
///
/// This is the same request-provider shape the page already uses for
/// `mapCarouselFocusRequestProvider` and `mapPromotedPinProvider`; it is *not*
/// a second camera authority. The screen remains the only thing that moves the
/// camera.
@immutable
sealed class MapExecutionCommand {
  const MapExecutionCommand(this.token);

  /// Monotonic — two identical commands in a row must still both run (the same
  /// reason `_centerToToken` exists; value-diffing silently drops a repeat, see
  /// `docs/learnings/mapbox-imperative-tokens-fit-vs-center.md`).
  final int token;
}

/// Fly/ease the camera to a point at [zoom].
class MapEaseToCommand extends MapExecutionCommand {
  const MapEaseToCommand({
    required int token,
    required this.lat,
    required this.lng,
    required this.zoom,
  }) : super(token);

  final double lat;
  final double lng;
  final double zoom;
}

/// Frame a geographic box (a resolved area's bbox). The screen computes the
/// camera with `fitCameraForBox` — this page must never hand a bbox to the
/// renderers' `boundsConfig` (see that helper's doc).
class MapFitBoxCommand extends MapExecutionCommand {
  const MapFitBoxCommand({required int token, required this.box})
    : super(token);

  final LatLngBounds box;
}

/// Open a venue detail sheet without moving the camera (Decision #18's
/// no-usable-coordinates fallback).
class MapOpenVenueSheetCommand extends MapExecutionCommand {
  const MapOpenVenueSheetCommand({required int token, required this.venueId})
    : super(token);

  final String venueId;
}

/// Open an event detail sheet without moving the camera. [eventId] is the
/// canonical id — never an occurrence id.
class MapOpenEventSheetCommand extends MapExecutionCommand {
  const MapOpenEventSheetCommand({required int token, required this.eventId})
    : super(token);

  final String eventId;
}

/// The pending command, or null once consumed. autoDispose so it resets with
/// the rest of the Map page's per-visit state.
final mapExecutionCommandProvider =
    StateProvider.autoDispose<MapExecutionCommand?>((ref) => null);

/// PROD-3566 — the id of a list the map still owes a **fit-to-pins** framing,
/// or null.
///
/// Entering a list can't emit a [MapFitBoxCommand] the way a location pick
/// does: a resolved area arrives with its bbox, a list does not. Its footprint
/// is whatever `/map/pins` returns for `scope=list`, which is only known one
/// round-trip later. So the executor *claims* the fit here and `MapScreen`
/// performs it when that response lands, then clears the claim.
///
/// Holding the **list id** rather than a bool is what makes it safe: entering a
/// second list before the first resolved leaves one pending fit for the list
/// actually being shown, and a response for any other scope can't consume it.
///
/// ⚠️ **A holder must subscribe to this, or the claim evaporates.** It is
/// autoDispose (page-scoped, like the rest of this file), and the executor
/// only ever `read`s it — so with no listener Riverpod disposes it on the next
/// microtask and the claim is gone long before `/map/pins` answers, silently
/// costing every list its camera fit. `MapScreen` holds the subscription for
/// the page's lifetime; a test must stand in for it with
/// `container.listen(mapPendingListFitProvider, (_, _) {})`, the same way the
/// other page-scoped providers are kept alive.
final mapPendingListFitProvider = StateProvider.autoDispose<String?>(
  (ref) => null,
);

/// PROD-3566 — may a just-resolved `/map/pins` response act on the pending
/// fit claim?
///
/// Three things must all hold, and the third is the one that isn't obvious:
/// the response must belong to the fetch the **list entry itself** caused.
/// The claim survives a round-trip, and a lot can happen in one — the user
/// can pan, or run another search. Each of those writes the query and starts
/// its own fetch, which is still `scope=list` for the same list and would
/// therefore satisfy the first two checks; acting on it would yank the camera
/// back to the whole list and undo whatever the user just did. `setList`
/// stamps `'list'` and nothing else does, so the trigger is what ties the
/// claim to its own fetch.
bool shouldConsumeListFit({
  required String? pendingListId,
  required MapQuery query,
  required String lastTrigger,
}) =>
    pendingListId != null &&
    query.isListMode &&
    query.activeListId == pendingListId &&
    lastTrigger == 'list';
