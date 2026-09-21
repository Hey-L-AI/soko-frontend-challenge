/// Current EULA version the client is bundled with.
///
/// The string is sent to `POST /api/v1/app/eula/accept` and compared by the
/// backend against the server's authoritative version. When we materially
/// update the Terms of Service / EULA copy (`features/legal/screens/
/// terms_of_service_screen.dart` and the matching ARB strings), bump this
/// string AND the server constant in lockstep. Mismatches surface as
/// `needs_acceptance: true` on the next `GET /eula/me` and trigger the
/// forced re-acceptance modal on cold launch.
///
/// Format: `YYYY-MM-DD` of the date the new text was authored.
const String kCurrentEulaVersion = '2026-05-29';
