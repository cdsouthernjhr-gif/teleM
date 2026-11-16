# Laporan ujian — 15 Nov 2026

**Kemas kini v2:** 9 stream terus diuji ONLINE dengan `tool/health_check.dart` (lihat SOURCES.md). Pemeriksa kini menguji segmen terbaharu dalam playlist live.

Prinsip: hanya perkara yang **benar-benar diuji** ditanda ✅. Selebihnya ditanda ❌ BELUM DIUJI beserta sebabnya.

## Diuji secara automatik (51 ujian, `flutter test`, lulus lokal & di GitHub Actions)

| Keperluan | Status | Bukti |
|---|---|---|
| Setiap negara (MY/ID/SG/BN) dan bilangan saluran (11/15/6/4) | ✅ | `database_test.dart`, `widget_test.dart` (pilih setiap negara) |
| Setiap kategori bagi setiap negara | ✅ | penapis + UI diuji untuk 4 negara × 9 kategori |
| Skema JSON, ID unik, versi, rujukan alternatif, EPG | ✅ | `SchemaValidator` + `tool/validate_db.dart` (CI) |
| URL tidak sah (http, `file:`, `javascript:`, kelayakan, domain luar senarai) | ✅ | `UrlPolicy` + pemeriksa tidak membuat sebarang permintaan |
| Kemas kini GitHub: versi baharu, sama, manual, JSON tidak sah, gagal separuh jalan, cache rosak, `min_app_build` | ✅ | `database_test.dart` (klien HTTP olok-olok) |
| Cache luar talian + sepanduk luar talian | ✅ | unit + widget |
| Pemeriksa kesihatan: ONLINE hanya jika playlist + varian + segmen pertama OK; HTML 200 ≠ ONLINE; 401/403/404/410/451/5xx/timeout | ✅ | `services_test.dart` |
| Respons geo-restriction (451, mesej geo, 403 di luar `geo_allowed`) | ✅ | unit + widget (panel kegagalan) |
| Auto-reconnect terhad, backoff, sumber sekunder, pengesan "stall", tiada gelung tanpa had | ✅ | `PlaybackController` dengan backend olok-olok + fake time |
| Fallback platform rasmi + alternatif | ✅ | widget (butang BUKA PLATFORM RASMI, senarai alternatif) |
| Navigasi remote D-pad (anak panah, OK/select, CH+/CH−, BACK) | ✅ (simulasi) | `widget_test.dart` menghantar acara kekunci |
| `flutter analyze` | ✅ | tiada isu |
| APK release terbina, `minSdk 23`, `targetSdk 35`, Leanback launcher | ✅ | GitHub Actions run 43699939597 (`aapt dump badging`: `sdkVersion:'23'`) |

## FDAM — Flutter Dynamic Asset Manager (16 Nov 2026)

Dijalankan dalam persekitaran pembinaan (Linux, Flutter 3.32.8). Ujian muat turun menggunakan **pelayan HTTP tempatan sebenar** (ETag, Range/If-Range, redirect, sambungan diputuskan, pelayan tergantung), SQLite sebenar (sqflite FFI) dan sistem fail sebenar — bukan olok-olok.

| Keperluan | Status | Bukti |
|---|---|---|
| `packages/fdam`: `flutter analyze` | ✅ | tiada isu |
| `packages/fdam`: 71 ujian | ✅ | `cd packages/fdam && flutter test` |
| Senario §19 no. 1–20 (pemasangan pertama, luar talian, terganggu, resume, manifest tidak sah, SHA-256 salah, storan tidak cukup, berganda, gambar/DB dikemas kini, pilihan, ZIP, ZIP Slip, ditutup semasa muat turun, restart, release tiada, manifest tiada, rollback, permulaan luar talian) | ✅ (pada hos) | `asset_manager_test.dart` |
| Keselamatan ZIP (traversal, mutlak, symlink, bom, had fail/saiz, rosak) | ✅ | `zip_extractor_test.dart` |
| Migrasi SQLite v1→v2, kegigihan selepas dibuka semula | ✅ | `database_test.dart` |
| UI Riverpod (gate → muat turun sebenar → aplikasi, papan pemuka, pengurus muat turun, tetapan) | ✅ | `ui_test.dart` |
| Output penjana Python diterima pengesah Dart dan dipasang hujung-ke-hujung | ✅ | `template_compat_test.dart` |
| Alat Python (penjana, pengesah, hash): 10 ujian | ✅ | `python -m unittest discover -s tools/tests` |
| Aplikasi: ujian sedia ada + 2 ujian FDAM (gerbang, pautan Tetapan) | ✅ | `flutter test` (53 ujian) |
| APK debug + release dengan FDAM dibina dalam persekitaran ini | ✅ | `flutter build apk --debug` dan `--release` (R8 aktif) berjaya; `aapt`: `sdkVersion:'23'`, `targetSdkVersion:'35'`. Kebenaran: INTERNET, ACCESS_NETWORK_STATE, WAKE_LOCK, RECEIVE_BOOT_COMPLETED sahaja (POST_NOTIFICATIONS dan FOREGROUND_SERVICE daripada WorkManager dibuang kerana tidak digunakan). |
| APK tidak mengandungi fail media | ✅ | Tiada `.mp3/.wav/.mp4/.zip` dalam APK. Saiz release (3 ABI): 47.4 MB sebelum FDAM → 52.4 MB selepas (+1.5 MB kod Dart dan +0.37 MB dex bagi setiap ABI). |
| Ujian peranti Android (`integration_test/fdam_device_test.dart`) | ❌ BELUM DIJALANKAN | Tiada KVM/peranti. Ia menguji sqflite asli, StatFs (plugin FDAM), connectivity_plus pada peranti. |
| WorkManager benar-benar dijalankan oleh Android | ❌ BELUM DIUJI | Pendaftaran dikompil; pelaksanaan latar belakang memerlukan peranti. `FdamBackground.runMaintenance` diuji secara tidak langsung melalui laluan yang sama (`checkForUpdates` + `downloadItems`). |
| Muat turun sebenar dari github.com / objects.githubusercontent.com | ❌ BELUM DIUJI | Belum ada repositori aset yang diterbitkan; redirect GitHub disimulasikan oleh pelayan tempatan. |

## BELUM DIUJI

| Keperluan | Sebab |
|---|---|
| Main semula video sebenar pada telefon/TV | ❌ URL v2 lulus ujian HTTP (playlist dan segmen, lihat SOURCES.md), tetapi main semula dalam aplikasi pada peranti belum disahkan. Dari Malaysia, gunakan Tetapan → **UJI SEMUA STREAM** dan cuba setiap saluran. |
| Android 6.0 emulator / peranti sebenar | ❌ Tiada KVM/peranti dalam persekitaran pembinaan. Hanya minSdk dan keserasian dependency (Media3 1.5.1 minSdk 21) disahkan secara statik. |
| TV Box RAM 2 GB | ❌ Tiada peranti. Langkah penjimatan memori telah dilaksanakan (lihat ARCHITECTURE.md) tetapi belum diukur. |
| Remote fizikal (DPAD_CENTER, butang CH, BACK) pada perkakasan | ❌ Hanya simulasi kekunci Flutter. |
| Pengesanan geo sebenar (Cloudflare/ipapi) | ❌ Hos disekat dalam persekitaran pembinaan; logik penghuraian diuji dengan data olok-olok. |
| Pengesanan VPN & membuka tetapan VPN | ❌ Kod Kotlin dikompil dalam APK tetapi belum dijalankan pada peranti. |
| TLS Let's Encrypt pada Android 6.0 | ❌ Root ISRG ditambah; perlu disahkan pada peranti Android 6.0. |
| Binaan lokal dalam persekitaran Claude | ✅ (16 Nov 2026) Maven Central masih memulangkan HTTP 429 melalui proksi; binaan berjaya dengan skrip init Gradle tempatan yang menghala ke cermin Maven Central Google (tidak di-commit). |

## Senarai semak ujian manual pada peranti

1. Pasang APK pada TV Box Android 6.0 (`adb install -r MY_ASEAN_TV.apk`); pastikan ikon/banner muncul pada skrin utama TV.
2. Tetapan → **UJI PEMAIN HLS** → video bipbop mesti dimainkan; tekan ▲▼, OK, BACK.
3. Matikan Wi-Fi semasa main → mesej "Menyambung semula (cubaan N)" → hidupkan semula → main semula disambung, atau panel kegagalan selepas cubaan terhad.
4. Matikan internet, buka semula aplikasi → senarai saluran dari cache + sepanduk luar talian.
5. Tetapan → KEMAS KINI MANUAL selepas menukar `database_version` di GitHub → versi baharu dipaparkan.
6. Tetapan → KESAN SEKARANG → negara dikesan (MY).
7. Buka saluran tanpa stream → BUKA PLATFORM RASMI membuka pelayar (jika ada pada TV Box).
8. Pantau memori: `adb shell dumpsys meminfo com.myaseantv.tv` semasa main (sasaran < 300 MB PSS).
