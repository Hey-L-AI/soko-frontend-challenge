import 'package:dio/dio.dart';

/// Stub implementation - should never be called at runtime.
/// This file is used when neither dart:html nor dart:io is available.
void configureWebCredentials(Dio dio) {
  throw UnsupportedError('Cannot configure web credentials on this platform');
}
