/// Build-time configuration.
///
/// Override the database location without editing code:
///   flutter build apk --dart-define=DB_BASE_URL=https://raw.githubusercontent.com/OWNER/REPO/main/database/
const String kDatabaseBaseUrl = String.fromEnvironment(
  'DB_BASE_URL',
  defaultValue: 'https://raw.githubusercontent.com/cdsouthernjhr-gif/teleM/main/database/',
);

/// Must match the build number in pubspec.yaml (`version: x.y.z+BUILD`).
/// The database can require a minimum build via `min_app_build`.
const int kAppBuild = 2;
const String kAppVersion = '1.1.0';
