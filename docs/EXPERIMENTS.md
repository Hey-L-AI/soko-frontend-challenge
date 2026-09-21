# Optional PostHog experiment

The actual app already has the PostHog SDK and service/experiment abstractions.
Production project configuration and the web tracking bootstrap have been removed
from this interview copy. Reuse the existing integration with a separate interview
project; do not restore the production token.

Use a dedicated interview project provided by your interviewer, or an empty project
you control. Never use Soko production or staging analytics. Do not add personal API
keys to client code or Git. A PostHog project token used by a client SDK is public;
keep any privileged management credentials out of the app.

Build a small experiment around one improvement:

1. Explain the hypothesis. Preserve an original experience and add the improved one.
2. Keep assignment stable for an anonymous browser identity rather than changing it
   on every rebuild. Define a fallback when flags are unavailable.
3. Record exposure when the relevant experience is actually shown, and capture the
   action needed to calculate your success metric. Use synthetic identifiers for demonstration events;
   avoid sending staging user data, free-text search content or personal information.
4. Demonstrate both variants, with a documented local testing override if useful.
   Separate forced test traffic from evidence for a real experiment.
5. Show test events arriving in the sandbox. Explain the metric denominator and a
   guardrail; no real traffic or statistical conclusions are expected.

Keep the default clone-and-run path working without PostHog configuration, including
when PostHog is unreachable. Do not enable session recordings as part of this exercise.

References:

- [Flutter SDK and web setup](https://posthog.com/docs/libraries/flutter)
- [Experiments](https://posthog.com/docs/experiments)

Follow the instructions for the SDK version you choose: Flutter web has platform-specific
initialisation requirements. Do not assume native SDK setup also enables web capture.
