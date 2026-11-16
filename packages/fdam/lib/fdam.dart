/// Flutter Dynamic Asset Manager (FDAM).
///
/// Downloads, verifies (SHA-256), extracts (safely) and versions extra app
/// assets hosted on GitHub Releases, described by a JSON manifest.
library;

export 'src/asset_manager.dart';
export 'src/background/fdam_background.dart';
export 'src/core/config.dart';
export 'src/core/errors.dart';
export 'src/core/logger.dart' show FdamLogger, FdamLogEntry, FdamLogLevel, redactUrl;
export 'src/core/path_safety.dart';
export 'src/core/version.dart';
export 'src/download/download_engine.dart';
export 'src/extract/zip_extractor.dart';
export 'src/install/asset_installer.dart';
export 'src/integrity/hash_service.dart';
export 'src/manifest/manifest_reader.dart';
export 'src/manifest/manifest_validator.dart';
export 'src/manifest/models.dart';
export 'src/network/fdam_http.dart';
export 'src/network/network_monitor.dart';
export 'src/storage/asset_repository.dart';
export 'src/storage/fdam_database.dart';
export 'src/storage/fdam_paths.dart';
export 'src/storage/fdam_preferences.dart';
export 'src/storage/storage_info.dart';
export 'src/ui/asset_dashboard_screen.dart';
export 'src/ui/asset_settings_screen.dart';
export 'src/ui/asset_setup_screen.dart';
export 'src/ui/download_manager_screen.dart';
export 'src/ui/fdam_gate.dart';
export 'src/ui/fdam_strings.dart';
export 'src/ui/providers.dart';
export 'src/version/version_planner.dart';
