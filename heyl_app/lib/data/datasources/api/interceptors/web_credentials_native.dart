import 'package:dio/dio.dart';

/// Native implementation - no special configuration needed for cookies.
void configureWebCredentials(Dio dio) {
  // No-op on native platforms - cookies handled differently
}
