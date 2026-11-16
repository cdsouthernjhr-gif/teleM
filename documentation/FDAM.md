# FDAM — Flutter Dynamic Asset Manager

Panduan seni bina, pemasangan, penerbitan release GitHub, binaan APK dan ujian
untuk sistem pengurusan aset luaran. Kod modul berada dalam
[`packages/fdam/`](../packages/fdam) (pakej Flutter yang boleh diguna semula),
templat repositori aset dalam [`asset_repo_template/`](../asset_repo_template).

## 1. Ringkasan

* APK hanya mengandungi kod + pengurus aset. Audio, gambar, video, pangkalan
  data SQLite, ZIP dan JSON disimpan dalam **GitHub Releases** sebuah
  repositori aset public.
* Aplikasi membaca `manifest.json` (URL raw), membandingkan versi, memuat turun
  fail yang berubah sahaja, mengesahkan **saiz + SHA-256**, membuka ZIP dengan
  selamat dalam *staging*, kemudian menukar ke lokasi sebenar dengan sandaran
  versi lama (rollback).
* Fail **wajib** mesti dipasang sebelum aplikasi dibuka; fail **pilihan** tidak
  pernah menghalang aplikasi.
* Dalam MY ASEAN TV, FDAM **dimatikan secara lalai** (tiada `FDAM_MANIFEST_URL`).
  Aplikasi berfungsi tepat seperti sebelum ini sehingga anda mengaktifkannya.

## 2. Seni bina

```
lib/main.dart ── FdamBinding.init() ─▶ AssetManager (packages/fdam)
                                         │
   ManifestReader ── ETag/304, cache, validasi ketat, offline
   VersionPlanner ── install / update / keep / repair / removed
   DownloadEngine ── Dio, .part, Range + If-Range, keutamaan 1/2/3,
                     2 serentak, jeda/sambung/batal/cuba semula, backoff
   HashService    ── SHA-256 strim dalam isolate
   ZipExtractor   ── isolate, anti ZIP Slip/symlink/bom, staging
   AssetInstaller ── staging → swap atomik, backups/, jurnal pemulihan
   FdamDatabase   ── SQLite (assets, downloads, app_settings) + migrasi
   NetworkMonitor ── connectivity_plus + permintaan HTTP sebenar, Wi-Fi sahaja
   FdamBackground ── WorkManager (semakan berkala + cuba semula)
   UI (Riverpod)  ── FdamGate, Setup, Download Manager, Dashboard, Settings
```

Struktur storan (dalam `ApplicationSupportDirectory/fdam/`, peribadi kepada aplikasi):

```
assets/{audio,images,videos,resources,config,data}/   fail aktif
databases/                                            pangkalan data aktif
staging/      pengekstrakan / sebelum diaktifkan (dikosongkan setiap permulaan)
temp/         *.part (muat turun separa)
metadata/     fdam.db (SQLite), manifest_cache.json, fdam.log
backups/      versi terdahulu setiap aset (rollback)
```

Lokasi pemasangan: `assets/<localPath>` (kategori `database`:
`databases/<localPath>`). Untuk `extract: true`, `audio/audio.zip` menjadi folder
`assets/audio/audio/`.

### Jadual SQLite

* `assets`: id, name, category, version, local_path, size_bytes, sha256, status,
  downloaded_at, updated_at (+ v2: required, priority, previous_version,
  previous_sha256, backup_path, in_manifest, deprecated, extract)
* `downloads`: id, asset_id, download_url, temporary_path, downloaded_bytes,
  total_bytes, status, retry_count, last_error, created_at, updated_at
  (+ v2: etag, last_modified, version, sha256, priority)
* `app_settings`: key, value

Migrasi berversi dalam `kFdamMigrations` (v1 = jadual spesifikasi, v2 = lajur
tambahan). Mod WAL melindungi data jika aplikasi ditutup ketika menulis.

### Keselamatan

| Ancaman | Perlindungan |
|---|---|
| URL berbahaya dalam manifest | HTTPS sahaja, hos GitHub sahaja (setiap redirect disemak), tiada `user:pass@`, pilihan `FDAM_RELEASE_PREFIX` untuk satu repositori |
| Path traversal | `localPath` dan nama entri ZIP ditolak jika mutlak, `..`, `\`, huruf pemacu, aksara kawalan; laluan akhir disemak kekal dalam root |
| ZIP Slip / symlink / bom ZIP | Ditolak; had bilangan fail, jumlah saiz, nisbah mampatan; bait sebenar dikira semasa menulis |
| Fail rosak / diganti | Saiz + SHA-256 mesti sepadan; jika tidak, `.part` dibuang dan dicuba semula |
| Resume fail yang salah | Resume hanya dengan ETag kuat / Last-Modified melalui `If-Range`; `Content-Range` disemak; jika tidak pasti, mula dari 0 |
| Manifest lama dihantar semula | `releaseVersion` lebih rendah daripada cache ditolak |
| Kemas kini gagal separuh jalan | Versi lama dipindah ke `backups/` dan dipulihkan; jurnal memulihkan selepas crash |
| Rahsia | Tiada token dalam APK; log membuang query string (URL bertandatangan GitHub) |

**Had yang diketahui:** SHA-256 membuktikan fail sepadan dengan manifest, tetapi
tidak membuktikan siapa yang menerbitkan manifest. Tandatangan **Ed25519** untuk
manifest ialah fasa keselamatan seterusnya (belum dilaksanakan).

## 3. Mengaktifkan FDAM dalam MY ASEAN TV

1. Cipta repositori public baharu daripada `asset_repo_template/` (lihat README di sana).
2. Terbitkan release pertama (bahagian 4).
3. Bina APK dengan URL manifest:

```bash
flutter build apk --release --dart-define=FDAM_MANIFEST_URL=https://raw.githubusercontent.com/USERNAME/MyFlutterApp-Assets/main/manifest/manifest.json --dart-define=FDAM_RELEASE_PREFIX=https://github.com/USERNAME/MyFlutterApp-Assets/releases/download/
```

`appId` dalam manifest mesti `com.myaseantv.tv` (atau tetapkan
`--dart-define=FDAM_APP_ID=...`).

Apabila diaktifkan:

* `FdamGate` memaparkan **Persediaan Aset** jika ada fail wajib yang belum dipasang
  (saiz muat turun, ruang storan sebenar, status internet, butang muat turun,
  pilihan langkau fail pilihan). Jika manifest tidak dapat dimuat dan tiada
  cache, pengguna boleh "Teruskan ke aplikasi".
* **Tetapan → Aset tambahan → URUS ASET** membuka Papan Pemuka, Pengurus Muat
  Turun dan Tetapan Aset (kemas kini automatik, Wi-Fi sahaja, kemas kini manual,
  kosongkan cache pilihan, pengurusan storan).
* WorkManager menjadualkan semakan berkala (12 jam, perlu rangkaian, storan dan
  bateri tidak rendah). Android boleh menangguhkannya; tiada janji muat turun
  serta-merta apabila aplikasi ditutup.

Menggunakan aset dalam kod:

```dart
final fdam = FdamBinding.of(context);            // null jika FDAM dimatikan
final file = await fdam?.manager.fileIn('audio_pack_01', 'click.wav');
```

## 4. Panduan penerbitan GitHub Release

Ringkas (butiran penuh dalam `asset_repo_template/README.md`):

1. Letak fail dalam `release-assets/`, kemas kini `config/assets_config.json`.
2. `generate_manifest.py --previous manifest/manifest.json --upload-list upload.txt`
   — fail yang tidak berubah mengekalkan versi dan URL lama.
3. `validate_manifest.py --check-files release-assets --tag vX.Y.Z`
4. `gh release create vX.Y.Z` kemudian `xargs -a upload.txt gh release upload vX.Y.Z`
5. `validate_manifest.py --check-urls`
6. Commit + push `manifest/` **paling akhir**.

## 5. Binaan APK

Keperluan: Flutter 3.32.8 (Dart 3.8.1), JDK 17+, Android SDK 35, NDK 27.0.12077973.

```bash
flutter pub get
```

```bash
flutter analyze
```

```bash
flutter test
```

```bash
cd packages/fdam && flutter test
```

```bash
flutter build apk --debug
```

```bash
flutter build apk --release
```

Tambah `--dart-define=FDAM_MANIFEST_URL=...` untuk mengaktifkan FDAM. Tanpanya,
APK berkelakuan seperti versi sebelum FDAM.

Pakej Android yang digunakan dan versinya (serasi dengan Flutter 3.32.8 /
AGP 8.7.3 / Kotlin 2.1.0 / minSdk 23): dio 5.11, sqflite 2.4.2, crypto 3.0.8,
archive 4.7.1, workmanager 0.9.2 (dengan `workmanager_platform_interface` 0.9.3
— versi 0.9.4 tidak serasi dengan `workmanager_apple` 0.9.4 dan gagal dikompil),
connectivity_plus 7.0.0 (7.1+ memerlukan androidx.core 1.18 → AGP 8.9.1 dan compileSdk 36), flutter_riverpod 3.3.2, shared_preferences 2.5.3,
path_provider 2.1.5.

## 6. Ujian

| Suite | Arahan | Kandungan |
|---|---|---|
| FDAM (71 ujian) | `cd packages/fdam && flutter test` | peraturan teras, keselamatan ZIP, migrasi SQLite, pembaca manifest, enjin muat turun terhadap pelayan HTTP tempatan sebenar, 20 senario hujung-ke-hujung, UI, keserasian output Python |
| Aplikasi | `flutter test` | ujian sedia ada + gerbang FDAM dan pautan Tetapan |
| Alat Python (10 ujian) | `cd asset_repo_template && python -m unittest discover -s tools/tests` | penjana, pengesah, hash |
| Peranti Android | `flutter test integration_test/fdam_device_test.dart -d <peranti>` | sqflite asli, StatFs, connectivity_plus, resume, kemas kini, luar talian |

Pemetaan senario spesifikasi §19 → `packages/fdam/test/asset_manager_test.dart`
(nama ujian bermula dengan nombor senario): 1 pemasangan pertama, 2 internet ada,
3 tiada internet, 4 muat turun terganggu, 5 resume, 6 manifest tidak sah,
7 SHA-256 salah, 8 storan tidak cukup, 9 muat turun berganda, 10 gambar sahaja
dikemas kini, 11 pangkalan data dikemas kini, 12 aset pilihan, 13 ekstrak ZIP,
14 laluan ZIP tidak sah, 15 aplikasi ditutup semasa muat turun, 16 peranti
dimulakan semula, 17 release GitHub tiada, 18 URL manifest tiada,
19 rollback kemas kini gagal, 20 permulaan luar talian.

Lihat [TEST_REPORT.md](TEST_REPORT.md) untuk status sebenar ujian yang telah
dan belum dijalankan.
