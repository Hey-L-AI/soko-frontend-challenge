import '../../../data/models/geo_boundary.dart';
import '../../../data/models/resolved_search_location.dart';

/// Whether leaving the map should offer to promote its transient camera centre
/// to the canonical Search Center (C).
///
/// The backend boundary is the single gate: unresolvable positions and
/// micro-pans within C do not interrupt navigation. A city-level result that
/// names the same current city also remains silent, while moving into one of
/// that city's neighbourhoods deliberately counts as a meaningful narrowing.
bool shouldPromptToUpdateSearchCenter({
  required ResolvedSearchLocation searchCenter,
  required GeoBoundary? settledBoundary,
}) {
  if (!searchCenter.hasCenter || settledBoundary == null) return false;
  // The prompt must name both choices. A legacy or partially restored C can
  // retain coordinates without a display label; treat that as unresolvable
  // rather than presenting an empty "Keep" action.
  if (searchCenterPromptName(searchCenter).isEmpty) return false;
  if (searchCenter.boundaryId == settledBoundary.id) return false;

  // An area-selected C carries a stable identity. A different resolved
  // boundary is a real change even when both happen to have similar labels.
  if (searchCenter.boundaryId != null) return true;

  // City C → the same city boundary is not a move. City C → a neighbourhood
  // within it IS a useful narrowing and therefore prompts.
  if (settledBoundary.level == GeoBoundaryLevel.city &&
      _sameName(searchCenter.cityName, settledBoundary.name)) {
    return false;
  }

  return true;
}

/// What a fresh page-leave request should do, given the map page's leave state.
///
/// PROD-3674 — this exists to keep the two meanings of the page's
/// `_allowRoutePop` latch apart. The latch has to persist past the frame
/// (`PopScope.canPop` reads it, which is why `_completeLeave` arms it via
/// `setState` BEFORE navigating), but "the decision is made" must never be read
/// as "do nothing". A shell-level nav tap arrives with an `onComplete` closure
/// that IS the navigation; short-circuiting without calling it strands the user
/// on the map with every later tap dead, because the latch is never reset.
enum MapLeaveRequest {
  /// No decision made yet — run the full leave flow (boundary resolve,
  /// divergence check, prompt).
  run,

  /// A leave flow is already running. Swallow this request; it self-heals when
  /// the in-flight one completes, or on the next tap.
  ignore,

  /// The leave decision was already made for this visit. Do NOT prompt again —
  /// but the navigation still has to happen.
  navigateOnly,
}

/// [MapLeaveRequest] for the given state. In-flight wins over decided, which
/// preserves the original `_leaveInFlight || _allowRoutePop` precedence: a
/// request arriving mid-flow must not fire the pending navigation early.
MapLeaveRequest resolveMapLeaveRequest({
  required bool leaveInFlight,
  required bool leaveDecided,
}) {
  if (leaveInFlight) return MapLeaveRequest.ignore;
  if (leaveDecided) return MapLeaveRequest.navigateOnly;
  return MapLeaveRequest.run;
}

/// The current search-area name used in the leave prompt. Callers only show
/// the prompt when C has a centre, but keep this total for safe UI composition.
String searchCenterPromptName(ResolvedSearchLocation searchCenter) {
  final label = searchCenter.label?.trim();
  if (label?.isNotEmpty ?? false) return label!;
  return searchCenter.cityName?.trim() ?? '';
}

bool _sameName(String? a, String? b) =>
    a != null && b != null && a.trim().toLowerCase() == b.trim().toLowerCase();
