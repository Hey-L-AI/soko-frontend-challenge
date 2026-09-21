// Models for the fake-door campaign framework.
//
// Wire shapes mirror:
//   GET  /api/v1/app/campaigns/active
//   GET  /api/v1/app/campaigns/{key}
//   POST /api/v1/app/campaigns/{key}/responses
//
// The backend is the source of truth for campaign content — all display
// strings in `content` arrive already personalized (merge tags resolved
// server-side). The client renders them verbatim; there is no client-side
// tag logic here.
//
// Every `fromJson` in this file is tolerant of unknown/missing enum wire
// values: unrecognized strings fall back to a safe default instead of
// throwing, so an older client never crashes when the backend ships a new
// button style / action / media type / body-block type.

// =============================================================================
// CAMPAIGN (top-level)
// =============================================================================

/// A single fake-door campaign, as returned by `GET /campaigns/active` (one
/// entry per active campaign) or `GET /campaigns/{key}` (one campaign).
class Campaign {
  /// Stable campaign identifier, e.g. `fake_door_pricing_v1`.
  final String key;

  /// Campaign template family (backend-owned taxonomy, e.g. `survey`,
  /// `announcement`). Opaque to the renderer — carried through for
  /// analytics.
  final String template;

  /// Presentation hint for how the campaign is surfaced: `sheet` (bottom
  /// sheet, the warm-up default), `fullscreen` (full-screen modal takeover),
  /// or `page` (routed page). Consumed by `presentCampaign` via
  /// `campaignSurfaceFromPresentation`; unknown/empty falls back to `sheet`.
  /// The `/campaign/:key` deep-link route always renders as a page
  /// regardless of this value.
  final String presentation;

  final CampaignContent content;

  /// Optional PostHog feature flag key gating this campaign's display.
  ///
  /// When present, the client only surfaces the campaign to a user for whom
  /// the flag reads truthy — the campaign's targeting lives in PostHog, not
  /// the backend eligibility check (which only handles active + not-yet-
  /// responded). Null/empty means no additional client-side gate: any user
  /// the backend already considers eligible sees it. See
  /// `CampaignNotifier.isFlagEligible` for the read + fail-closed semantics.
  final String? posthogFlagKey;

  /// The caller's own prior answer to this campaign, or null if unanswered.
  /// Populated only by the catalog read (`GET /campaigns`, `listCampaignsForUser`);
  /// always null on the warm-up `/active` and deep-link `/{key}` reads.
  final CampaignUserResponse? response;

  const Campaign({
    required this.key,
    required this.template,
    required this.presentation,
    required this.content,
    this.posthogFlagKey,
    this.response,
  });

  // TODO(PROD-2264): identity-field cast retained pending Phase 3
  // `requireString` helper (see docs/platform/error-handling-discipline.md).
  factory Campaign.fromJson(Map<String, dynamic> json) => Campaign(
    key:
        json['key']
            as String, // gstack:allow check-error-handling json-cast-string
    template: (json['template'] as String?) ?? '',
    presentation: (json['presentation'] as String?) ?? '',
    content: CampaignContent.fromJson(json['content'] as Map<String, dynamic>),
    posthogFlagKey: json['posthog_flag_key'] as String?,
    response: json['response'] is Map
        ? CampaignUserResponse.fromJson(
            Map<String, dynamic>.from(json['response'] as Map),
          )
        : null,
  );
}

/// The caller's own prior answer to a campaign (`CampaignUserResponseOut`).
/// Returned inside each item of the catalog read (`GET /campaigns`) so the
/// app can show a history entry / re-open an answered campaign.
class CampaignUserResponse {
  final String choice; // yes | no | dismissed
  final List<String>? selectedOptions;
  final String? freeText;
  final List<String>? path;
  final DateTime? respondedAt;

  const CampaignUserResponse({
    required this.choice,
    this.selectedOptions,
    this.freeText,
    this.path,
    this.respondedAt,
  });

  factory CampaignUserResponse.fromJson(Map<String, dynamic> json) {
    final rawResponded = json['responded_at'];
    return CampaignUserResponse(
      choice: (json['choice'] as String?) ?? '',
      selectedOptions: (json['selected_options'] as List?)
          ?.whereType<String>()
          .toList(growable: false),
      freeText: json['free_text'] as String?,
      path: (json['path'] as List?)?.whereType<String>().toList(
        growable: false,
      ),
      respondedAt: rawResponded is String
          ? DateTime.tryParse(rawResponded)
          : null,
    );
  }
}

/// `content` payload: a small state machine of screens keyed by
/// [screens]'s map key, starting at [entry].
class CampaignContent {
  final int version;

  /// Key into [screens] identifying the first screen to render.
  final String entry;

  final Map<String, CampaignScreen> screens;

  const CampaignContent({
    required this.version,
    required this.entry,
    required this.screens,
  });

  factory CampaignContent.fromJson(Map<String, dynamic> json) {
    final rawScreens = json['screens'];
    final screens = <String, CampaignScreen>{};
    if (rawScreens is Map) {
      rawScreens.forEach((key, value) {
        if (value is Map<String, dynamic>) {
          screens[key as String] = CampaignScreen.fromJson(value);
        } else if (value is Map) {
          screens[key as String] = CampaignScreen.fromJson(
            Map<String, dynamic>.from(value),
          );
        }
      });
    }
    return CampaignContent(
      version: (json['version'] as num?)?.toInt() ?? 1,
      entry: (json['entry'] as String?) ?? '',
      screens: screens,
    );
  }
}

/// One screen in a campaign's flow.
class CampaignScreen {
  final String title;
  final String? subtitle;
  final String? badge;
  final List<CampaignMedia> media;
  final List<CampaignBodyBlock> body;
  final List<CampaignOption> options;
  final CampaignFreeTextConfig? freeText;

  /// 1-3 buttons per the contract. The backend is expected to enforce the
  /// bound; the client does not truncate/pad.
  final List<CampaignButton> buttons;

  const CampaignScreen({
    required this.title,
    required this.media,
    required this.body,
    required this.options,
    required this.buttons,
    this.subtitle,
    this.badge,
    this.freeText,
  });

  factory CampaignScreen.fromJson(Map<String, dynamic> json) {
    return CampaignScreen(
      title: (json['title'] as String?) ?? '',
      subtitle: json['subtitle'] as String?,
      badge: json['badge'] as String?,
      media: (json['media'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((m) => CampaignMedia.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false),
      body: (json['body'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((b) => CampaignBodyBlock.fromJson(Map<String, dynamic>.from(b)))
          .toList(growable: false),
      options: (json['options'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((o) => CampaignOption.fromJson(Map<String, dynamic>.from(o)))
          .toList(growable: false),
      freeText: json['free_text'] is Map
          ? CampaignFreeTextConfig.fromJson(
              Map<String, dynamic>.from(json['free_text'] as Map),
            )
          : null,
      buttons: (json['buttons'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((b) => CampaignButton.fromJson(Map<String, dynamic>.from(b)))
          .toList(growable: false),
    );
  }
}

// =============================================================================
// MEDIA
// =============================================================================

enum CampaignMediaType {
  /// A plain image at a fixed URL.
  static_,

  /// A server-resolved dynamic image (e.g. personalized art). Today the
  /// backend already resolves this to a concrete `url` before the client
  /// sees it; when `url` is absent the client falls back to a placeholder
  /// rather than attempting any client-side resolution.
  dynamicImage,
}

CampaignMediaType _mediaTypeFromWire(String? raw) {
  switch (raw) {
    case 'dynamic_image':
      return CampaignMediaType.dynamicImage;
    case 'static':
    default:
      return CampaignMediaType.static_;
  }
}

/// One media item in a screen's carousel.
class CampaignMedia {
  final CampaignMediaType type;

  /// Present for `static` media, and for `dynamic_image` once the backend
  /// has resolved it. Null triggers a placeholder in the renderer.
  final String? url;
  final String? alt;

  /// `dynamic_image`-only fields, carried through for a future richer
  /// renderer. Unused by the foundation renderer.
  final String? layout;
  final String? subject;

  const CampaignMedia({
    required this.type,
    this.url,
    this.alt,
    this.layout,
    this.subject,
  });

  factory CampaignMedia.fromJson(Map<String, dynamic> json) => CampaignMedia(
    type: _mediaTypeFromWire(json['type'] as String?),
    url: json['url'] as String?,
    alt: json['alt'] as String?,
    layout: json['layout'] as String?,
    subject: json['subject'] as String?,
  );
}

// =============================================================================
// BODY BLOCKS
// =============================================================================

enum CampaignBodyBlockType { paragraph, bullet }

CampaignBodyBlockType _bodyBlockTypeFromWire(String? raw) {
  switch (raw) {
    case 'bullet':
      return CampaignBodyBlockType.bullet;
    case 'paragraph':
    default:
      return CampaignBodyBlockType.paragraph;
  }
}

/// One paragraph or bulleted line in a screen's body.
class CampaignBodyBlock {
  final CampaignBodyBlockType type;
  final String text;

  /// Optional icon glyph name for a bullet row. Opaque string — the
  /// renderer maps known values to a Lucide icon and falls back to a
  /// generic bullet dot otherwise.
  final String? icon;

  const CampaignBodyBlock({required this.type, required this.text, this.icon});

  factory CampaignBodyBlock.fromJson(Map<String, dynamic> json) =>
      CampaignBodyBlock(
        type: _bodyBlockTypeFromWire(json['type'] as String?),
        text: (json['text'] as String?) ?? '',
        icon: json['icon'] as String?,
      );
}

// =============================================================================
// OPTIONS (multi-select)
// =============================================================================

/// One selectable option card.
class CampaignOption {
  final String key;
  final String? icon;
  final String title;
  final String? description;

  const CampaignOption({
    required this.key,
    required this.title,
    this.icon,
    this.description,
  });

  factory CampaignOption.fromJson(Map<String, dynamic> json) => CampaignOption(
    key: (json['key'] as String?) ?? '',
    icon: json['icon'] as String?,
    title: (json['title'] as String?) ?? '',
    description: json['description'] as String?,
  );
}

// =============================================================================
// FREE TEXT
// =============================================================================

class CampaignFreeTextConfig {
  final bool enabled;
  final String? prompt;

  const CampaignFreeTextConfig({required this.enabled, this.prompt});

  factory CampaignFreeTextConfig.fromJson(Map<String, dynamic> json) =>
      CampaignFreeTextConfig(
        enabled: (json['enabled'] as bool?) ?? false,
        prompt: json['prompt'] as String?,
      );
}

// =============================================================================
// BUTTONS
// =============================================================================

enum CampaignButtonStyle { primary, secondary, ghost, danger }

CampaignButtonStyle _buttonStyleFromWire(String? raw) {
  switch (raw) {
    case 'primary':
      return CampaignButtonStyle.primary;
    case 'ghost':
      return CampaignButtonStyle.ghost;
    case 'danger':
      return CampaignButtonStyle.danger;
    case 'secondary':
    default:
      return CampaignButtonStyle.secondary;
  }
}

enum CampaignButtonAction { submit, goto, dismiss, external }

CampaignButtonAction _buttonActionFromWire(String? raw) {
  switch (raw) {
    case 'submit':
      return CampaignButtonAction.submit;
    case 'goto':
      return CampaignButtonAction.goto;
    case 'external':
      return CampaignButtonAction.external;
    case 'dismiss':
    default:
      // Safest fallback for an unrecognized action: close the flow rather
      // than risk executing an action the client doesn't understand.
      return CampaignButtonAction.dismiss;
  }
}

/// One button in a screen's button row (1-3 per screen).
class CampaignButton {
  final String key;
  final String label;
  final CampaignButtonStyle style;
  final CampaignButtonAction action;

  /// `submit`-only: the choice value recorded in the response POST.
  final String? choice;

  /// `goto`-only: the screen key to navigate to.
  final String? goto;

  /// `external`-only: the URL to open.
  final String? url;

  const CampaignButton({
    required this.key,
    required this.label,
    required this.style,
    required this.action,
    this.choice,
    this.goto,
    this.url,
  });

  factory CampaignButton.fromJson(Map<String, dynamic> json) => CampaignButton(
    key: (json['key'] as String?) ?? '',
    label: (json['label'] as String?) ?? '',
    style: _buttonStyleFromWire(json['style'] as String?),
    action: _buttonActionFromWire(json['action'] as String?),
    choice: json['choice'] as String?,
    goto: json['goto'] as String?,
    url: json['url'] as String?,
  );
}

// =============================================================================
// RESPONSE SUBMISSION (POST /campaigns/{key}/responses body)
// =============================================================================

/// Payload for `POST /api/v1/app/campaigns/{key}/responses`. All fields are
/// optional per the contract except that a submit-style interaction should
/// at minimum carry [choice].
class CampaignResponseRequest {
  final String? choice;
  final List<String>? selectedOptions;
  final String? freeText;

  /// Ordered list of screen keys visited before this response, for funnel
  /// analysis on the backend.
  final List<String>? path;
  final String? sessionId;
  final String? visitorId;

  const CampaignResponseRequest({
    this.choice,
    this.selectedOptions,
    this.freeText,
    this.path,
    this.sessionId,
    this.visitorId,
  });

  Map<String, dynamic> toJson() => {
    if (choice != null) 'choice': choice,
    if (selectedOptions != null) 'selected_options': selectedOptions,
    if (freeText != null && freeText!.isNotEmpty) 'free_text': freeText,
    if (path != null && path!.isNotEmpty) 'path': path,
    if (sessionId != null) 'session_id': sessionId,
    if (visitorId != null) 'visitor_id': visitorId,
  };
}
