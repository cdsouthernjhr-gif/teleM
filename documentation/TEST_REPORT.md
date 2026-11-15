# Laporan ujian — 15 Nov 2026

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

## BELUM DIUJI

| Keperluan | Sebab |
|---|---|
| Setiap URL stream sebenar / main semula HLS sebenar | ❌ Tiada URL stream terus yang disahkan (lihat STREAM_VERIFICATION.md). Rangkaian persekitaran pembinaan menyekat semua hos penyiar dan berada di luar Malaysia. Butang **UJI PEMAIN HLS** (Tetapan) disediakan untuk menguji pemain dengan stream contoh rasmi Apple pada peranti. |
| Android 6.0 emulator / peranti sebenar | ❌ Tiada KVM/peranti dalam persekitaran pembinaan. Hanya minSdk dan keserasian dependency (Media3 1.5.1 minSdk 21) disahkan secara statik. |
| TV Box RAM 2 GB | ❌ Tiada peranti. Langkah penjimatan memori telah dilaksanakan (lihat ARCHITECTURE.md) tetapi belum diukur. |
| Remote fizikal (DPAD_CENTER, butang CH, BACK) pada perkakasan | ❌ Hanya simulasi kekunci Flutter. |
| Pengesanan geo sebenar (Cloudflare/ipapi) | ❌ Hos disekat dalam persekitaran pembinaan; logik penghuraian diuji dengan data olok-olok. |
| Pengesanan VPN & membuka tetapan VPN | ❌ Kod Kotlin dikompil dalam APK tetapi belum dijalankan pada peranti. |
| TLS Let's Encrypt pada Android 6.0 | ❌ Root ISRG ditambah; perlu disahkan pada peranti Android 6.0. |
| Binaan lokal dalam persekitaran Claude | ❌ Maven Central memulangkan HTTP 429 melalui proksi; APK dibina di GitHub Actions. |

## Senarai semak ujian manual pada peranti

1. Pasang APK pada TV Box Android 6.0 (`adb install -r MY_ASEAN_TV.apk`); pastikan ikon/banner muncul pada skrin utama TV.
2. Tetapan → **UJI PEMAIN HLS** → video bipbop mesti dimainkan; tekan ▲▼, OK, BACK.
3. Matikan Wi-Fi semasa main → mesej "Menyambung semula (cubaan N)" → hidupkan semula → main semula disambung, atau panel kegagalan selepas cubaan terhad.
4. Matikan internet, buka semula aplikasi → senarai saluran dari cache + sepanduk luar talian.
5. Tetapan → KEMAS KINI MANUAL selepas menukar `database_version` di GitHub → versi baharu dipaparkan.
6. Tetapan → KESAN SEKARANG → negara dikesan (MY).
7. Buka saluran tanpa stream → BUKA PLATFORM RASMI membuka pelayar (jika ada pada TV Box).
8. Pantau memori: `adb shell dumpsys meminfo com.myaseantv.tv` semasa main (sasaran < 300 MB PSS).
