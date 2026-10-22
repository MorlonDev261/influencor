/// App-wide constants and configurable defaults.
abstract final class AppConstants {
  static const String appName = 'Influencor';

  /// Keep in sync with `version:` in pubspec.yaml (without the build number).
  static const String version = '1.0.0';

  /// Public privacy policy (influencor-web): English page for English,
  /// French page otherwise (also for Malagasy).
  static String privacyPolicyUrl(String languageCode) => languageCode == 'en'
      ? 'https://influencor.mi-kandra.org/privacy/'
      : 'https://influencor.mi-kandra.org/confidentialite/';

  /// Layout breakpoint (logical pixels) above which the desktop / tablet
  /// layout (persistent sidebar, wider grids) is used.
  static const double desktopBreakpoint = 840;

  /// Maximum content width on large screens.
  static const double maxContentWidth = 1200;

  static const double defaultPadding = 16;
  static const double borderRadius = 16;

  /// Search input debounce.
  static const Duration searchDebounce = Duration(milliseconds: 300);

  // Default file-size limits (bytes). Overridable from settings.
  static const int maxImageBytes = 100 * 1024 * 1024; // 100 MB
  static const int maxVideoBytes = 1024 * 1024 * 1024; // 1 GB
  static const int maxTextBytes = 1 * 1024 * 1024; // 1 MB

  static const List<String> imageExtensions = [
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif'
  ];
  static const List<String> videoExtensions = ['mp4', 'mov', 'webm', 'avi'];

  /// Font used to render note text so the native Unicode styling looks right:
  /// Arial keeps normal text familiar and draws a continuous, centred strike
  /// (U+0336); Cambria Math supplies the bold/italic math letters (and also
  /// centres the strike); Segoe UI is the last-resort fallback.
  static const String noteFontFamily = 'Arial';
  static const List<String> noteFontFallback = [
    'Cambria Math',
    'Segoe UI',
    'Segoe UI Symbol',
    'Segoe UI Emoji',
    'Noto Sans',
    'Noto Color Emoji',
  ];
}
