# FDAM — Flutter Dynamic Asset Manager

A reusable Flutter package (Android) that keeps large app files **out of the APK**.
Audio, images, video, SQLite databases, ZIP packs and JSON config live in a
GitHub repository's **Releases**; the app downloads, verifies, extracts and
updates them after installation.

```
GitHub (assets repo)                         Android app
manifest/manifest.json ──raw URL + ETag──▶  ManifestReader ─▶ VersionPlanner
Releases v1.0.0, v1.1.0 ──302 redirect──▶   DownloadEngine (.part, Range/If-Range)
                                              └─▶ SHA-256 (isolate)
                                                   └─▶ ZipExtractor (isolate, staging)
                                                        └─▶ AssetInstaller (swap + backup)
                                                             └─▶ SQLite metadata
```

## Features

| Area | What it does |
|---|---|
| Manifest | Raw-URL fetch with `If-None-Match`/`If-Modified-Since`, strict validation (schema, appId, semver, HTTPS + allowed hosts, optional repo prefix, safe `localPath`, size, SHA-256 format, duplicates, overlaps), offline cache, downgrade protection, `minimumManagerVersion`. |
| Download | Dio streaming to `.part`, priority queue (required → startup → optional), 2 concurrent by default, pause / resume / cancel / retry, exponential backoff with jitter, timeouts, manually followed redirects (every hop is host-checked), HTTP Range resume validated with a strong ETag or Last-Modified (`If-Range`), restart from 0 when the server ignores Range, never writes past the manifest size, real speed + ETA, state persisted in SQLite. |
| Integrity | Size check then streaming SHA-256 in a background isolate. A download only succeeds when both match the manifest; mismatches delete the `.part` and retry. |
| ZIP | Background isolate; rejects ZIP Slip, absolute paths, backslashes, symlinks, duplicates; limits on entry count, total size and compression ratio; counts real bytes written; checks free space; extracts to `staging/` only. |
| Install | Staging → atomic rename into place. Previous version moved to `backups/` first and restored on any failure; crash journal recovers interrupted swaps on next start. Manual rollback. |
| Versions | Per asset: id + version + SHA-256 (+ size via SHA) + files-present check → install / update / keep / repair / removed. Removed assets are kept until the app says they are unused. |
| Network | connectivity_plus for the interface, plus a real HTTP request to prove the internet works. Wi-Fi-only mode, wait-for-network, auto-continue on reconnect. |
| Background | WorkManager periodic maintenance + one-off retry, with network/storage/battery constraints. Skips when the app is in the foreground. |
| Storage | Real free space via `StatFs` (small Kotlin plugin in this package). |
| UI | Riverpod screens: `AssetSetupScreen`, `DownloadManagerScreen`, `AssetDashboardScreen`, `AssetSettingsScreen`, plus `FdamGate`. Malay / English. D-pad friendly. |

## Use in an app

```yaml
dependencies:
  fdam:
    path: packages/fdam   # or a git dependency
  flutter_riverpod: ^3.3.2
```

```dart
import 'package:fdam/fdam.dart';

FdamConfig buildFdamConfig() => const FdamConfig(
      manifestUrl: 'https://raw.githubusercontent.com/OWNER/MyFlutterApp-Assets/main/manifest/manifest.json',
      appId: 'com.example.myapp',
      allowedUrlPrefixes: ['https://github.com/OWNER/MyFlutterApp-Assets/releases/download/'],
    );

@pragma('vm:entry-point')
void fdamBackgroundDispatcher() => FdamBackground.dispatch(buildFdamConfig);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final manager = await AssetManager.create(
    config: buildFdamConfig(),
    rootDirectory: AssetManager.defaultRoot(support),
  );
  await FdamBackground.register(fdamBackgroundDispatcher, config: buildFdamConfig());
  runApp(ProviderScope(
    overrides: [assetManagerProvider.overrideWithValue(manager)],
    child: MaterialApp(home: FdamGate(child: MyHomePage())),
  ));
}
```

Reading an asset:

```dart
final dir = await manager.pathOf('audio_pack_01');          // extracted folder
final file = await manager.fileIn('audio_pack_01', 'sfx/click.wav');
final db = await manager.pathOf('database_main');            // databases/...
```

Before an installed SQLite file is replaced, close it:

```dart
manager.installer.beforeActivate = (item) async { if (item.id == 'database_main') await myDb.close(); };
manager.installer.afterActivate  = (item) async { if (item.id == 'database_main') await reopenDb(); };
```

Tell FDAM whether a retired asset (removed from the manifest) is still used:

```dart
AssetManager.create(..., usageChecker: (record) async => myAppStillUses(record.id));
```

## Manifest

See `asset_repo_template/` (generator, validator, sample). Install locations:
`assets/<localPath>` (or `databases/<localPath>` for the `database` category);
for `extract: true` the ZIP becomes the folder `<localPath without .zip>/`.

## Error codes

`NETWORK_UNAVAILABLE`, `HTTP_ERROR`, `MANIFEST_INVALID`, `MANIFEST_NOT_FOUND`,
`FILE_NOT_FOUND`, `DISK_SPACE_INSUFFICIENT`, `DOWNLOAD_INTERRUPTED`,
`CHECKSUM_MISMATCH`, `ZIP_EXTRACTION_FAILED`, `INVALID_ASSET_PATH`,
`DATABASE_ERROR`, `VERSION_CONFLICT` (+ `CANCELLED`, `UNKNOWN`). Each has a
Malay and English user message (`FdamException.userMessage(lang)`). Logs
redact query strings and credentials.

## Tests

```bash
flutter test
```

71 tests: core rules, ZIP security, SQLite migrations, manifest reader,
download engine (real local HTTP server with ETag, Range, redirects,
disconnects, stalls), 20 end-to-end scenarios, UI, and compatibility with the
Python generator's output.

## Known limits

* SHA-256 proves the file matches the manifest, **not** who published the
  manifest. Ed25519 manifest signatures are the planned next security phase.
* No foreground service: Android may delay background work; large downloads
  are meant to run while the app is open (progress is shown in the UI).
* Public asset repositories only (no tokens are ever placed in the APK).
