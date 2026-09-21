/// Commits a user-selected Search Center (C) without exposing it globally
/// before the active chat accepts the same value.
///
/// [publishGlobal] deliberately does not run when [persistActiveChat] fails.
Future<void> commitSearchCenterChange({
  required Future<void> Function() persistActiveChat,
  required Future<void> Function() publishGlobal,
}) async {
  await persistActiveChat();
  await publishGlobal();
}
