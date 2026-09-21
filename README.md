# Soko frontend challenge

A small Flutter app for exploring fictional Lisbon events and saving a plan for later.
This is an isolated interview exercise, inspired by Soko's discovery experience.
It is not a checkout of the production app.

**Start with [CHALLENGE.md](CHALLENGE.md).** Spend at most eight hours, including the
review, implementation, documentation and any bonus work.

## Run it

Install [Flutter](https://docs.flutter.dev/install) and Chrome. This starter and CI
use **Flutter 3.38.10 / Dart 3.10.9**. Flutter includes Dart. No Android SDK, Xcode,
backend, account or API key is needed for the required web target.

```sh
git clone https://github.com/Hey-L-AI/soko-frontend-challenge.git
cd soko-frontend-challenge
flutter pub get
flutter gen-l10n
flutter run -d chrome --web-port 8080
```

For a private repository, accept your GitHub invitation first and authenticate
with GitHub CLI (`gh auth login`, then `gh auth setup-git`) or your usual Git credentials.
If your interviewer gives you a personal repository copy, use that clone URL instead.

If you use [FVM](https://fvm.app/), `.fvmrc` pins the same SDK:

```sh
fvm install
fvm flutter pub get
fvm flutter gen-l10n
fvm flutter run -d chrome --web-port 8080
```

Other browsers: run `flutter run -d web-server --web-port 8080` and open
`http://localhost:8080`. Debugging and hot reload support differ by browser.

The first dependency download needs internet access. No Soko service is contacted.
If setup takes more than 30 minutes, contact your interviewer; setup trouble should
not consume the exercise.

## What is included

- Discover, search, event details, save and unsave, and a Saved tab.
- Eight fictional events with varied dates, prices, booking and accessibility details.
- Browser-local persistence for saved events. Use the same browser and port to retain
  them between runs. Clearing site storage resets them; nothing syncs to a server.
- Loading, empty and recoverable error states.
- Responsive Flutter layouts, Soko colour tokens and locally drawn illustrations.
- English UI strings in ARB, ready for localisation. Event content is fixture data.
- Behaviour tests and GitHub Actions checks.

The scenario is fixed: imagine it is **Friday, 25 September 2026**, planning for
**26–27 September** in Lisbon. Dates do not depend on when you take the interview.
All times are Lisbon wall-clock times. Names, venues and listings are fictional;
there are no real bookings or external event links.

## Find your way around

| Path | Purpose |
| --- | --- |
| `lib/app.dart` | Discovery screen, navigation and small local state |
| `lib/screens/event_detail.dart` | Event details and saving |
| `lib/domain/event.dart` | Event model and search matching |
| `lib/data/` | Local asset repository and saved-item storage |
| `lib/widgets/` | Cards, illustrations and primary button |
| `lib/theme.dart` | Colours and theme |
| `lib/l10n/app_en.arb` | UI copy; run `flutter gen-l10n` after edits |
| `assets/data/events.json` | Synthetic events |
| `test/` | Baseline behaviour tests |
| `docs/EXPERIMENTS.md` | Optional PostHog bonus scope |
| `SUBMISSION.md` | Short template for your findings and decisions |

State uses Flutter's built-in `StatefulWidget`; there is no required state-management
package. Adapt the structure if your changes justify it. The baseline is deliberately
small, with no hidden defects you are expected to find and no prescribed improvements.

## Check your work

```sh
flutter gen-l10n
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build web --no-web-resources-cdn
```

Format edits with `dart format lib test`. Generated localisation files are ignored
by Git and recreated by `flutter gen-l10n`.

To exercise alternative data states, stop the current app and restart with:

```sh
# First load fails; Try again recovers.
flutter run -d chrome --web-port 8080 --dart-define=DEMO_SCENARIO=error

# Repository returns no events.
flutter run -d chrome --web-port 8080 --dart-define=DEMO_SCENARIO=empty
```

To preview a release build locally:

```sh
flutter build web --no-web-resources-cdn
python3 -m http.server 8080 --directory build/web
```

## Submit

Work in the separate repository provided by your interviewer, or create your own
private copy and share it with them. Keep your submission private unless agreed
otherwise. You do not need write access to this starter or any Soko application repo.

Complete `SUBMISSION.md`, include screenshots or a short demo, and send your
interviewer the repository URL and final commit SHA. A source ZIP is also acceptable
if repository sharing is inconvenient. Keep the lockfile and exclude build output,
credentials, personal data and unredacted tool logs.
