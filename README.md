# Soko Flutter frontend challenge

Work on **the actual Soko Flutter app**. This private repository contains a snapshot
of the released `heyl-webapp` application, with its original screens, components,
assets, Riverpod state, GoRouter navigation and API clients.

It is an independent copy, with no deployment workflow or connection to the original
Git repository. The app connects to **backend-staging**. Production analytics and
marketing SDK startup are disabled. See [docs/SOURCE.md](docs/SOURCE.md) for exact
provenance and the small set of interview-specific changes.

Start with [CHALLENGE.md](CHALLENGE.md). Review the real app, choose two usability
improvements, and implement them in Flutter. Maximum effort: eight hours.

## Run

Install [Flutter](https://docs.flutter.dev/install), Chrome, Git and Python 3 (used by
the convenience script to check the SDK version). Use the Flutter version in
[.flutter-version](.flutter-version): **3.38.10**, including Dart 3.10.9.

Accept your GitHub invitation first. Clone the repository URL supplied by your
interviewer; if you were given a personal copy, use that URL instead:

```sh
git clone https://github.com/Hey-L-AI/soko-frontend-challenge.git
cd soko-frontend-challenge
./bin/start
```

The app opens at **http://localhost:3001**. Keep this port: backend-staging permits
this local origin for API calls and authentication callbacks.

Equivalent commands, also suitable for Windows or FVM users:

```sh
cd heyl_app
flutter pub get --enforce-lockfile
flutter gen-l10n
flutter run -d chrome --web-port 3001
```

For FVM, install the version from `.flutter-version` and prefix Flutter commands with
`fvm`. Or set `FLUTTER_BIN` to your pinned SDK's executable before running `bin/start`.
No Android SDK, Xcode, Docker, database or backend process is needed for web.

**Internet access is required.** This is the real app using live staging services,
not an offline demo. If setup takes over 30 minutes, contact your interviewer.

## Account and data

Use your own **backend-staging account**, or an individual staging account supplied
by your interviewer. Accounts and data are separate from backend-prod. Guest browsing
is available, but saving and other personalised features require sign-in.

The repository does not contain account credentials. Do not use a shared admin account.
Before the timed exercise, confirm you can sign in, browse and open an item. Report
account or staging-service problems to the interviewer instead of spending the day
fixing backend infrastructure.

Changes to frontend code affect only your copy. In-app actions operate on staging
and can persist there. Use your own lists/content for write actions. Ordinary public
links, imagery, Google sign-in and Mapbox still use their respective live services;
this is not a network sandbox. The existing public Mapbox client token and style are
retained so the actual map UI can work; no private Mapbox token is included.

## What is here

No product feature directory has been removed. The original Flutter source includes
discovery, chat, maps, event/venue details, zines/lists, library, profile, settings,
onboarding and authentication. Some features depend on staging data, permissions,
remote feature flags or native capabilities. Web is the required interview target;
we have not included iOS/Android signing and deployment projects.

| Path | Start here for |
| --- | --- |
| `heyl_app/lib/features/discovery/` | Discovery screens and feed |
| `heyl_app/lib/features/chat/` | Conversation UI and recommendation cards |
| `heyl_app/lib/features/map/` | Map experience |
| `heyl_app/lib/features/event_detail/`, `venue_detail/` | Item detail screens |
| `heyl_app/lib/features/lists/` | Zines and lists |
| `heyl_app/lib/shared/widgets/` | Existing Soko components |
| `heyl_app/lib/core/theme/` | Real design tokens and themes |
| `heyl_app/lib/providers/` | Riverpod state and service wiring |
| `heyl_app/lib/core/router/app_router.dart` | Existing navigation |
| `heyl_app/lib/data/datasources/` | API clients and existing mocks |
| `heyl_app/lib/l10n/intl_*.arb` | English, Portuguese and Spanish UI copy |
| `docs/ui/` | Design-system context from the app repository |
| `open-api/heyl-webapp-v1.openapi.yaml` | API contract snapshot |

Choose a manageable flow; you are not expected to understand the entire codebase.
Reuse existing components. Keep new user-facing strings in the ARB files and run
`flutter gen-l10n` after changing them.

## Verify

From `heyl_app/`:

```sh
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
flutter build web --no-web-resources-cdn
```

The source snapshot carries existing analyzer warnings/style notices. These are not
hidden tasks for the interview; CI fails on errors, while reporting those notices.
The included tests cover selected original components plus interview configuration.
They are not a copy of the entire production regression suite. Add focused checks
for your changes and describe manual validation in `SUBMISSION.md`.

For a release-build preview, from the repository root:

```sh
python3 bin/serve
```

This serves `heyl_app/build/web` on localhost:3001 with the fallback needed by the
app's existing URL routing. Stop `flutter run` first to free the port.

## Submit

Work in your own private candidate repository. Complete [SUBMISSION.md](SUBMISSION.md),
include before/after screenshots or a short recording, and share the repository URL
and final commit SHA with your interviewer. A source ZIP is also acceptable.

Do not publish Soko's application source or assets. Do not commit credentials, build
output, personal data or unredacted tool transcripts.

[Optional PostHog experiment](docs/EXPERIMENTS.md) · [Source provenance](docs/SOURCE.md)
