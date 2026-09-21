/// App-wide constants for Soko app
class AppConstants {
  AppConstants._();

  /// App name
  static const String appName = 'Soko';

  /// App full name
  static const String appFullName = 'Soko';

  /// AI Assistant name
  static const String assistantName = 'Soko';

  /// Storage keys
  static const String accessTokenKey = 'access_token';
  static const String userIdKey = 'user_id';
  static const String useMockApiKey = 'use_mock_api';

  /// Pagination defaults
  static const int defaultPageSize = 50;
  static const int maxPageSize = 200;

  /// Message input constraints
  static const int maxMessageLength = 4000;

  /// Animation durations
  static const Duration shortAnimation = Duration(milliseconds: 150);
  static const Duration mediumAnimation = Duration(milliseconds: 300);
  static const Duration longAnimation = Duration(milliseconds: 500);

  /// Breakpoints for responsive design
  static const double mobileBreakpoint = 480;
  static const double tabletBreakpoint = 768;
  static const double desktopBreakpoint = 1024;

  /// Chat sidebar width
  static const double sidebarWidth = 280;

  /// Profile sheet width
  static const double profileSheetWidth = 320;
}
