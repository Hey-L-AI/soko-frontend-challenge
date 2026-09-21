import 'chat_message.dart' show ItemSuggestion;
import 'import_job.dart' show ImportJobCreatedResponse;

/// Outcome of `POST /api/v1/app/places/resolve-url`.
///
/// The endpoint resolves EITHER a single place (200/201) OR — when the pasted
/// URL is a shared Google Maps *list* — starts an async import job (202) that
/// creates a new list in the background. Callers switch on this to branch:
/// render the place, or hand the `job_id` to the import poller.
/// (backend PROD-3903 / app PROD-3905)
sealed class ResolveUrlResult {
  const ResolveUrlResult();
}

/// A single place was resolved synchronously (HTTP 200 DB hit / 201 created).
class ResolveUrlPlace extends ResolveUrlResult {
  final ItemSuggestion suggestion;
  const ResolveUrlPlace(this.suggestion);
}

/// The pasted URL was a shared list — an async import job was started (HTTP
/// 202). Poll it via the import machinery (`importListProvider`).
class ResolveUrlListImport extends ResolveUrlResult {
  final ImportJobCreatedResponse job;
  const ResolveUrlListImport(this.job);
}
