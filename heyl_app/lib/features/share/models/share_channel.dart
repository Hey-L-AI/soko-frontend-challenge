/// PROD-2785 — the channels the unified `SokoShareSheet` can hand off to.
///
/// v1 channels are {copyLink, whatsapp, instagramStory, more}. The `more`
/// channel falls through to the OS share sheet (UIActivityViewController on
/// iOS, ChooserIntent on Android) for everything we don't natively handle.
///
/// v2 will add `tiktokStory`, `whatsappStatus`, `x`, `facebookStory`. The
/// `Set` helpers below let the sheet hide unsupported channels per platform
/// without a switch-statement bloom.
enum ShareChannel {
  copyLink,
  whatsapp,
  instagramStory,

  /// Dedicated Instagram-story entry point (surface-level button that
  /// skips the channel picker). Behaves identically to [instagramStory]
  /// at the handoff layer — the enum split exists so PostHog can
  /// distinguish "picked IG from the sheet" vs "tapped the direct IG
  /// button on the surface" without an extra property filter.
  instagramStoryDirect,

  /// Save the BE-rendered share PNG to the user's device — photo
  /// library on iOS/Android, browser download on web. No outbound
  /// handoff.
  saveImage,
  more;

  /// Analytics-friendly stable string for PostHog `{channel: ...}` event
  /// props. Snake-case matches the existing `ShareMethod` constants in
  /// `unified_analytics_service.dart`.
  String get analyticsName => switch (this) {
    ShareChannel.copyLink => 'copy_link',
    ShareChannel.whatsapp => 'whatsapp',
    ShareChannel.instagramStory => 'instagram_story',
    ShareChannel.instagramStoryDirect => 'instagram_story_direct',
    ShareChannel.saveImage => 'save_image',
    ShareChannel.more => 'more',
  };
}
