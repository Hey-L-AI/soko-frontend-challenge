import '../analytics_service.dart';
import 'analytics_destination.dart';

/// Firebase Analytics destination adapter.
///
/// Maps generic events to Firebase's typed SDK methods where available,
/// falling back to `logEvent()` for custom events.
class FirebaseDestination implements AnalyticsDestination {
  final AnalyticsService _firebase;

  FirebaseDestination(this._firebase);

  @override
  String get name => 'firebase';

  @override
  Future<void> track(String event, Map<String, dynamic> properties) async {
    switch (event) {
      // Firebase has special SDK methods for these standard events
      case 'login':
        await _firebase.logLogin(method: properties['method'] as String? ?? 'unknown');

      case 'sign_up':
        await _firebase.logSignUp(method: properties['method'] as String? ?? 'unknown');

      case 'logout':
        await _firebase.logLogout();

      case 'search':
        await _firebase.logSearch(searchTerm: properties['search_term'] as String? ?? '');

      case 'view_item':
        await _firebase.logViewItem(
          itemId: properties['item_id'] as String? ?? '',
          itemType: properties['item_type'] as String? ?? '',
          itemName: properties['item_name'] as String?,
        );

      case 'screen_view':
        await _firebase.logScreenView(
          screenName: properties['screen_name'] as String? ?? '',
          screenClass: properties['screen_class'] as String?,
        );

      case 'message_sent_user':
        await _firebase.logMessageSent(
          messageType: properties['message_type'] as String? ?? 'text',
        );

      // List share maps to Firebase's share event
      case 'list_share':
        await _firebase.logShare(
          contentType: 'list',
          itemId: properties['list_id'] as String? ?? '',
          method: properties['share_method'] as String?,
        );

      // All other events use the generic logEvent method
      default:
        await _firebase.logEvent(
          name: _sanitizeEventName(event),
          parameters: _castParameters(properties),
        );
    }
  }

  @override
  Future<void> identify(String userId, Map<String, dynamic> traits) async {
    await _firebase.setUserId(userId);
  }

  @override
  Future<void> reset() async {
    await _firebase.setUserId(null);
  }

  /// Firebase event names must be alphanumeric + underscores, max 40 chars.
  String _sanitizeEventName(String name) {
    // Replace hyphens with underscores (our events already use underscores)
    final sanitized = name.replaceAll('-', '_');
    return sanitized.length > 40 ? sanitized.substring(0, 40) : sanitized;
  }

  /// Cast properties to Map<String, Object> for Firebase, filtering nulls.
  Map<String, Object>? _castParameters(Map<String, dynamic> props) {
    if (props.isEmpty) return null;
    final result = <String, Object>{};
    for (final entry in props.entries) {
      if (entry.value != null) {
        result[entry.key] = entry.value as Object;
      }
    }
    return result.isEmpty ? null : result;
  }
}
