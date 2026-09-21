import 'package:dio/dio.dart';
import 'package:dio/browser.dart';

/// Web implementation - sets withCredentials for cross-origin cookie handling.
void configureWebCredentials(Dio dio) {
  dio.httpClientAdapter = BrowserHttpClientAdapter(withCredentials: true);
}
