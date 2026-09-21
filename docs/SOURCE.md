# Source and interview-specific changes

This is a source snapshot of **Hey-L-AI/heyl-webapp**, released branch `main`, commit
`745c590906d43aac1bf6f8ba3abde4626958759e` (21 September 2026).
It has independent Git history and no deployment connection to the source repository.

## What was retained

All **671 files under `heyl_app/lib/features/` are byte-for-byte unchanged** from that
commit. All product feature directories remain, including discovery, chat, map,
event and venue details, lists/zines, library, profile, settings and onboarding.
The original shared components, themes, assets, localisation, providers, routing,
API clients, dependency versions and local `third_party/social_share` dependency
are included. Design documentation and the API contract are copied from the same
snapshot. This is not a recreation of the interface.

Of the 1,162 original files under `lib/`, 1,155 are unchanged, six have changes
listed below, and the Firebase project configuration is omitted.

## What changed

| File | Interview change |
| --- | --- |
| `lib/main.dart` | Keep the actual SokoApp and provider wiring; use a web bootstrap without Firebase, Sentry or native marketing startup. |
| `lib/core/constants/api_constants.dart` | Route both environment configurations to backend-staging; use localhost:3001 for the app origin. |
| `lib/core/config/environment.dart` | Empty default PostHog/Klaviyo configuration and disable optional marketing integrations by default. |
| `lib/core/services/analytics_service.dart` | Preserve the analytics interface as a no-op without a Firebase project. |
| `lib/core/services/unified_analytics_service.dart` | Accept the no-op analytics navigator observer. |
| `lib/core/notifications/fcm_background_handler.dart` | Preserve the handler signature without Firebase background initialisation. |
| `lib/firebase_options.dart` | Omit the original Firebase project configuration. |
| `web/index.html` | Remove production PostHog and TikTok bootstraps; retain the real app shell and map support. |
| `pubspec.yaml` | Remove production Sentry symbol-upload configuration; retain application dependencies and lockfile. |

Paths in this table are relative to `heyl_app/`.

The public Mapbox client token/style and Google sign-in client identifier remain
because the original map and authentication integrations use them. The app also
loads external images and public links. It is not an offline or network-isolated app.
No private service credentials or candidate account credentials are included.

## What is outside the copy

- iOS/Android/desktop runner projects, signing files and deployment infrastructure.
  Flutter web is the required interview target.
- Original Git history, internal agent instructions, operational scripts and the
  full upstream test suite.
- Production monitoring, analytics and marketing startup. Optional PostHog work
  should use a separate interview project, as described in `EXPERIMENTS.md`.

The selected upstream tests check event-card date precision and CTA accessibility
at large font sizes. Additional tests check the interview service configuration.
Existing source warnings are reported by analysis but are not interview tasks.

## Service and verification limits

Backend-staging must be available. Guest discovery works without an account;
personalised journeys need an individual staging login. Some original functionality
also depends on permissions, remote flags, data or native-only integrations.
Provision and verify the candidate's account before starting the timed exercise.

The interview preparation verified dependency resolution, static analysis with no
errors, 14 tests and a Flutter web release build. Browser verification covered the
real entry/onboarding screens and guest discovery using staging data. Authenticated
saving, every feature and native builds have not been exhaustively validated.
