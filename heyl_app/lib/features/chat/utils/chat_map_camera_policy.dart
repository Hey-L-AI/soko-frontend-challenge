/// Default camera authority for chat maps when no recommendation card is
/// explicitly selected.
enum ChatMapCameraAuthority { searchCenter, resultBounds, fallback }

/// The conversation Search Center (C) is the camera authority whenever it is
/// available. Recommendation pins remain visible and tappable, but no longer
/// silently pull the camera back to historical results from another area.
ChatMapCameraAuthority chatMapCameraAuthority({
  required bool hasSearchCenter,
  required bool hasResults,
}) {
  if (hasSearchCenter) return ChatMapCameraAuthority.searchCenter;
  if (hasResults) return ChatMapCameraAuthority.resultBounds;
  return ChatMapCameraAuthority.fallback;
}
