import 'package:firebase_messaging/firebase_messaging.dart';

/// Native push delivery is outside the web interview target. No Firebase project
/// is configured in this copy and the bootstrap does not register this handler.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}
