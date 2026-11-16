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

/// Flutter Dynamic Asset Manager: raw URL of the assets manifest.json.
/// Empty (default) disables FDAM; the app then behaves exactly as before.
///   flutter build apk --dart-define=FDAM_MANIFEST_URL=https://raw.githubusercontent.com/OWNER/MyFlutterApp-Assets/main/manifest/manifest.json
const String kFdamManifestUrl = String.fromEnvironment('FDAM_MANIFEST_URL', defaultValue: '');

/// Must equal `appId` in the assets manifest.
const String kFdamAppId = String.fromEnvironment('FDAM_APP_ID', defaultValue: 'com.myaseantv.tv');

/// Optional: restrict asset URLs to one repository's releases, e.g.
///   --dart-define=FDAM_RELEASE_PREFIX=https://github.com/OWNER/MyFlutterApp-Assets/releases/download/
const String kFdamReleasePrefix = String.fromEnvironment('FDAM_RELEASE_PREFIX', defaultValue: '');
